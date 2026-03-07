# diixtra-forge

Infrastructure monorepo for the Diixtra homelab and Diixtra platform. Manages Kubernetes clusters, cloud resources, and the Internal Developer Platform (IDP) stack.

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

| Repository | Purpose |
|-----------|---------|
| [`diixtra-backstage`](https://github.com/Diixtra/diixtra-backstage) | Backstage source code, Docker build, and local dev tooling |
| [`diixtra-docs`](https://github.com/Diixtra/diixtra-docs) | ADRs, runbooks, troubleshooting guides, and learning resources |
| [`diixtra-packer`](https://github.com/Diixtra/diixtra-packer) | Packer golden images for Proxmox VMs and Raspberry Pi K8s nodes |

## Bootstrap

See the [bootstrap runbook](https://github.com/Diixtra/diixtra-docs/blob/main/runbooks/bootstrap.md) for the
full procedure, or run `python3 scripts/bootstrap.py` for automated setup.

## Documentation

Documentation has moved to [`Diixtra/diixtra-docs`](https://github.com/Diixtra/diixtra-docs).

| Doc | Purpose |
|-----|---------|
| [Architecture](https://github.com/Diixtra/diixtra-docs/blob/main/architecture.md) | System architecture overview |
| [Bootstrap](https://github.com/Diixtra/diixtra-docs/blob/main/runbooks/bootstrap.md) | Flux bootstrap procedure |
| [TrueNAS Setup](https://github.com/Diixtra/diixtra-docs/blob/main/runbooks/truenas-setup.md) | TrueNAS CSI configuration |
| [Traefik TLS](https://github.com/Diixtra/diixtra-docs/blob/main/traefik-tls-migration.md) | Caddy→Traefik migration & ACME fix |
| [ADRs](https://github.com/Diixtra/diixtra-docs/tree/main/adr) | Architecture Decision Records (001–010) |
| [Learning](https://github.com/Diixtra/diixtra-docs/tree/main/learning) | Deep-dive educational content |
