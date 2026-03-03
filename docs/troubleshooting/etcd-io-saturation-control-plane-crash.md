# etcd I/O Saturation — Control Plane Crash Loop

**Date:** 2026-03-03
**Affected Node:** kaz-k8-1 (control-plane)
**Impact:** Full cluster outage — API server unreachable, all controllers crash-looping
**Root Cause:** etcd disk I/O contention + Proxmox thin-provisioned TRIM stalls

## Symptoms

- API server connection refused (`dial tcp 10.2.0.35:6443: connect: connection refused`)
- etcd fdatasync latency 12-30 seconds (expected <10ms)
- sda (root disk) at 90-99% utilisation, 40-89% iowait
- All controllers (democratic-csi, flux, kube-state-metrics) crash-looping due to leader election failures
- Load average 11.58 on 2 CPU cores

## Root Cause Chain

### Stage 1: Shared Disk Saturation
etcd data (`/var/lib/etcd`, 477MB) was on the root LVM volume (sda), sharing I/O bandwidth
with containerd images, kubelet, container logs, and all pod storage. Under normal cluster
load, the combined I/O pushed sda to 90-99% utilisation.

etcd's write-ahead log (WAL) requires fast synchronous writes (fdatasync). When sda was
saturated, fdatasync latency spiked from <10ms to 12-30 seconds. etcd treated this as node
failure, the API server timed out waiting for etcd, and the entire control plane crash-looped.

**Why sdb was never used:** The Packer template originally had no second disk. After adding
sdb (50GB) for etcd, cloud-init had no `disk_setup` config so it skipped formatting:
`Skipping modules 'disk_setup' because no applicable config is provided`. The provisioning
script now handles formatting sdb during the Packer build.

### Stage 2: TRIM/Discard Stalls
After migrating etcd to sdb, the disk showed 100% utilisation with zero throughput. The
Proxmox QEMU virtual disk (thin-provisioned) accepts discard/TRIM requests up to 1GB
(`/sys/block/sdb/queue/discard_max_bytes = 1073741824`). When ext4 issued large TRIM
commands during filesystem operations, the underlying storage backend stalled completely.

This put etcd in uninterruptible I/O sleep (D state) — unkillable by any signal. The only
recovery was a node reboot.

### Stage 3: Slow Storage Latency
Even with TRIMs disabled, the Proxmox storage pool backing the VM disks has inherent
latency (~250ms fsync, ~70ms write await). etcd's default heartbeat interval (100ms) is
shorter than the disk latency, causing raft agreement to time out repeatedly.

## Fixes Applied

### 1. Dedicated etcd Disk (Packer template + provisioning script)
**Files changed:**
- `packer/proxmox-ubuntu/ubuntu-k8s.pkr.hcl` — added second disk block + `etcd_disk_size` variable
- `packer/scripts/provision-k8s-node.sh` — formats sdb, mounts at `/var/lib/etcd`

### 2. Disable TRIM/Discard on etcd Disk
**fstab:** `nodiscard` mount option prevents ext4 from issuing inline TRIMs
```
LABEL=etcd-data /var/lib/etcd ext4 defaults,noatime,nodiscard 0 2
```

**udev rule:** Belt-and-suspenders block-layer discard disable
```
# /etc/udev/rules.d/99-etcd-nodiscard.rules
ACTION=="add|change", KERNEL=="sdb", ATTR{queue/discard_max_bytes}="0"
```

### 3. etcd Heartbeat Tuning (manual, applied to etcd.yaml on kaz-k8-1)
For storage with >100ms latency, the default etcd heartbeat (100ms) is too aggressive:
```yaml
# /etc/kubernetes/manifests/etcd.yaml
- --heartbeat-interval=500    # default: 100ms, 2x disk latency
- --election-timeout=5000     # default: 1000ms, 10x heartbeat
```

**Note:** This was applied manually to the live node. For new clusters, this should be
configured via kubeadm's `ClusterConfiguration.etcd.local.extraArgs` during bootstrap.

