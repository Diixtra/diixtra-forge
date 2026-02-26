# k8-worker-1 Pod Sandbox Failures — Missing systemd-resolved

**Date**: 2026-02-26
**Status**: Resolved (manual fix applied; Packer image fix pending)
**Impact**: All pods on k8-worker-1 unable to create sandboxes. Cascading failures: Cilium DaemonSet not fully Ready, ARC runner listeners stuck, democratic-csi node drivers not running, image pulls failing cluster-wide on that node.

## Environment

- **Node**: k8-worker-1 (Debian 13 trixie, kernel 6.12.73+deb13-amd64)
- **Runtime**: containerd 2.2.1
- **Kubernetes**: v1.35.1 (kubeadm)
- **Kubelet resolvConf**: `/run/systemd/resolve/resolv.conf`

## Symptoms

1. Cilium DaemonSet stuck at 4/5 Ready after enabling Hubble UI (PR #130)
2. Multiple pods on k8-worker-1 in `Unknown` state (leftovers from earlier reboot)
3. After force-deleting Unknown pods, replacements stuck in `Init:0/6` and `ContainerCreating`
4. ARC runner listeners and democratic-csi node pods in `ImagePullBackOff`

## Investigation

### Step 1: Check stuck pod events

```
kubectl describe pod cilium-s9p6v -n kube-system
```

Events revealed:
```
Warning  FailedCreatePodSandBox  8s (x25 over 5m32s)  kubelet
  Failed to create pod sandbox: open /run/systemd/resolve/resolv.conf: no such file or directory
```

Every pod on the node had the same error — the kubelet could not create any pod sandbox because the resolv.conf file it was configured to use did not exist.

### Step 2: Confirm resolv.conf is missing

```
# On k8-worker-1:
ls -la /run/systemd/resolve/resolv.conf
# ls: cannot access '/run/systemd/resolve/resolv.conf': No such file or directory

systemctl status systemd-resolved
# Unit systemd-resolved.service could not be found.
```

`systemd-resolved` was never installed on this node. The Packer image did not include it.

### Step 3: Confirm kubelet expects it

```
# On k8-worker-1:
grep resolv /var/lib/kubelet/config.yaml
# resolvConf: /run/systemd/resolve/resolv.conf
```

The kubelet was configured (via kubeadm defaults) to use `systemd-resolved`'s resolv.conf, but the service wasn't present.

### Step 4: Compare with control plane

```
# On kaz-k8-1 (control plane):
ls -la /run/systemd/resolve/resolv.conf
# -rw-r--r-- 1 systemd-resolve systemd-resolve 793 Feb 26 14:02 /run/systemd/resolve/resolv.conf

systemctl status systemd-resolved
# Active: active (running)
```

The control plane had `systemd-resolved` installed and working — the Packer image for the control plane included it, but the worker image did not.

## Root Cause

The Packer image used for k8-worker-1 did not include the `systemd-resolved` package. kubeadm's default kubelet configuration sets `resolvConf: /run/systemd/resolve/resolv.conf`, which requires the service to be running. Without it:

1. The kubelet cannot create pod sandboxes (no resolv.conf to inject into containers)
2. Even if sandboxes were created, DNS resolution inside containers would fail

The node appeared `Ready` because the kubelet itself uses the host's `/etc/resolv.conf` (which had `1.1.1.1` and `8.8.8.8` hardcoded), but pod creation was completely broken.

## Fix Applied (Manual)

### 1. Install systemd-resolved

```bash
ssh k8-worker-1
sudo apt-get install -y systemd-resolved
sudo systemctl enable --now systemd-resolved
```

### 2. Configure upstream DNS

After install, systemd-resolved had no upstream DNS servers (`No DNS servers known`). Created a drop-in config:

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
echo -e '[Resolve]\nDNS=1.1.1.1 8.8.8.8' | sudo tee /etc/systemd/resolved.conf.d/dns.conf
sudo systemctl restart systemd-resolved
```

### 3. Restart kubelet

The kubelet needed a restart to pick up the now-existing resolv.conf:

```bash
sudo systemctl restart kubelet
```

### 4. Verify

```bash
# DNS works:
resolvectl query ghcr.io
# ghcr.io: 20.26.156.211

# resolv.conf exists with nameservers:
cat /run/systemd/resolve/resolv.conf
# nameserver 1.1.1.1
# nameserver 8.8.8.8

# All pods running:
kubectl get pods -A --field-selector spec.nodeName=k8-worker-1
# All Running, 0 not-ready
```

## Permanent Fix Needed

The Packer image for worker nodes must be updated to:

1. Install `systemd-resolved` (`apt-get install -y systemd-resolved`)
2. Create `/etc/systemd/resolved.conf.d/dns.conf` with upstream DNS servers
3. Enable the service (`systemctl enable systemd-resolved`)

This should be tracked as a separate ticket to fix the Packer template.

## Timeline

| Time | Event |
|------|-------|
| ~02:00 | k8-worker-1 rebooted with 4GB RAM (previously 2GB) |
| ~02:00 | Pods from previous node state stuck in `Unknown` |
| ~14:00 | Cilium Hubble UI enabled (PR #130), DaemonSet rolling update |
| ~14:30 | Cilium stuck at 4/5 — new pod on k8-worker-1 can't start |
| 16:14 | Force-deleted Unknown cilium + cilium-envoy pods |
| 16:15 | Replacement pods stuck: `Init:0/6` / `ContainerCreating` |
| 16:17 | `FailedCreatePodSandBox: open /run/systemd/resolve/resolv.conf: no such file or directory` |
| 16:21 | Installed systemd-resolved, configured DNS |
| 16:25 | Restarted kubelet, all pods recovered |
| 16:30 | 16/16 HelmReleases Ready, 0 non-ready pods cluster-wide |

## Lessons Learned

1. **Node `Ready` != pods can run**: A node can report `Ready` even if pod sandbox creation is completely broken. The kubelet health checks don't validate the resolv.conf path.
2. **Packer image parity**: Control plane and worker images should install the same base packages. Use a shared provisioner script for common packages like `systemd-resolved`.
3. **Check kubelet resolvConf**: When pods fail to create sandboxes, check the kubelet's `resolvConf` config and verify the target file exists on the host.
4. **systemd-resolved needs explicit DNS**: A fresh install has no upstream DNS configured. Always add a drop-in config with fallback DNS servers.
