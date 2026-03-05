# diixtra-forge

GitOps control plane for the Diixtra homelab. Manages Kubernetes cluster state via Flux CD — what's deployed, where, and how.

All documentation (ADRs, runbooks, learning docs, troubleshooting) has moved to [`diixtra-docs`](https://github.com/Diixtra/diixtra-docs).

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Git Repository                           │
│                    (Single Source of Truth)                      │
├───────────────────────┬─────────────────────────────────────────┤
│                       │                                         │
│   Flux CD (GitOps)    │         GitHub Actions (CI/CD)          │
│   Watches Git, syncs  │         Validates PRs, runs Terraform   │
│   to Kubernetes       │         for cloud resources             │
│                       │                                         │
├───────────┬───────────┼───────────┬─────────────────────────────┤
│           │           │           │                             │
│  Homelab  │    Dev    │ Cloudflare│    AWS      Grafana Cloud   │
│  Cluster  │  Cluster  │   (DNS)   │  (future)   (observability) │
│           │           │           │                             │
└───────────┴───────────┴───────────┴─────────────────────────────┘
```

## Deployment Layers

Flux deploys resources in dependency order:

```
infrastructure (Layer 1)  →  platform (Layer 2)  →  apps (Layer 3)
  Cilium, Traefik,             Kyverno, Alloy,       Diixtra services
  1Password Operator            Crossplane, Backstage
```

## Auto-Update Strategy

Three systems keep the homelab always-current (no users, aggressive updates):

| System               | Scope               | Frequency |
|----------------------|---------------------|-----------|
| Flux helm-controller | Helm chart versions | 1 hour    |
| Flux Image Automation| Container digests   | 5 minutes |
| Renovate Bot         | Everything else     | 6 hours   |

Rollback is always `git revert` + Flux reconciliation.

## Quick Reference

| Action | Command |
|--------|---------|
| Check Flux status | `flux get all` |
| Force reconciliation | `flux reconcile kustomization infrastructure` |
| View Flux logs | `flux logs --all-namespaces` |
| Check image updates | `flux get images all -A` |
| Check HelmReleases | `flux get helmreleases -A` |
| Validate locally | `kustomize build infrastructure/homelab` |

## Related Repositories

| Repo | Purpose |
|------|---------|
| [`diixtra-docs`](https://github.com/Diixtra/diixtra-docs) | ADRs, runbooks, learning docs, troubleshooting |

## Bootstrap

See the [bootstrap runbook](https://github.com/Diixtra/diixtra-docs/blob/main/runbooks/bootstrap.md)
in `diixtra-docs`, or run `python3 scripts/bootstrap.py` for automated setup.
