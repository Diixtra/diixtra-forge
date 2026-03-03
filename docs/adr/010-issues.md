# ADR-010 Implementation Issues

Create these GitHub issues to track the Forgejo deployment and supply chain
resilience work. Labels: `feature`, `infrastructure`, `team:kaz`.

---

## Issue 1: Deploy Forgejo on homelab cluster (ADR-010)

**Priority:** medium

### Context

ADR-010 proposes deploying Forgejo as a self-hosted git forge for repository
mirroring and supply chain resilience.

### Acceptance Criteria

- [ ] Forgejo HelmRelease in `infrastructure/base/forgejo/`
- [ ] Homelab overlay with iSCSI PVC via democratic-csi
- [ ] Traefik IngressRoute at `git.lab.kazie.co.uk` with TLS
- [ ] 1Password `OnePasswordItem` for admin credentials
- [ ] Namespace: `forgejo`
- [ ] Flux health checks passing
- [ ] Accessible via browser and git clone over HTTPS

### Technical Notes

- ~256MB RAM, lightweight Go binary
- iSCSI storage (same pattern as Backstage PostgreSQL)
- Layer 1 infrastructure — deploy before apps that may depend on it
- Forgejo Helm chart: https://codeberg.org/forgejo-contrib/forgejo-helm

---

## Issue 2: Configure git mirrors for Diixtra org repos in Forgejo

**Priority:** medium
**Depends on:** Issue 1

### Context

Once Forgejo is deployed, configure mirror repositories for all Diixtra org
repos to enable GitHub portability.

### Acceptance Criteria

- [ ] Mirror `Diixtra/diixtra-forge` → `git.lab.kazie.co.uk/Diixtra/diixtra-forge`
- [ ] Mirror all other org repos (backstage, packer, etc. as created per ADR-009)
- [ ] Auto-sync interval configured (e.g. every 15 minutes)
- [ ] GitHub PAT or App token stored in 1Password for mirror authentication
- [ ] Verify: Flux `GitRepository` can be pointed at Forgejo URL as fallback

---

## Issue 3: Configure upstream git mirrors for critical dependencies

**Priority:** high
**Depends on:** Issue 1

### High-Risk Upstream Repos to Mirror

**MCP Servers (young ecosystem, solo maintainers):**
- [ ] `grafana/mcp-grafana`
- [ ] `alexei-led/k8s-mcp-server` (solo maintainer)
- [ ] `hashicorp/terraform-mcp-server`
- [ ] `cloudflare/mcp-server-cloudflare`
- [ ] `stripe/agent-toolkit` (contains @stripe/mcp)

**Backstage Plugins (small vendor, wildcard versions):**
- [ ] Terasky Backstage plugin repos (8 plugins: crossplane-resources,
  kubernetes-ingestor, kubernetes-resources-permissions,
  scaffolder-backend-module-terasky-utils, api-docs-module-crd,
  crossplane-resources-frontend, entity-scaffolder-content, template-builder)

**Infrastructure (nice to have):**
- [ ] `democratic-csi/democratic-csi`
- [ ] `fluxcd/flux2`

---

## Issue 4: Replace npx-at-runtime MCP servers with vendored container images

**Priority:** medium

### Context

Three MCP servers pull npm packages at runtime via `npx`. If the npm package
is unpublished or npmjs.com is down, pods fail on restart.

**Affected deployments:**
- `mcp-cloudflare`: `npx @cloudflare/mcp-server-cloudflare`
- `mcp-stripe`: `npx @stripe/mcp`
- `mcp-memory`: runtime npm install

### Acceptance Criteria

- [ ] Custom Dockerfiles for each npx-based MCP server
- [ ] Dependencies baked into image at build time
- [ ] Images published to `ghcr.io/diixtra/mcp-*` (or Forgejo OCI registry)
- [ ] GitHub Actions workflow to build and push images
- [ ] Deployments updated to use vendored images instead of `node:24-alpine` + npx
- [ ] Renovate configured to watch upstream npm packages for updates

---

## Issue 5: Ensure all split repos default to private visibility (ADR-009)

**Priority:** medium

### Context

ADR-009 defines the multi-repo split. All new repositories must default to
private visibility, especially `diixtra-docs` which contains internal
architecture details, IP addresses, vault paths, and infrastructure topology.

### Acceptance Criteria

- [ ] All repos created as private: `diixtra-backstage`, `diixtra-packer`,
  `diixtra-mcp-servers`, `diixtra-docs`
- [ ] Backstage catalog and Flux `GitRepository` sources use GitHub App or
  deploy key auth (not public URL)
- [ ] Document visibility decisions in each repo's README
