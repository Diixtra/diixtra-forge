# Bootstrap Runbook — Flux CD on Diixtra Forge

## Bootstrap Strategy

The initial Flux bootstrap is a **one-time manual operation** per cluster,
run from the control plane node (`kaz-k8-1`). This is unavoidable — Flux
can't deploy itself, and GitHub Actions runners can't reach the homelab
until the runner is inside the cluster.

After bootstrap, the sequence is:
1. Manual `flux bootstrap` installs Flux + infrastructure layer
2. Flux deploys 1Password Operator, MetalLB, **and** the self-hosted
   GitHub Actions runner (KAZ-62)
3. Runner connects to GitHub → pipelines now have cluster access
4. All subsequent operations (re-bootstrap, upgrades, new cluster
   onboarding) happen through GitHub Actions workflows

The `flux bootstrap` command is idempotent — running it again updates
Flux without destroying state. Once the self-hosted runner exists, this
command moves into a `workflow_dispatch` pipeline.

## Prerequisites

Before running the bootstrap script, ensure you have:

1. **Flux CLI** installed: `curl -s https://fluxcd.io/install.sh | sudo bash`
2. **kubectl** configured and pointing at your homelab cluster
3. **GitHub CLI** (`gh`) installed and authenticated: `gh auth login`
4. **GitHub Fine-Grained PAT** with:
   - Repository: `diixtra-forge` (must exist first)
   - Contents: Read and write
   - Administration: Read and write (for deploy key creation)
5. **1Password SA token** for the Homela vault

## Pre-Flight Checks

Run Flux pre-flight validation:
```bash
flux check --pre
```

This verifies:
- Kubernetes version meets Flux minimum (v1.28+)
- RBAC is properly configured
- No conflicting Flux installations exist

### Network Validation (future — KAZ-61)
When UniFi API integration is implemented, the bootstrap script will also:
- Verify K8s node IPs are static assignments (not DHCP leases)
- Verify MetalLB IP range doesn't overlap with DHCP range
- Verify DNS servers are reachable on the VLAN

## Automated Bootstrap

```bash
# Set required environment variables
export GITHUB_OWNER="your-github-username"
export GITHUB_TOKEN="github_pat_..."
export OP_SA_TOKEN="ops_..."

# Optional overrides (defaults shown)
export REPO_NAME="diixtra-forge"      # GitHub repo name
export CLUSTER_NAME="homelab"                # Cluster identifier
export CLUSTER_PATH="clusters/homelab"       # Flux watch path

# Run from the repo root
python3 scripts/bootstrap.py
```

### What the Script Does
1. **Pre-flight checks** — flux CLI, kubectl, kubeconfig context
2. **GitHub repo creation** — if repo doesn't exist
3. **Git init + push** — scaffold to the repo
4. **Bootstrap secret** — creates `op-service-account-token` in `onepassword-system`
5. **Flux bootstrap** — installs controllers with auto-update components:
   ```
   flux bootstrap github \
     --token-auth \
     --owner=$GITHUB_OWNER \
     --repository=$REPO_NAME \
     --branch=main \
     --path=$CLUSTER_PATH \
     --personal \
     --components-extra=image-reflector-controller,image-automation-controller \
     --read-write-key \
     --reconcile
   ```
6. **Reconciliation verification** — waits for all Kustomizations to report Ready

### Key Flags Explained
- `--components-extra` installs Image Automation controllers alongside the
  standard four (source, kustomize, helm, notification). These enable
  automatic container image digest updates committed to Git.
- `--read-write-key` creates a deploy key with write access. Required because
  Image Automation Controller needs to push commits (digest updates) back to
  the repository. Without this, Flux can only read.
- `--token-auth` uses the GitHub PAT for initial authentication. After
  bootstrap, Flux switches to the deploy key for ongoing Git operations.
  Your PAT is not stored or used again.

## Manual Bootstrap (if script fails mid-way)

### Step 1: Create GitHub Repo
```bash
gh repo create diixtra-forge --private \
  --description "Infrastructure monorepo — Flux CD, Terraform, IDP stack"
```

### Step 2: Push Scaffold
```bash
cd diixtra-forge
git init -b main
git add .
git commit -m "feat: initial scaffold"
git remote add origin https://github.com/$GITHUB_OWNER/diixtra-forge.git
git push -u origin main
```

