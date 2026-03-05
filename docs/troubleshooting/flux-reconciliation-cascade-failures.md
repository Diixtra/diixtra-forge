# Flux Reconciliation Cascade Failures

**Date**: 2026-03-05
**Status**: Resolved (session) / Permanent fixes proposed
**Impact**: All 6 kustomizations and multiple HelmReleases failed to reconcile. Root cause was a chain of failures starting with Kyverno webhook timeouts and Cilium stale datapaths.

## Failure Chain

```
Kyverno webhook timeout
  -> platform-crds blocked (health check on backstage HR)
    -> platform blocked (depends on platform-crds)
      -> apps blocked (depends on platform)
```

Independently, Cilium stale datapaths on pi5 and k8-gpu-1 broke pod-to-pod networking, preventing backstage from reaching its postgres database.

## Issues Encountered

### 1. Kyverno admission controller stuck in lease loop

**Symptom**: All kustomizations failing with `webhook "validate.kyverno.svc-fail" timeout`.
**Root cause**: Kyverno admission controller pod was Running but stuck in a lease update loop, not serving webhooks.
**Fix**: `kubectl delete pod -n kyverno-system -l app.kubernetes.io/component=admission-controller`
**Recurred**: Yes, had to restart twice during the session.

**Permanent fix**:
- Add a `livenessProbe` that checks webhook readiness, not just process health
- Consider switching Kyverno `failurePolicy` from `Fail` to `Ignore` for non-critical policies (risk: policies silently bypassed during outages)
- Add Flux health check timeout on Kyverno HR so it auto-remediates

### 2. Cilium stale datapath (pod networking broken)

**Symptom**: Pods on a node cannot reach other pod IPs, even on the same node. `curl` to pod IP hangs.
**Root cause**: Cilium agent had stale VXLAN datapath state after restarts. Affected pi5 (0 restarts but stale) and k8-gpu-1 (11 restarts).
**Fix**: `kubectl delete pod -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=<node>`

**Permanent fix**:
- Upgrade Cilium — newer versions have improved datapath resiliency
- Add node-level connectivity monitoring (e.g., periodic pod-to-pod pings via Grafana Alloy)
- Consider adding a CronJob or DaemonSet that detects stale datapaths and auto-restarts the Cilium agent
- Investigate if `bpf.masquerade=true` or `tunnel=disabled` (native routing) reduces stale state

### 3. Falco CrashLoopBackOff on ARM nodes

**Symptom**: Falco pods crash on pi4/pi5 with `BPF_TRACE_RAW_TP` not supported.
**Root cause**: Falco's `modern_ebpf` driver requires kernel features not available on ARM64 Pi kernels.
**Fix applied**: Added `nodeSelector: kubernetes.io/arch: amd64` and GPU toleration to falco helm-release.

**Status**: Permanently fixed in `infrastructure/base/falco/helm-release.yaml`.

### 4. Kyverno blocking Helm upgrades (missing resource limits)

**Symptom**: Falco HelmRelease stuck — Kyverno `require-resource-limits` policy blocks pods without CPU/memory limits.
**Root cause**: Upstream Helm charts don't always expose resource limit values for all containers (init containers, sidecars).
**Affected**: falcosidekick-ui init container, falcoctl init/sidecar containers.
**Fix applied**:
- Disabled `webui` (init container resource limits not configurable)
- Added explicit `falcoctl.artifact.install.resources` and `falcoctl.artifact.follow.resources`

**Permanent fix**:
- Before upgrading any HelmRelease, check the chart's rendered manifest for containers without resource limits: `helm template <chart> | grep -A5 'containers:' | grep -B1 'resources:'`
- Consider adding a Kyverno exception (`PolicyException`) for specific namespaces or well-known charts where upstream doesn't support resource limits
- Alternatively, use Kyverno `mutate` rules to inject default limits into containers that lack them, rather than blocking

### 5. democratic-csi provisioner can't reach TrueNAS

**Symptom**: PVC stuck Pending. CSI controller logs show `timeout of 60000ms exceeded` or `502 Bad Gateway`.
**Root cause (this incident)**: TrueNAS cloud backup/sync jobs saturated disk I/O, causing the ZFS dataset creation API to hang for 60+ seconds.
**Root cause (general)**: Pod networking issues (Cilium stale datapath) can also prevent pods from reaching TrueNAS at 10.2.0.232.

