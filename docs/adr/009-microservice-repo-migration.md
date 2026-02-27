# ADR-009: Migrate from Monorepo to Multi-Repo Microservice Architecture

## Status
Proposed

## Date
2026-02-27

## Context
ADR-002 established the monorepo (`diixtra-forge`) as the right choice for a solo
operator. The platform has since grown to include Backstage IDP, MCP servers,
Packer golden images, and multiple CI/CD pipelines — all in one repo.

Two drivers now favour splitting:
1. **AI-assisted development** — AI agents work best on focused, self-contained
   repos with clear boundaries. A monorepo with mixed Kubernetes YAML, TypeScript,
   HCL, and Packer templates increases context noise and error rates.
2. **Independent release cadence** — Backstage builds and MCP server images have
   no reason to be gated by infrastructure manifest changes, and vice versa.

## Decision
Split the monorepo into **purpose-specific repositories** while keeping the
GitOps control plane (`diixtra-forge`) as the deployment source of truth.

### Target Repositories

| Repo | Contents | Purpose |
|------|----------|---------|
| `diixtra-forge` (stays) | clusters, infrastructure, platform, apps | GitOps control plane — Flux watches this |
| `diixtra-backstage` | Backstage IDP source (TypeScript) | Internal Developer Platform |
| `diixtra-packer` | Packer templates (HCL, Bash) | Golden VM/Pi images |
| `diixtra-mcp-servers` | MCP server manifests + future code | Model Context Protocol servers |
| `diixtra-docs` | ADRs, runbooks, learning docs | Documentation |

### Key Design Decisions

1. **ARC runners: org-level** — A single pool of self-hosted runners serving all
   repos in the Diixtra org. Avoids duplicating infrastructure per-repo.

2. **MCP deployment: Flux GitRepository** — Flux natively watches the
   `diixtra-mcp-servers` repo via a second `GitRepository` source. No CI sync
   pipelines or Helm chart packaging needed.

3. **Renovate: GitHub App** — Replace self-hosted Renovate with the Renovate
   GitHub App. Auto-discovers repos, zero infrastructure to maintain. Each repo
   keeps its own `.renovaterc`.

## Supersedes
ADR-002 (Monorepo for All Infrastructure). The migration path trigger cited in
ADR-002 ("team exceeds ~5 engineers, or different layers need isolated access
controls") now includes "AI agents acting as parallel contributors."

## Consequences

**Positive:**
- AI agents get focused, self-contained repos with clear boundaries
- Independent CI/CD — Backstage TypeScript builds don't block Packer HCL changes
- Smaller blast radius per repo
- Cleaner dependency graph

**Negative:**
- Cross-repo changes require coordinating multiple PRs
- Flux config gains a second `GitRepository` source (minor complexity)
- Must maintain org-level runner authentication (GitHub App or PAT with `admin:org`)

## References
- [MIGRATION-PLAN.md](../../MIGRATION-PLAN.md) — Detailed phased execution plan
