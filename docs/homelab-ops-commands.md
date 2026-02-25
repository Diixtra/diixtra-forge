# Homelab Operations Commands

Quick reference for all operational commands used to manage the diixtra-forge homelab cluster.

> These commands are also available as Warp Drive workflows (YAML exports) for import into Raycast via the [Warp Drive Sync extension](https://github.com/Diixtra/raycast-warp-drive-sync).

---

## 1. Flux CD — Daily Operations

| Name | Command | Tags |
|------|---------|------|
| flux-status | `flux get all` | flux |
| flux-kustomizations | `flux get kustomizations` | flux |
| flux-helmreleases | `flux get helmreleases -A` | flux |
| flux-images-all | `flux get images all -A` | flux |
| flux-logs | `flux logs --all-namespaces` | flux |
| flux-logs-errors | `flux logs --all-namespaces --level=error` | flux |
| flux-source-git | `flux get source git flux-system` | flux |
| flux-sources-helm | `flux get sources helm -A` | flux |

## 2. Flux CD — Reconciliation

| Name | Command | Tags |
|------|---------|------|
| flux-reconcile-all | `python3 scripts/ops/force-reconcile-all.py` | flux, reconcile |
| flux-reconcile-all-helm | `python3 scripts/ops/force-reconcile-all.py --include-helm` | flux, reconcile |
| flux-reconcile-git | `flux reconcile source git flux-system` | flux, reconcile |
| flux-reconcile-infra | `flux reconcile kustomization infrastructure` | flux, reconcile |
| flux-reconcile-platform | `flux reconcile kustomization platform` | flux, reconcile |
| flux-reconcile-hr | `flux reconcile helmrelease {{name}} -n {{namespace}}` | flux, reconcile |

## 3. Cluster Health & Diagnostics

| Name | Command | Tags |
|------|---------|------|
| cluster-health | `python3 scripts/ops/validate-cluster-health.py` | cluster, diagnostics |
| cluster-health-verbose | `python3 scripts/ops/validate-cluster-health.py --verbose` | cluster, diagnostics |
| cluster-health-json | `python3 scripts/ops/validate-cluster-health.py --json` | cluster, diagnostics |
| k8s-events | `kubectl get events -n {{namespace}} --sort-by='.lastTimestamp'` | kubectl, diagnostics |
| k8s-bad-pods | `kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded` | kubectl, diagnostics |
| k8s-nodes | `kubectl get nodes -o wide` | kubectl, diagnostics |
| network-preflight | `python3 scripts/network_checks.py` | network, diagnostics |

## 4. Secrets Management (1Password)

| Name | Command | Tags |
|------|---------|------|
| op-rotate-token | `python3 scripts/ops/rotate-1password-token.py` | 1password, secrets |
| op-rotate-dry-run | `python3 scripts/ops/rotate-1password-token.py --dry-run` | 1password, secrets |
| op-check-items | `kubectl get onepassworditems -A` | 1password, secrets |
| op-check-operator | `kubectl logs -n onepassword-system deploy/onepassword-connect-operator` | 1password, secrets |
| op-force-refresh | `kubectl delete secret {{name}} -n {{namespace}}` | 1password, secrets |
| op-verify-secret | `kubectl get secret {{name}} -n {{namespace}} -o jsonpath='{.data}' \| python3 -c "import sys,json; [print(k) for k in json.load(sys.stdin)]"` | 1password, secrets |
| op-secret-hash | `kubectl get secret {{name}} -n {{namespace}} -o jsonpath='{.data.credential}' \| base64 -d \| sha256sum` | 1password, secrets |
| op-bootstrap-secret | `kubectl create secret generic op-service-account-token --namespace=onepassword-system --from-literal=token={{token}}` | 1password, secrets |

## 5. Kustomize Validation (Local)

| Name | Command | Tags |
|------|---------|------|
| kustomize-infra | `kustomize build infrastructure/homelab` | kustomize, validation |
| kustomize-infra-crds | `kustomize build infrastructure/homelab/crds` | kustomize, validation |
| kustomize-platform-crds | `kustomize build platform/homelab/crds` | kustomize, validation |
| kustomize-platform-policies | `kustomize build platform/homelab/policies` | kustomize, validation |
| kustomize-dev | `kustomize build infrastructure/dev` | kustomize, validation |

## 6. Packer Golden Images

| Name | Command | Tags |
|------|---------|------|
| packer-init-all | `cd packer && packer init proxmox-ubuntu/ && packer init proxmox-debian/ && packer init proxmox-gpu/ && packer init arm-debian/` | packer, images |
| packer-build-ubuntu | `packer build -var-file="variables.auto.pkrvars.hcl" proxmox-ubuntu/` | packer, images |
| packer-build-debian | `packer build -var-file="variables.auto.pkrvars.hcl" proxmox-debian/` | packer, images |
| packer-build-gpu | `packer build -var-file="variables.auto.pkrvars.hcl" proxmox-gpu/` | packer, images |
| packer-build-pi | `sudo packer build arm-debian/` | packer, images |
| packer-build-pi-ci | `gh workflow run packer-pi-build.yaml` | packer, images, ci |
| packer-build-proxmox-ci-all | `gh workflow run "Packer — Build Proxmox K8s Images" -f template=all` | packer, images, ci |
| packer-build-proxmox-ci | `gh workflow run "Packer — Build Proxmox K8s Images" -f template={{template}}` | packer, images, ci |
| packer-validate | `packer validate -var-file="variables.auto.pkrvars.hcl" {{template_dir}}/` | packer, images |
| packer-token-from-1p | `export PKR_VAR_proxmox_api_token_secret=$(op read "op://Homelab/proxmox-packer-token/credential")` | packer, 1password |

## 7. Bootstrap (One-Time / Recovery)

| Name | Command | Tags |
|------|---------|------|
| bootstrap-full | `export GITHUB_OWNER="Diixtra" && export GITHUB_TOKEN="{{pat}}" && export OP_SA_TOKEN="{{token}}" && python3 scripts/bootstrap.py` | bootstrap, flux |
| bootstrap-flux | `flux bootstrap github --token-auth --owner=$GITHUB_OWNER --repository=diixtra-forge --branch=main --path=clusters/homelab --personal --components-extra=image-reflector-controller,image-automation-controller --read-write-key --reconcile` | bootstrap, flux |
| bootstrap-verify | `kubectl get pods -n flux-system && flux get kustomizations && flux get helmreleases -A && flux get images all -A` | bootstrap, flux |
| flux-preflight | `flux check --pre` | bootstrap, flux |
| flux-reset | `flux uninstall --namespace=flux-system` | bootstrap, flux |

## 8. Git Rollback (Auto-Update Recovery)

| Name | Command | Tags |
|------|---------|------|
| flux-auto-commits | `git log --oneline --author="Flux" \| head -10` | git, rollback |
| rollback-auto-update | `git revert {{commit_hash}} && git push` | git, rollback |

## 9. Troubleshooting Specific Components

| Name | Command | Tags |
|------|---------|------|
| debug-traefik | `kubectl logs -n traefik-system deploy/traefik` | debug, traefik |
| debug-cilium | `kubectl -n kube-system exec ds/cilium -- cilium status --brief` | debug, cilium |
| debug-democratic-csi-nfs | `kubectl logs -n democratic-csi deploy/truenas-nfs-democratic-csi-controller -c csi-driver` | debug, storage |
| debug-flux-source | `kubectl logs -n flux-system deploy/source-controller` | debug, flux |
| debug-flux-kustomize | `kubectl logs -n flux-system deploy/kustomize-controller` | debug, flux |
| debug-flux-helm | `kubectl logs -n flux-system deploy/helm-controller` | debug, flux |
| debug-flux-image-reflect | `kubectl logs -n flux-system deploy/image-reflector-controller` | debug, flux |
| debug-flux-image-auto | `kubectl logs -n flux-system deploy/image-automation-controller` | debug, flux |
| helm-history | `helm history {{name}} -n {{namespace}}` | debug, helm |
| pvc-status | `kubectl get pvc -A` | debug, storage |
| describe-onepassworditem | `kubectl describe onepassworditem {{name}} -n {{namespace}}` | debug, 1password |

## 10. Node Storage Setup (New Node Prep)

| Name | Command | Tags |
|------|---------|------|
| node-prep-amd64 | `sudo apt-get update && sudo apt-get install -y nfs-common open-iscsi lsscsi sg3-utils multipath-tools scsitools && sudo systemctl enable --now iscsid && sudo systemctl enable --now multipathd` | node-prep, storage |
| node-prep-pi | `sudo apt-get update && sudo apt-get install -y nfs-common open-iscsi && sudo systemctl enable --now iscsid` | node-prep, storage |
| verify-nfs | `showmount -e 10.2.0.232` | verify, storage |
| verify-iscsi | `sudo iscsiadm -m discovery -t sendtargets -p 10.2.0.232` | verify, storage |
| truenas-api-check | `curl -k -H "Authorization: Bearer {{api_key}}" https://10.2.0.232/api/v2.0/system/version` | verify, storage |

## 11. Git / PR Workflow

| Name | Command | Tags |
|------|---------|------|
| forge-new-branch | `git checkout main && git pull && git checkout -b james/kaz-{{issue_number}}-{{description}}` | git, workflow |
| forge-pr | `gh pr create --title "{{title}} (KAZ-{{issue_number}})" --body "## Summary\n\n## Test plan\n"` | git, workflow |

---

**Total: 69 commands across 11 categories**

### Template Variables

Commands using `{{variable}}` placeholders require substitution before running:

| Variable | Description |
|----------|-------------|
| `{{name}}` | Kubernetes resource name |
| `{{namespace}}` | Kubernetes namespace |
| `{{commit_hash}}` | Git commit SHA |
| `{{pat}}` | GitHub Personal Access Token |
| `{{token}}` | 1Password Service Account token |
| `{{issue_number}}` | Linear issue number (e.g., `75`) |
| `{{description}}` | Short kebab-case description |
| `{{template}}` | Packer template name (ubuntu, debian, gpu) |
| `{{template_dir}}` | Packer template directory |
| `{{api_key}}` | TrueNAS API key |
| `{{title}}` | PR title |
