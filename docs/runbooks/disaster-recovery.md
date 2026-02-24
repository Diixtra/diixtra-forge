# Disaster Recovery Runbook

## Overview

This runbook covers recovery procedures for the homelab k3s cluster after node reboots, TrueNAS outages, and cascading Flux failures.

## Prerequisites

SSH access to the control plane node:
```bash
ssh kaz-k8-1
```

## Recovery Procedures

### 1. Node Reboot Recovery

After a node reboot, verify all nodes are Ready:
```bash
kubectl get nodes
```

Check Flux reconciliation status:
```bash
flux get kustomizations
flux get helmreleases -A
```

If Flux is stuck on an old revision, trigger a source reconciliation:
```bash
flux reconcile source git flux-system --timeout=2m
```

### 2. 1Password Operator Recovery

**Symptom**: `infrastructure` Kustomization stuck reconciling. Health check reports OnePasswordItems as `InProgress`.

**Root cause**: The 1Password operator uses a WASM-based SDK that can crash with "out of bounds memory access" after node restarts.

**Fix**:
```bash
# 1. Restart the operator to clear corrupted WASM state
kubectl rollout restart deployment/onepassword-connect-operator -n onepassword-system
kubectl rollout status deployment/onepassword-connect-operator -n onepassword-system --timeout=60s

# 2. Force all OnePasswordItems to resync
kubectl annotate onepassworditem --all -A force-sync=$(date +%s) --overwrite

# 3. Verify secrets exist
kubectl get secrets -A | grep -E "cloudflare|truenas|github-config|backstage"

# 4. Check operator logs for errors
kubectl logs -n onepassword-system deploy/onepassword-connect-operator --tail=20
```

**Important**: Never `kubectl delete secret` a 1Password-managed secret. The operator may fail to recreate it.

### 3. DiskPressure Recovery

**Symptom**: Pods evicted with reason `The node had condition: [DiskPressure]`.

**Fix**:
```bash
# Check which nodes have pressure
kubectl describe nodes | grep -A5 "Conditions:"

# On the affected node, clean up container images
crictl rmi --prune

# Clean old pod logs
find /var/log/pods -mtime +7 -delete 2>/dev/null

# Verify pressure cleared
kubectl describe node <node-name> | grep DiskPressure
```

### 4. Cascading Flux Failure Recovery

**Symptom**: Multiple Kustomizations show `dependency not ready`.

The Flux dependency chain is:
```
infrastructure-crds → infrastructure → platform-crds → platform → apps
```

A failure at any stage blocks all downstream stages.

**Fix** — work through the chain in order:
```bash
# 1. Fix the root cause (usually 1Password operator or a failed HelmRelease)
# See sections above

# 2. Reconcile each stage in order
flux reconcile kustomization infrastructure-crds --timeout=10m
flux reconcile kustomization infrastructure --timeout=10m
flux reconcile kustomization platform-crds --timeout=10m
flux reconcile kustomization platform --timeout=10m
flux reconcile kustomization apps --timeout=10m
```

### 5. Stale HelmRelease Status

**Symptom**: HelmRelease shows `False` / `Helm upgrade failed` but pods are actually running fine.

**Fix**:
```bash
# Suspend and resume to clear stale status
flux suspend helmrelease <name> -n <namespace>
flux resume helmrelease <name> -n <namespace>

# Then reconcile
flux reconcile helmrelease <name> -n <namespace> --timeout=10m
```

## Post-Recovery Validation

Run these checks after any recovery to confirm full system health:

```bash
# All nodes Ready
kubectl get nodes

# All Kustomizations Ready
flux get kustomizations

# All HelmReleases Ready
flux get helmreleases -A

# No unhealthy pods
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded | grep -v Completed

# 1Password secrets synced
kubectl get onepassworditems -A

# Storage healthy
kubectl get pv
kubectl get pvc -A
```

## Known Issues

### 1Password WASM Crash (recurring)

The 1Password Connect operator v2.x uses a WASM-based SDK that is prone to out-of-bounds memory access errors after node restarts. The fix is always to restart the operator pod. Memory limits have been increased to 512Mi to reduce frequency.

### DiskPressure on Worker Nodes

Worker nodes with limited disk can hit DiskPressure after accumulating container images and pod logs. This evicts pods during HelmRelease upgrades, causing upgrade timeouts.
