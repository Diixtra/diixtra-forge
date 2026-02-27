# Microservice Repo Migration Plan

**Overall Progress:** `0%`

## Executive Summary

Migrate `diixtra-forge` from a monorepo to a multi-repo architecture. The goal is
to give each logical component its own GitHub repository with independent CI/CD,
while keeping `diixtra-forge` as the GitOps deployment control plane that Flux
watches.

## Target Repository Layout

After migration, the Diixtra GitHub org will have these repos:

| New Repo | Source Directory | Language/Tooling | Purpose |
|----------|-----------------|------------------|---------|
| `diixtra-forge` (stays) | `clusters/`, `infrastructure/`, `platform/`, `apps/` | Kustomize + Flux YAML | GitOps control plane — Flux watches this |
| `diixtra-backstage` | `backstage/` | TypeScript, Yarn 4, Docker | Internal Developer Platform (Backstage IDP) |
| `diixtra-packer` | `packer/` | HCL, Bash | Golden VM/Pi image templates |
| `diixtra-mcp-servers` | `apps/base/mcp-servers/` | YAML (Kubernetes manifests) + future app code | Model Context Protocol server deployments |
| `diixtra-docs` | `docs/` | Markdown | Architecture docs, ADRs, runbooks, learning |

### What stays in `diixtra-forge`

`diixtra-forge` remains the **single source of truth for what's deployed**:

```
diixtra-forge/                  (post-migration)
├── .github/workflows/          flux-validate.yaml, post-deploy-check.yaml,
│                               dns-cloudflare-sync.yaml, terraform-cloudflare.yaml,
│                               renovate.yaml
├── apps/                       Kustomize overlays (HelmReleases, namespaces)
│   ├── base/
│   │   ├── jupyterhub/
│   │   └── ollama/
│   ├── dev/
│   └── homelab/
├── clusters/                   Flux entry points & cluster vars
├── infrastructure/             Layer 1 (Cilium, Traefik, 1Password, CSI, etc.)
├── platform/                   Layer 2 (Kyverno, Alloy, Backstage helm, Traefik config)
├── scripts/                    Bootstrap & ops scripts
└── tests/                      Validation tests
```

---

## Phase 1: Extract Backstage into `diixtra-backstage`

**Priority:** High — largest self-contained component, most benefit for AI development

### 1.1 Create `diixtra-backstage` repository
- [ ] Create `Diixtra/diixtra-backstage` on GitHub
- [ ] Initialise with `.gitignore` (Node), `LICENSE`, and empty `README.md`

### 1.2 Migrate Backstage source code
- [ ] Copy `backstage/` contents to new repo root:
  ```
  diixtra-backstage/
  ├── .yarn/
  ├── packages/
  │   ├── app/         (React frontend)
  │   └── backend/     (Node.js backend)
  ├── package.json
  ├── tsconfig.json
  ├── Dockerfile
  ├── app-config.yaml
  └── app-config.production.yaml
  ```
- [ ] Preserve full git history for `backstage/` using `git filter-repo`:
  ```bash
  git clone diixtra-forge diixtra-backstage-temp
  cd diixtra-backstage-temp
  git filter-repo --subdirectory-filter backstage
  ```
- [ ] Push filtered history to `Diixtra/diixtra-backstage`

### 1.3 Move CI/CD workflow
- [ ] Move `.github/workflows/backstage-build.yaml` to `diixtra-backstage`
- [ ] Update workflow paths — remove `backstage/` prefix:
  ```yaml
  # Before (in monorepo)
  on:
    push:
      paths: ['backstage/**']
  # After (in own repo)
  on:
    push:
      branches: [main]
  ```
- [ ] Update Docker build context from `./backstage` to `.`
- [ ] Verify GHCR push still targets `ghcr.io/diixtra/backstage`
- [ ] Add repo secrets: none needed (uses `GITHUB_TOKEN` for GHCR)

### 1.4 Add standalone development tooling to `diixtra-backstage`
- [ ] Add `CLAUDE.md` with repo context for AI agents
- [ ] Add Renovate config (`.renovaterc`) scoped to Backstage dependencies
- [ ] Add basic test workflow (TypeScript type-check, unit tests)
- [ ] Add `docker-compose.yaml` for local development (PostgreSQL + Backstage)

### 1.5 Update `diixtra-forge` references
- [ ] Remove `backstage/` directory from `diixtra-forge`
- [ ] Remove `backstage-build.yaml` workflow from `diixtra-forge`
- [ ] Backstage Helm deployment in `platform/base/backstage/` **stays** — it
      references the container image `ghcr.io/diixtra/backstage`, not the source
