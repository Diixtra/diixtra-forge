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

## Bootstrap

See [`docs/runbooks/bootstrap.md`](docs/runbooks/bootstrap.md) for the
full procedure, or run `python3 scripts/bootstrap.py` for automated setup.

## Documentation

| Doc | Purpose |
|-----|---------|
| [`docs/architecture.md`](docs/architecture.md) | System architecture overview |
| [`docs/runbooks/bootstrap.md`](docs/runbooks/bootstrap.md) | Flux bootstrap procedure |
| [`docs/runbooks/secrets-management.md`](docs/runbooks/secrets-management.md) | 1Password secrets lifecycle |
| [`docs/runbooks/truenas-setup.md`](docs/runbooks/truenas-setup.md) | TrueNAS CSI configuration |
| [`docs/traefik-tls-migration.md`](docs/traefik-tls-migration.md) | Caddy→Traefik migration & ACME fix |
| [`docs/adr/`](docs/adr/) | Architecture Decision Records (001–010) |
| [`docs/learning/`](docs/learning/) | Deep-dive educational content |
