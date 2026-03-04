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

### 2. Moved etcd Disk to Local NVMe (`local-lvm`)
The etcd disk was on `nas-1` (TrueNAS over network) — ~250ms fsync latency. Moved to
`local-lvm` (NVMe on the Proxmox host) via `qm move-disk 101 scsi1 local-lvm --delete 1`.

This eliminated the root cause. The following NAS workarounds were **removed** as they are
unnecessary (or harmful) on local NVMe:

| Workaround | Why removed |
|---|---|
| `nodiscard` fstab mount | NVMe handles TRIM fast; discard reclaims thin pool space |
| `discard_max_bytes=0` udev rule | Same — only needed for NAS TRIM stalls |
| `mq-deadline` I/O scheduler | NVMe has its own scheduler; `none` is optimal |
| `--heartbeat-interval=500` | NVMe fsync is <1ms; default 100ms heartbeat is fine |
| `--election-timeout=5000` | Default 1000ms is fine; 5000ms delays failure detection |

**Packer template** updated: `etcd_disk_storage` variable allows placing the etcd disk on
a separate storage pool from the OS disk. Set to `local-lvm` in variables file.

### 3. VM Resource Increase
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
#    The cilium-healthcheck DaemonSet may have already handled this.
#    Verify its logs, then force a restart to ensure all nodes are clean:
kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-healthcheck --tail=5
kubectl rollout restart daemonset -n kube-system cilium
kubectl rollout status daemonset -n kube-system cilium --timeout=120s

# 3. Verify ClusterIP routing works (from a debug pod)
#    Tests both DNS resolution AND TCP connectivity to the API server ClusterIP
kubectl run check-net --rm -it --restart=Never --image=busybox -n kube-system -- sh -c \
  'nslookup kubernetes.default && nc -z -w5 $KUBERNETES_SERVICE_HOST $KUBERNETES_SERVICE_PORT && echo OK || echo FAIL'

# 4. Restart any pods that were crash-looping during the outage
kubectl get pods -A | grep -E 'CrashLoopBackOff|Error'
# For each affected workload:
# kubectl rollout restart {deployment|statefulset|daemonset} -n <namespace> <name>

# 5. Run full cluster health check
python3 scripts/ops/validate-cluster-health.py
```

## Prevention

1. **etcd on local NVMe** — Packer template uses `etcd_disk_storage = "local-lvm"` to place
   etcd on fast local storage. NAS/network storage should never be used for etcd.
2. **Packer builds** include dedicated etcd disk with discard enabled and weekly defrag timer
3. **Monitoring** — GitHub issue #475 created for Slack alerting on cluster health events
4. **Cilium health check DaemonSet** — automatically detects stale eBPF maps and restarts
   the local Cilium agent (see `platform/base/cilium-healthcheck/`)

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

# Check TRIM/discard settings (on NVMe, discards should be enabled)
cat /sys/block/sdb/queue/discard_max_bytes  # should be >0 on NVMe
mount | grep etcd  # should show discard (not nodiscard)
```