- [ ] Update Backstage scaffolder templates in `platform/base/backstage/templates/`
      if any reference the monorepo path structure
- [ ] Update `README.md` to link to new repo

### 1.6 Validate
- [ ] Push a commit to `diixtra-backstage` → verify GHCR image builds
- [ ] Verify Flux Image Automation still picks up new `build-N` tags
- [ ] Verify Backstage Helm deployment in cluster is unaffected
- [ ] Verify Backstage templates still scaffold correctly

---

## Phase 2: Extract Packer Images into `diixtra-packer`

**Priority:** High — fully self-contained, runs on specialised `packer` runners

### 2.1 Create `diixtra-packer` repository
- [ ] Create `Diixtra/diixtra-packer` on GitHub
- [ ] Initialise with `.gitignore` (Packer output, logs), `LICENSE`

### 2.2 Migrate Packer source
- [ ] Copy `packer/` contents to new repo root:
  ```
  diixtra-packer/
  ├── arm-debian/          (Raspberry Pi)
  ├── proxmox-debian/      (Debian worker)
  ├── proxmox-ubuntu/      (Ubuntu control plane)
  ├── proxmox-gpu/         (NVIDIA GPU worker)
  ├── scripts/
  │   ├── provision-k8s-node.sh
  │   └── provision-gpu-node.sh
  └── variables.auto.pkrvars.hcl
  ```
- [ ] Preserve git history with `git filter-repo --subdirectory-filter packer`
- [ ] Push filtered history to `Diixtra/diixtra-packer`

### 2.3 Move CI/CD workflows
- [ ] Move `packer-proxmox-build.yaml` to `diixtra-packer`
- [ ] Move `packer-pi-build.yaml` to `diixtra-packer`
- [ ] Update path triggers — remove `packer/` prefix:
  ```yaml
  # Before
  paths: ["packer/proxmox-ubuntu/**"]
  # After
  paths: ["proxmox-ubuntu/**"]
  ```
- [ ] Update `working-directory: packer` → remove or change to `.`
- [ ] Add repo secret: `OP_SERVICE_ACCOUNT_TOKEN` (needed for 1Password CLI)

### 2.4 Add standalone tooling to `diixtra-packer`
- [ ] Add `CLAUDE.md` with repo context for AI agents
- [ ] Add Renovate config (`.renovaterc`) for Packer plugin versions
- [ ] Add validation workflow: `packer validate` on PR for all templates
- [ ] Add `packer fmt --check` lint step

### 2.5 Update `diixtra-forge` references
- [ ] Remove `packer/` directory from `diixtra-forge`
- [ ] Remove `packer-proxmox-build.yaml` and `packer-pi-build.yaml` from `diixtra-forge`
- [ ] Remove `packer-console.log` and `packer-debug.log` from `diixtra-forge` root
- [ ] The `packer-runner` ARC runner set in `infrastructure/base/packer-runner/`
      **stays** — it's cluster infrastructure that provides the runner, not Packer source
- [ ] Update `ARC_GITHUB_CONFIG_URL` in `clusters/homelab/vars.yaml`:
  - Currently scoped to `diixtra-forge` repo — will need to become org-level
    (`https://github.com/Diixtra`) or the runner set needs to serve both repos
- [ ] Update `README.md` to link to new repo

### 2.6 Handle ARC Runner Scope Change
- [ ] **Decision required:** Org-level runners vs. per-repo runner sets
  - **Option A (recommended):** Change `ARC_GITHUB_CONFIG_URL` to
    `https://github.com/Diixtra` (org-level) so runners serve all repos
  - **Option B:** Deploy a second `arc-runner-set` for `diixtra-packer`
- [ ] Update `infrastructure/base/github-actions-runner/` accordingly
- [ ] Update Packer workflows `runs-on` labels if runner names change

### 2.7 Validate
- [ ] Trigger `packer-proxmox-build.yaml` via workflow_dispatch in new repo
- [ ] Verify Proxmox template creation succeeds
- [ ] Verify Pi image build succeeds
- [ ] Verify `homelab` self-hosted runner can be used from new repo

---

## Phase 3: Extract MCP Servers into `diixtra-mcp-servers`

**Priority:** Medium — currently pure Kubernetes manifests, but likely to grow with
custom server code