### 4. VM Resource Increase
Control plane resources increased from 2 CPU / 3.8GB RAM to 4 CPU / 5.8GB RAM.

## Cascade Effects Fixed

| Pod | Issue | Fix |
|-----|-------|-----|
| democratic-csi controllers (x2) | CrashLoopBackOff — leader election failures due to API server down | Self-healed once API server stabilised |
| cilium agents (per-node) | Stale eBPF service maps — new pods get `EHOSTUNREACH` for ClusterIPs while existing pods work fine | Rolling restart: `kubectl rollout restart ds -n kube-system cilium` |
| backstage | CrashLoopBackOff — DB connection timeout (`EHOSTUNREACH` for PostgreSQL ClusterIP due to stale Cilium eBPF) | Restart Cilium agent on affected node, then restart Backstage |
| kube-state-metrics | CrashLoopBackOff — bad deployment revision with Go `map[]` syntax in args | Rolled back to revision 2 |
| nvidia-device-plugin | ContainerCreating — NVIDIA kernel module not built for azure kernel | Installed `linux-headers-6.17.0-1008-azure`, DKMS rebuilt nvidia module |
| ollama | Pending — no GPU resources available | Self-resolved once nvidia-device-plugin registered the GPU |
| node-cleanup CronJob | ImagePullBackOff — `bitnami/kubectl:1.31` not found | Patched to `registry.k8s.io/kubectl:v1.35.1` |

## Post-Recovery Checklist

After the control plane recovers from any outage, run these steps in order:

```bash
# 1. Verify API server and nodes
kubectl cluster-info
kubectl get nodes

# 2. Rebuild Cilium eBPF service maps on all nodes
#    The cilium-healthcheck DaemonSet should handle this automatically,
#    but verify its logs first. If it hasn't acted, restart manually:
kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-healthcheck --tail=5
kubectl rollout restart daemonset -n kube-system cilium
kubectl rollout status daemonset -n kube-system cilium --timeout=120s

# 3. Verify ClusterIP routing works (from a debug pod)
#    Tests both DNS resolution AND TCP connectivity to the API server ClusterIP
kubectl run check-net --rm -it --restart=Never --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"check-net","image":"busybox","command":["sh","-c","nslookup kubernetes.default && nc -z -w5 $KUBERNETES_SERVICE_HOST $KUBERNETES_SERVICE_PORT && echo OK || echo FAIL"],"resources":{"requests":{"cpu":"50m","memory":"32Mi"},"limits":{"cpu":"50m","memory":"32Mi"}}}]}}' \
  -n kube-system

# 4. Restart any pods that were crash-looping during the outage
kubectl get pods -A | grep -E 'CrashLoopBackOff|Error'
# For each affected workload:
# kubectl rollout restart {deployment|statefulset|daemonset} -n <namespace> <name>

# 5. Run full cluster health check
python3 scripts/ops/validate-cluster-health.py
```

## Prevention

1. **Packer builds** now include dedicated etcd disk with `nodiscard` mount and udev rule
2. **Monitoring** — GitHub issue #475 created for Slack alerting on cluster health events
3. **Cilium health check DaemonSet** — automatically detects stale eBPF maps and restarts
   the local Cilium agent (see `platform/base/cilium-healthcheck/`)
4. **Future improvement:** Move VM disks to a Proxmox storage pool backed by local NVMe
   rather than network/thin-provisioned storage. etcd requires <10ms fdatasync latency;
   the current pool delivers ~250ms.

## Diagnostic Commands Reference

```bash
# Check etcd fdatasync latency (should be <10ms)
sudo crictl logs <etcd-container-id> 2>&1 | grep 'took too long'

# Check disk utilisation and iowait
iostat -x 1 3

# Check etcd database size and fragmentation
sudo crictl exec <etcd-container-id> etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table

# Check TRIM/discard settings
cat /sys/block/sdb/queue/discard_max_bytes  # should be 0
mount | grep etcd  # should show nodiscard
```