**Diagnosis steps**:
```bash
# 1. Test TrueNAS API from control plane
curl -sk https://10.2.0.232/api/v2.0/core/ping

# 2. Test from CSI controller pod
kubectl exec -n democratic-csi <controller-pod> -c csi-driver -- \
  wget -qO- --no-check-certificate --timeout=10 https://10.2.0.232/api/v2.0/core/ping

# 3. Check for running TrueNAS jobs
curl -sk -H "Authorization: Bearer <api-key>" \
  'https://10.2.0.232/api/v2.0/core/get_jobs' | \
  python3 -c 'import json,sys; [print(f"{j["id"]}: {j["method"]} {j["state"]}") for j in json.load(sys.stdin) if j["state"] in ("RUNNING","WAITING")]'

# 4. Test dataset creation directly
time curl -sk --max-time 120 -X POST \
  -H "Authorization: Bearer <api-key>" \
  -H "Content-Type: application/json" \
  -d '{"name":"kaz.cloud/kozmox/k8/nfs/vols/test-delete-me"}' \
  'https://10.2.0.232/api/v2.0/pool/dataset'
```

**Permanent fix**:
- Schedule TrueNAS cloud backups during off-hours and cap I/O priority
- Add TrueNAS API health monitoring to Grafana (ping endpoint + response time)
- Consider increasing the democratic-csi HTTP timeout beyond 60s in the driver config
- Keep CSI controller pods on the control plane node (direct L2 access to TrueNAS, no VXLAN overhead)

### 6. CSI "operation locked" errors

**Symptom**: `operation locked due to in progress operation(s)` in CSI controller or node logs. New provisioning attempts fail.
**Root cause**: A previous CreateVolume or NodeStageVolume call hung (due to TrueNAS timeout), and the lock was never released.
**Fix**: Restart the affected pod — `kubectl delete pod -n democratic-csi <pod>`

**Permanent fix**:
- This is a known democratic-csi issue — locks are in-memory and don't have TTLs
- Upgrading democratic-csi may help if newer versions add lock timeouts
- As a workaround, add a liveness probe that detects stale locks

### 7. iSCSI volume attached but device node never appears

**Symptom**: Pod stuck in ContainerCreating. CSI node logs show `hit timeout waiting for device node to appear`.
**Root cause**: iSCSI login succeeded but the kernel didn't create the block device, usually because the zvol/extent wasn't fully provisioned on TrueNAS (incomplete CreateVolume due to API flakiness).
**Fix**: Delete the PVC, clean up orphaned targets/extents/datasets on TrueNAS, restart CSI controller, let it reprovision.

**Cleanup commands**:
```bash
# List iSCSI targets on TrueNAS
curl -sk -H "Authorization: Bearer <api-key>" \
  'https://10.2.0.232/api/v2.0/iscsi/target' | python3 -c '
import json,sys; [print(f"id={t[\"id\"]} name={t[\"name\"]}") for t in json.load(sys.stdin)]'

# Delete orphaned target (no matching extent)
curl -sk -X DELETE -H "Authorization: Bearer <api-key>" \
  'https://10.2.0.232/api/v2.0/iscsi/target/id/<id>?force=true'

# Delete orphaned dataset
curl -sk -X DELETE -H "Authorization: Bearer <api-key>" \
  'https://10.2.0.232/api/v2.0/pool/dataset/id/<url-encoded-dataset-id>'
```

## Remaining Known Issues

### k8-worker-1 NotReady
Kubelet stopped posting status. Needs SSH investigation — likely the node needs a reboot or kubelet restart.

### CiliumNetworkPolicy default-deny policies Invalid
All default-deny `CiliumNetworkPolicy` resources across namespaces show `Valid: False`. They have empty `ingress: []` / `egress: []` arrays which Cilium rejects. Currently harmless because `policyAuditMode: true`, but will block traffic once audit mode is disabled.

**Fix**: Change empty arrays to explicit deny rules:
```yaml
# Instead of:
ingress: []
egress: []

# Use:
ingressDeny:
  - fromEntities:
      - all
egressDeny:
  - toEntities:
      - all
```

## Prevention Checklist

- [ ] Add TrueNAS API response time monitoring to Grafana
- [ ] Schedule cloud backups to run during off-peak hours with I/O throttling
- [ ] Add pod-to-pod connectivity monitoring across all nodes
- [ ] Review Kyverno `failurePolicy` — consider `Ignore` for `require-resource-limits`
- [ ] Upgrade Cilium to latest patch for datapath resiliency improvements
- [ ] Add `PolicyException` for charts with known unconfigurable init containers
- [ ] Fix CiliumNetworkPolicy default-deny policies before disabling audit mode
- [ ] Investigate k8-worker-1 kubelet failure