### 3.1 Create `diixtra-mcp-servers` repository
- [ ] Create `Diixtra/diixtra-mcp-servers` on GitHub

### 3.2 Migrate MCP server definitions
- [ ] Copy `apps/base/mcp-servers/` contents to new repo:
  ```
  diixtra-mcp-servers/
  ├── kubernetes/        (deployment, rbac, service)
  ├── terraform/         (deployment, service)
  ├── grafana/           (deployment, onepassword-item, service)
  ├── cloudflare/        (deployment, onepassword-item, service)
  ├── stripe/            (deployment, onepassword-item, service)
  ├── memory/            (deployment, pvc, service)
  ├── kustomization.yaml
  └── namespace.yaml
  ```
- [ ] Preserve git history with `git filter-repo --subdirectory-filter apps/base/mcp-servers`

### 3.3 Decide deployment model
- [ ] **Decision required:** How Flux consumes the new repo
  - **Option A (recommended for now):** Continue embedding manifests in
    `diixtra-forge` under `apps/base/mcp-servers/` — treat `diixtra-mcp-servers`
    as the development repo and sync manifests via CI or Flux GitRepository
  - **Option B:** Add a second Flux `GitRepository` source pointing to
    `diixtra-mcp-servers` and a corresponding Flux Kustomization
  - **Option C:** Package MCP manifests as a Helm chart published to GHCR,
    reference via HelmRelease in `diixtra-forge`
- [ ] Implement chosen deployment model

### 3.4 Add CI/CD to `diixtra-mcp-servers`
- [ ] Add Kustomize build validation workflow
- [ ] Add kubeconform schema validation
- [ ] Add `CLAUDE.md` for AI agents
- [ ] If building custom MCP server images in future: add Docker build pipeline

### 3.5 Update `diixtra-forge`
- [ ] Based on 3.3 decision, either:
  - Keep `apps/base/mcp-servers/` as-is (synced from external repo), or
  - Replace with Flux `GitRepository` + `Kustomization` pointing to new repo, or
  - Replace with `HelmRelease` referencing OCI chart
- [ ] Update `README.md`

### 3.6 Validate
- [ ] Verify MCP server pods remain running after migration
- [ ] Verify 1Password secrets still sync (OnePasswordItem resources)
- [ ] Test adding a new MCP server in the new repo flows through to deployment

---

## Phase 4: Extract Documentation into `diixtra-docs`

**Priority:** Low — no runtime impact, purely organisational

### 4.1 Create `diixtra-docs` repository
- [ ] Create `Diixtra/diixtra-docs` on GitHub

### 4.2 Migrate documentation
- [ ] Copy `docs/` contents to new repo:
  ```
  diixtra-docs/
  ├── adr/               (Architecture Decision Records 001-009)
  ├── learning/          (Deep-dive educational content)
  ├── runbooks/          (Bootstrap, disaster recovery, TrueNAS)
  └── troubleshooting/   (Operational troubleshooting guides)
  ```
- [ ] Preserve git history with `git filter-repo --subdirectory-filter docs`
- [ ] Move `PLAN.md` and `MIGRATION-PLAN.md` to the docs repo

### 4.3 Update cross-references
- [ ] Update `diixtra-forge/README.md` — replace doc links with links to `diixtra-docs`
- [ ] Update any ADR cross-references between repos
- [ ] Add a `README.md` to `diixtra-docs` with navigation structure

### 4.4 Remove from `diixtra-forge`
- [ ] Remove `docs/` directory
- [ ] Remove `PLAN.md` (after migration is complete)
- [ ] Keep a minimal `README.md` in `diixtra-forge` with:
  - Architecture diagram
  - Quick reference commands
  - Links to `diixtra-docs` for detailed documentation

### 4.5 Validate
- [ ] Verify all documentation links resolve correctly
- [ ] Verify ADR numbering is consistent

---

## Phase 5: Post-Migration Cleanup & Configuration

### 5.1 Update Renovate Bot
- [ ] **`diixtra-forge`:** Update `.renovaterc` — remove Backstage and Packer managers
- [ ] **`diixtra-backstage`:** Add `.renovaterc` with npm/yarn manager
- [ ] **`diixtra-packer`:** Add `.renovaterc` with Packer and Terraform managers
- [ ] **Decision:** Run Renovate per-repo (GitHub App) or keep self-hosted?
  - Self-hosted Renovate in `diixtra-forge` currently scans one repo
  - Need to update `RENOVATE_REPOSITORIES` to include all repos, or
  - Switch to Renovate GitHub App (zero-config, runs on their infrastructure)

