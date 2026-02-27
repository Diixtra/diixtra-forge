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
│                               dns-cloudflare-sync.yaml, terraform-cloudflare.yaml
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
- [ ] Update `README.md` to link to new repo

### 2.6 Migrate ARC Runners to Org-Level
**Decision: Org-level runners** — a single pool of runners serving all repos in the
Diixtra org. No per-repo runner sets; org-level avoids duplicating infrastructure
as repos are added.

- [ ] Change `ARC_GITHUB_CONFIG_URL` in `clusters/homelab/vars.yaml`:
  ```yaml
  # Before
  ARC_GITHUB_CONFIG_URL: "https://github.com/Diixtra/diixtra-forge"
  # After
  ARC_GITHUB_CONFIG_URL: "https://github.com/Diixtra"
  ```
- [ ] Update `infrastructure/base/github-actions-runner/` HelmRelease values
      to use org-level GitHub App or PAT authentication (org runners require a
      GitHub App installation or PAT with `admin:org` scope — repo-level tokens
      won't work)
- [ ] Verify `homelab` and `packer` runner labels are available to all org repos
- [ ] Test workflows in `diixtra-forge` still pick up runners after the scope change
      **before** moving any workflows to new repos

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

### 3.3 Deploy via Flux GitRepository (decided)
**Decision: Second Flux `GitRepository`** — Flux natively supports watching multiple
git repos. This avoids CI sync pipelines (fragile, adds lag) and Helm chart packaging
overhead (over-engineering for static Kustomize manifests). When custom MCP server
images are added later, the same repo houses code + manifests.

- [ ] Add `GitRepository` source in `diixtra-forge` for the new repo:
  ```yaml
  # clusters/homelab/mcp-servers.yaml
  apiVersion: source.toolkit.fluxcd.io/v1
  kind: GitRepository
  metadata:
    name: mcp-servers
    namespace: flux-system
  spec:
    interval: 5m
    url: https://github.com/Diixtra/diixtra-mcp-servers
    ref:
      branch: main
  ---
  apiVersion: kustomize.toolkit.fluxcd.io/v1
  kind: Kustomization
  metadata:
    name: mcp-servers
    namespace: flux-system
  spec:
    interval: 10m
    sourceRef:
      kind: GitRepository
      name: mcp-servers
    path: ./
    prune: true
    wait: true
    dependsOn:
      - name: platform
    postBuild:
      substituteFrom:
        - kind: ConfigMap
          name: cluster-vars
  ```
- [ ] Add `mcp-servers.yaml` to `clusters/homelab/kustomization.yaml` resources
- [ ] Add matching entry for `clusters/dev/` if MCP servers deploy to dev cluster
- [ ] Remove `apps/base/mcp-servers/` from `diixtra-forge` (manifests now live in
      `diixtra-mcp-servers` and are consumed via the new GitRepository)
- [ ] Update `apps/base/kustomization.yaml` to remove mcp-servers reference

### 3.4 Add CI/CD to `diixtra-mcp-servers`
- [ ] Add Kustomize build validation workflow
- [ ] Add kubeconform schema validation
- [ ] Add `CLAUDE.md` for AI agents
- [ ] If building custom MCP server images in future: add Docker build pipeline

### 3.5 Update `diixtra-forge`
- [ ] Remove `apps/base/mcp-servers/` directory (handled by Flux GitRepository now)
- [ ] Update `apps/base/kustomization.yaml` to remove mcp-servers reference
- [ ] Add `flux-validate.yaml` matrix entry for the new GitRepository if needed
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

### 5.1 Switch Renovate to GitHub App (decided)
**Decision: Renovate GitHub App** — self-hosted Renovate was right for one repo.
With multiple repos, the GitHub App auto-discovers repos in the org, requires zero
infrastructure (no workflow, no runner time, no 1Password token), and `.renovaterc`
configs in each repo work identically.

- [ ] Install the [Renovate GitHub App](https://github.com/apps/renovate) on the
      `Diixtra` org (select all repos or specific repos)
- [ ] Add `.renovaterc` to each new repo:
  - **`diixtra-backstage`:** npm/yarn manager
  - **`diixtra-packer`:** regex manager for Packer plugin versions
  - **`diixtra-mcp-servers`:** regex manager for container image tags
- [ ] Verify Renovate App creates PRs in each repo
- [ ] Remove `renovate.yaml` self-hosted workflow from `diixtra-forge`
- [ ] Remove `RENOVATE_TOKEN` PAT from 1Password (no longer needed)
- [ ] Update `diixtra-forge/.renovaterc` — remove Backstage/Packer managers,
      keep Helm chart + Flux image version managers

### 5.2 Verify Org-Level ARC Runners (done in Phase 2.6)
- [ ] Confirm all repos can use `homelab` and `packer` runner labels
- [ ] Verify runner utilisation is acceptable with additional repos
- [ ] Consider runner group policies if repos need runner isolation later

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
Phase 0: ARC → org-level  ← PREREQUISITE: must happen first so new repos get runners
    ↓
Phase 1: Backstage     ← Zero deployment risk (image-based decoupling)  ─┐
Phase 2: Packer        ← Zero deployment risk (offline build tooling)   ─┤ parallel
    ↓                                                                     │
Phase 3: MCP Servers   ← Requires Flux GitRepository config (med risk) ←─┘
    ↓
Phase 4: Docs          ← Zero risk (no runtime impact)
    ↓
Phase 5: Cleanup       ← Renovate App, Backstage catalog, final validation
```

**Phase 0** (ARC org-level migration from Phase 2.6) is a prerequisite — new repos
need runners before their workflows can execute. Phases 1 and 2 can run in parallel
once runners are org-level. Phase 3 waits for 1+2 to validate the multi-repo pattern.

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Flux stops reconciling during migration | No Flux config changes in Phases 1-2; image references are decoupled |
| Self-hosted runners unavailable to new repos | Move to org-level ARC before moving workflows |
| Lost git history | Use `git filter-repo` to preserve per-directory history |
| Broken Renovate | Install GitHub App before removing self-hosted workflow; verify PRs appear |
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
