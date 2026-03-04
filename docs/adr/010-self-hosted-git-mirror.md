# ADR-010: Self-Hosted Git Mirror & Supply Chain Resilience

## Status
Proposed

## Date
2026-03-03

## Context
The platform depends on a wide surface of external artefacts that could
disappear without warning:

- **16 external Helm chart registries** (GitHub Pages, OCI) — any could go
  offline or archive
- **MCP server images** from solo maintainers (`ghcr.io/alexei-led/k8s-mcp-server`,
  `ghcr.io/grafana/mcp-grafana`, `hashicorp/terraform-mcp-server`) — young
  ecosystem, high churn risk
- **9 Terasky Backstage plugins** from a single vendor — could pivot or
  disappear (versions are now pinned, but source code preservation remains
  important)
- **npx-at-runtime pattern** for Cloudflare, Stripe, and Memory MCP servers —
  if any of these npm packages is unpublished, pods fail on next restart
- **GitHub itself** — having a local mirror enables portability if we choose
  to move off GitHub or if there's an extended outage

ADR-005 Phase 2 addresses _policy enforcement_ (Kyverno, Trivy, Cosign) to
control what runs in the cluster. This ADR addresses _artefact preservation_
— ensuring we retain the source code and images needed to rebuild if upstream
disappears.

## Decision
Deploy **Forgejo** on the homelab cluster as a self-hosted git forge with
built-in repository mirroring, container registry, and package registry.

### Why Forgejo

| Option | Pros | Cons |
|--------|------|------|
| **Forgejo** | Community-governed fork of Gitea, lightweight (~256MB RAM), built-in mirror sync, OCI package registry, Helm chart available | Smaller community than Gitea; ecosystem tooling (e.g. Terraform providers) lags slightly |
| Gitea | Mature, same feature set, Helm chart available | Backed by Gitea Ltd (for-profit) — ironic dependency for an independence layer |
| GitLab CE | Full DevOps platform | 4GB+ RAM, massive overkill for mirroring |
| Bare `git clone --mirror` on TrueNAS | Zero overhead | No UI, no mirror management, no container registry |

### Why on the cluster (not bare TrueNAS)

- Slots into existing Flux GitOps workflow as another HelmRelease
- Gets Traefik IngressRoute, TLS, and 1Password secrets automatically
- Uses democratic-csi iSCSI-backed storage (same proven pattern as Backstage PostgreSQL)
- Avoids maintaining a separate management plane on TrueNAS

### Mirror Strategy

**Own repositories (GitHub portability):**
- Mirror `github.com/Diixtra/diixtra-forge` and all org repos
- Forgejo's built-in mirror feature syncs on a configurable interval
- If leaving GitHub: update Flux `GitRepository` source URL to Forgejo, done

**Critical upstream repositories (supply chain resilience):**
- MCP server source repos: `grafana/mcp-grafana`, `alexei-led/k8s-mcp-server`,
  `hashicorp/terraform-mcp-server`
- Terasky Backstage plugin repos (highest risk — small vendor, wildcard versions)
- Key infrastructure tooling repos as needed

**What git mirroring does NOT cover:**
- Pre-built container images (requires OCI registry caching — Forgejo Phase 2, below)
- npm packages pulled at runtime via npx (requires vendoring into custom images — Forgejo Phase 3, below)
- Helm charts (requires ChartMuseum or OCI cache — Forgejo Phase 2, below)

### Phased Rollout

**Forgejo Phase 1 (this ADR):** Deploy Forgejo, configure git mirrors for own
repos and critical upstream repos. Access at `git.lab.kazie.co.uk`.

**Forgejo Phase 2 (future):** Use Forgejo's built-in OCI container registry to
cache critical upstream images. Point deployments at local registry paths.

**Forgejo Phase 3 (future):** Vendor npx-based MCP servers into custom
container images with dependencies baked in. Eliminate runtime npm pulls entirely.

## Deployment

- **Namespace:** `forgejo`
- **Storage:** iSCSI PVC via democratic-csi (same as Backstage PostgreSQL)
- **Ingress:** Traefik IngressRoute at `git.lab.kazie.co.uk`
- **Secrets:** 1Password for admin credentials and GitHub mirror tokens
- **Layer:** Infrastructure (Layer 1) — other services may depend on it for
  source code access

> These are the target deployment parameters. Implementation will be tracked
> in a separate PR against `infrastructure/base/forgejo/`.

## Consequences

**Positive:**
- GitHub portability — can migrate away with a URL change in Flux
- Upstream project disappearance is survivable — source code preserved locally
- OCI registry capability provides a path to image caching without deploying Harbor
- Low resource cost (~256MB RAM, few GB disk)
- Forgejo's community governance reduces risk of the mirror tool itself being enshittified

**Negative:**
- Another service to maintain (mitigated: Flux auto-updates, Renovate watches)
- Mirror sync delay means brief window where local copy is behind upstream
- Does not solve the container image/npm package disappearance problem alone (Forgejo Phase 2-3)
- GitHub mirror tokens need periodic rotation

## References
- [ADR-005](005-auto-update-strategy.md): Auto-Update Strategy (Phase 2 supply chain security)
- [ADR-009](009-microservice-repo-migration.md): Multi-Repo Migration (repos that need mirroring)
- [Forgejo documentation](https://forgejo.org/docs/)