### Step 3: Create Bootstrap Secret
```bash
kubectl create namespace onepassword-system
kubectl create secret generic op-service-account-token \
  --namespace=onepassword-system \
  --from-literal=token=$OP_SA_TOKEN
```

### Step 4: Bootstrap Flux
```bash
flux bootstrap github \
  --token-auth \
  --owner=$GITHUB_OWNER \
  --repository=diixtra-forge \
  --branch=main \
  --path=clusters/homelab \
  --personal \
  --components-extra=image-reflector-controller,image-automation-controller \
  --read-write-key \
  --reconcile
```

### Step 5: Verify
```bash
# All Flux controllers should be Running
kubectl get pods -n flux-system

# All Kustomizations should be Ready
flux get kustomizations

# All HelmReleases should be Ready
flux get helmreleases -A

# Image Automation should be scanning
flux get images all -A

# Check Flux logs for errors
flux logs --all-namespaces --level=error
```

## Post-Bootstrap: Auto-Update Verification

After bootstrap, verify the three automation systems are working:

### Helm Auto-Update (wildcard semver)
```bash
# HelmReleases should show installed versions
flux get helmreleases -A

# Source controller checks for new chart versions every hour
flux get sources helm -A
```

### Image Automation (digest pinning)
```bash
# Image repositories should show last scan time
flux get images repository -A

# Image policies should show latest digest
flux get images policy -A

# Image update automation should show last commit
flux get images update -A
```

### Renovate Bot (GitHub Actions)
- Check GitHub Actions tab for Renovate workflow runs
- Renovate creates grouped PRs and auto-merges patch/minor updates
- Requires `RENOVATE_TOKEN` secret in repo settings (see KAZ-56)

## Troubleshooting

### Diagnostic Hierarchy
Follow this order for any issue:
1. **Events** — `kubectl get events -n <namespace> --sort-by='.lastTimestamp'`
2. **Describe** — `kubectl describe <resource> -n <namespace>`
3. **Logs** — `kubectl logs -n <namespace> deploy/<controller>`
4. **YAML** — `kubectl get <resource> -n <namespace> -o yaml`
5. **Exec** — `kubectl exec -it <pod> -n <namespace> -- sh`

### Flux controllers not starting
```bash
kubectl get pods -n flux-system
kubectl logs -n flux-system deploy/source-controller
kubectl logs -n flux-system deploy/kustomize-controller
kubectl logs -n flux-system deploy/helm-controller
kubectl logs -n flux-system deploy/image-reflector-controller
kubectl logs -n flux-system deploy/image-automation-controller
```

### GitRepository not syncing
```bash
flux get source git flux-system
flux reconcile source git flux-system

# Check deploy key (not PAT — Flux uses deploy key after bootstrap)
kubectl get secret flux-system -n flux-system
```

### Kustomization failing
```bash
flux get kustomizations
kubectl describe kustomization infrastructure -n flux-system

# Test Kustomize build locally
kustomize build infrastructure/homelab
```

### HelmRelease stuck
```bash
flux get helmreleases --all-namespaces
flux reconcile helmrelease <name> -n <namespace>
helm history <name> -n <namespace>
```

### Image Automation not committing
```bash
# Check if image-reflector is scanning
flux get images repository -A

# Check if policy found a new digest
flux get images policy -A

# Check automation controller logs
kubectl logs -n flux-system deploy/image-automation-controller

# Common issue: deploy key doesn't have write access
# Fix: re-bootstrap with --read-write-key
```

## Recovery

### Re-bootstrap (non-destructive)
The `--reconcile` flag makes bootstrap idempotent:
```bash
flux bootstrap github --token-auth --owner=$GITHUB_OWNER \
  --repository=diixtra-forge --branch=main \
  --path=clusters/homelab --personal \
  --components-extra=image-reflector-controller,image-automation-controller \
  --read-write-key --reconcile
```

### Rollback an auto-update
```bash
# Find the automated commit
git log --oneline --author="Flux" | head -10

# Revert it
git revert <commit-hash>
git push

# Flux reconciles the revert automatically
```

### Full reset (destructive)
```bash
flux uninstall --namespace=flux-system
# Then re-run bootstrap
```