### 5.2 Update GitHub Actions Runners (ARC)
- [ ] Migrate `ARC_GITHUB_CONFIG_URL` from repo-level to org-level:
  ```yaml
  # clusters/homelab/vars.yaml
  # Before
  ARC_GITHUB_CONFIG_URL: "https://github.com/Diixtra/diixtra-forge"
  # After
  ARC_GITHUB_CONFIG_URL: "https://github.com/Diixtra"
  ```
- [ ] Update ARC runner set to serve org-level runners
- [ ] Verify `homelab` and `packer` runner labels are available to all repos
- [ ] Test workflows in each repo can pick up self-hosted runners

### 5.3 Update Flux Image Automation
- [ ] Verify image update automation still works for Backstage:
  - `ImageRepository` watches `ghcr.io/diixtra/backstage`
  - Image source is decoupled from code source — should work unchanged
- [ ] If MCP servers get their own images, add `ImageRepository` and
      `ImagePolicy` resources for each

### 5.4 Update Backstage Catalog
- [ ] Update Backstage `catalog-info.yaml` entities to reflect new repo locations
- [ ] Update scaffolder templates if they reference the monorepo file structure
- [ ] Add `catalog-info.yaml` to each new repo for Backstage discovery

### 5.5 Secrets & Permissions
- [ ] Add `OP_SERVICE_ACCOUNT_TOKEN` secret to repos that need it:
  - `diixtra-packer` (Packer builds need Proxmox token from 1Password)
  - `diixtra-backstage` (if any workflow needs secrets)
- [ ] Verify `GITHUB_TOKEN` permissions (packages:write) for GHCR push in `diixtra-backstage`
- [ ] Review repo visibility settings (public vs private) for each new repo

### 5.6 Final Validation Checklist
- [ ] All Flux Kustomizations reconcile cleanly (`flux get ks -A`)
- [ ] All HelmReleases are Ready (`flux get hr -A`)
- [ ] Backstage image builds and deploys from `diixtra-backstage`
- [ ] Packer builds run from `diixtra-packer`
- [ ] MCP server pods are healthy
- [ ] Renovate creates PRs in all repos
- [ ] Self-hosted runners serve all repos
- [ ] DNS sync workflow still triggers correctly
- [ ] Post-deploy health check still runs on `diixtra-forge` pushes
- [ ] No dangling references to old paths in any repo

---

## Migration Order & Dependencies

```
Phase 1: Backstage     ← Zero deployment risk (image-based decoupling)
    ↓
Phase 2: Packer        ← Zero deployment risk (offline build tooling)
    ↓
Phase 3: MCP Servers   ← Requires Flux config change (medium risk)
    ↓
Phase 4: Docs          ← Zero risk (no runtime impact)
    ↓
Phase 5: Cleanup       ← Consolidate cross-cutting concerns
```

Phases 1 and 2 can be done in parallel — they have no dependencies on each other.
Phase 3 should wait until the ARC runner scope change (Phase 2.6 / 5.2) is settled.

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Flux stops reconciling during migration | No Flux config changes in Phases 1-2; image references are decoupled |
| Self-hosted runners unavailable to new repos | Move to org-level ARC before moving workflows |
| Lost git history | Use `git filter-repo` to preserve per-directory history |
| Broken Renovate | Test Renovate in each new repo before removing from monorepo |
| Backstage image stops building | Keep old workflow in monorepo until new one is confirmed working |
| Secrets missing in new repos | Audit 1Password service account scope; add secrets before moving workflows |

## Rollback Strategy

Each phase is independently reversible:
- **Backstage:** Copy source back, restore workflow — Helm deployment never changed
- **Packer:** Copy templates back, restore workflows
- **MCP Servers:** Restore `apps/base/mcp-servers/` in `diixtra-forge`
- **Docs:** Copy docs back

The GitOps control plane (`diixtra-forge`) is the last thing to change in each
phase, and the changes are always additive removal of source (not deployment
config). Flux continues watching the same repo for deployment state.

## Success Criteria

1. Each repo builds, tests, and deploys independently
2. AI agents can clone a single repo and have full context for their domain
3. No cross-repo dependencies for day-to-day development
4. Flux reconciliation is unaffected — same deployment state, different source layout
5. CI/CD pipeline times are equal or better than monorepo
6. Renovate keeps all repos up to date
