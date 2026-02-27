# Microservice Migration — GitHub Issues

Create a GitHub Project called **"Microservice Migration"** under the Diixtra org,
then create the following issues. Each issue maps to a sub-task in `MIGRATION-PLAN.md`.

**Labels to create first:**
- `migration` (purple `#7057ff`) — all migration tasks
- `phase-0` (green `#0e8a16`) — Prerequisites
- `phase-1` (blue `#1d76db`) — Backstage extraction
- `phase-2` (yellow `#fbca04`) — Packer extraction
- `phase-3` (red `#d93f0b`) — MCP Servers extraction
- `phase-4` (light green `#c2e0c6`) — Docs extraction
- `phase-5` (pink `#e99695`) — Post-migration cleanup

---

## Phase 0: Prerequisites

### Issue: Migrate ARC runners to org-level
**Labels:** `migration`, `phase-0`

Migrate GitHub Actions Runner Controller (ARC) from repo-level to org-level so all
repos in the Diixtra org can use self-hosted runners. **This is a prerequisite for
all other phases.**

**Tasks:**
- [ ] Change `ARC_GITHUB_CONFIG_URL` in `clusters/homelab/vars.yaml` from `https://github.com/Diixtra/diixtra-forge` to `https://github.com/Diixtra`
- [ ] Update `infrastructure/base/github-actions-runner/` HelmRelease values for org-level authentication (GitHub App or PAT with `admin:org`)
- [ ] Verify `homelab` and `packer` runner labels are available to all org repos
- [ ] Test existing `diixtra-forge` workflows still pick up runners after scope change
- [ ] Document the new authentication method

**Acceptance Criteria:**
- `runs-on: homelab` and `runs-on: packer` work in any Diixtra org repo
- Existing `diixtra-forge` workflows are unaffected

---

## Phase 1: Extract Backstage

### Issue: Create diixtra-backstage repository
**Labels:** `migration`, `phase-1`

- [ ] Create `Diixtra/diixtra-backstage` repo on GitHub (private)
- [ ] Initialise with `.gitignore` (Node), `LICENSE`, empty `README.md`

---

### Issue: Migrate Backstage source code with history
**Labels:** `migration`, `phase-1`

Extract `backstage/` from `diixtra-forge` with full git history preserved.

- [ ] Clone `diixtra-forge` to temp directory
- [ ] Run `git filter-repo --subdirectory-filter backstage`
- [ ] Push filtered history to `Diixtra/diixtra-backstage`
- [ ] Verify `yarn install && yarn build:all` succeeds in new repo

**Target structure:** `.yarn/`, `packages/app/`, `packages/backend/`, `package.json`,
`tsconfig.json`, `Dockerfile`, `app-config.yaml`, `app-config.production.yaml`

---

### Issue: Move Backstage CI/CD workflow to new repo
**Labels:** `migration`, `phase-1`

- [ ] Copy `backstage-build.yaml` to `diixtra-backstage/.github/workflows/build.yaml`
- [ ] Update trigger — remove `paths: ['backstage/**']`, use `branches: [main]`
- [ ] Update Docker build context from `./backstage` to `.`
- [ ] Verify GHCR push still targets `ghcr.io/diixtra/backstage`
- [ ] Verify `GITHUB_TOKEN` has `packages:write` in new repo
- [ ] Test: push commit → image builds and pushes to GHCR

**Acceptance:** Image `ghcr.io/diixtra/backstage:build-N` published from new repo,
multi-platform build works, runs on `homelab` runner.

---

### Issue: Add standalone tooling to diixtra-backstage
**Labels:** `migration`, `phase-1`

- [ ] Add `CLAUDE.md` with repo context for AI agents
- [ ] Add `.renovaterc` scoped to npm/yarn dependencies
- [ ] Add test workflow (TypeScript type-check, unit tests)
- [ ] Add `docker-compose.yaml` for local development (PostgreSQL + Backstage)
- [ ] Add PR template

---

### Issue: Clean up Backstage from diixtra-forge
**Labels:** `migration`, `phase-1`

- [ ] Remove `backstage/` directory from `diixtra-forge`
- [ ] Remove `backstage-build.yaml` workflow from `diixtra-forge`
- [ ] Verify `platform/base/backstage/` Helm deployment **stays** (references image, not source)
- [ ] Check scaffolder templates in `platform/base/backstage/templates/` for monorepo path references
- [ ] Update `diixtra-forge/README.md` to link to `diixtra-backstage`

---

### Issue: Validate Backstage migration end-to-end
**Labels:** `migration`, `phase-1`

- [ ] Push test commit to `diixtra-backstage` → verify GHCR image builds
- [ ] Verify Flux Image Automation picks up new `build-N` tags
- [ ] Verify Backstage Helm deployment in cluster is unaffected
- [ ] Verify scaffolder templates still create PRs correctly
- [ ] Verify Backstage UI accessible at `backstage.lab.kazie.co.uk`

---

## Phase 2: Extract Packer

### Issue: Create diixtra-packer repository
**Labels:** `migration`, `phase-2`

- [ ] Create `Diixtra/diixtra-packer` repo on GitHub (private)
- [ ] Initialise with `.gitignore` (Packer output, logs, crash logs), `LICENSE`

---

### Issue: Migrate Packer source code with history
**Labels:** `migration`, `phase-2`

- [ ] Clone `diixtra-forge`, run `git filter-repo --subdirectory-filter packer`
- [ ] Push filtered history to `Diixtra/diixtra-packer`
- [ ] Verify `packer validate` succeeds for all templates

**Target structure:** `arm-debian/`, `proxmox-debian/`, `proxmox-ubuntu/`,
`proxmox-gpu/`, `scripts/`, `variables.auto.pkrvars.hcl`

---

### Issue: Move Packer CI/CD workflows to new repo
**Labels:** `migration`, `phase-2`

- [ ] Copy `packer-proxmox-build.yaml` to `diixtra-packer/.github/workflows/`
- [ ] Copy `packer-pi-build.yaml` to `diixtra-packer/.github/workflows/`
- [ ] Update path triggers — remove `packer/` prefix
- [ ] Remove `working-directory: packer` from all steps
- [ ] Add `OP_SERVICE_ACCOUNT_TOKEN` as repo secret in `diixtra-packer`
- [ ] Test: trigger Proxmox build via `workflow_dispatch`

**Acceptance:** All 4 builds succeed (Ubuntu, Debian, GPU, Pi), run on `packer` runner.

---

### Issue: Add standalone tooling to diixtra-packer
**Labels:** `migration`, `phase-2`

- [ ] Add `CLAUDE.md` with repo context for AI agents
- [ ] Add `.renovaterc` for Packer plugin versions
- [ ] Add validation workflow on PR: `packer validate` for all templates
- [ ] Add `packer fmt --check` lint step
- [ ] Add PR template

---

### Issue: Clean up Packer from diixtra-forge
**Labels:** `migration`, `phase-2`

- [ ] Remove `packer/` directory from `diixtra-forge`
- [ ] Remove `packer-proxmox-build.yaml` and `packer-pi-build.yaml` workflows
- [ ] Remove `packer-console.log` and `packer-debug.log` from repo root if present
- [ ] Verify `infrastructure/base/packer-runner/` ARC runner set **stays**
- [ ] Update `diixtra-forge/README.md` to link to `diixtra-packer`

---

## Phase 3: Extract MCP Servers

### Issue: Create diixtra-mcp-servers repository
**Labels:** `migration`, `phase-3`

- [ ] Create `Diixtra/diixtra-mcp-servers` repo on GitHub
- [ ] Run `git filter-repo --subdirectory-filter apps/base/mcp-servers`
- [ ] Push filtered history to new repo
- [ ] Verify `kustomize build .` succeeds

**Target structure:** `kubernetes/`, `terraform/`, `grafana/`, `cloudflare/`,
`stripe/`, `memory/`, `kustomization.yaml`, `namespace.yaml`

---

### Issue: Add Flux GitRepository source for MCP servers
**Labels:** `migration`, `phase-3`

Configure Flux to watch `diixtra-mcp-servers` via a second GitRepository source.

- [ ] Create `clusters/homelab/mcp-servers.yaml` with `GitRepository` + `Kustomization` (see MIGRATION-PLAN.md Phase 3.3 for full YAML)
- [ ] Add `mcp-servers.yaml` to `clusters/homelab/kustomization.yaml` resources
- [ ] Add matching config for `clusters/dev/` if applicable
- [ ] Remove `apps/base/mcp-servers/` from `diixtra-forge`
- [ ] Update `apps/base/kustomization.yaml` to remove mcp-servers reference
- [ ] Update `flux-validate.yaml` matrix if needed

**Acceptance:** `flux get source git mcp-servers` Ready, all MCP pods running,
OnePasswordItem secrets syncing.

---

### Issue: Add CI/CD to diixtra-mcp-servers
**Labels:** `migration`, `phase-3`

- [ ] Add Kustomize build validation workflow (on PR)
- [ ] Add kubeconform schema validation
- [ ] Add `CLAUDE.md` for AI agent context
- [ ] Add `.renovaterc` for container image tag updates

---

### Issue: Validate MCP server migration end-to-end
**Labels:** `migration`, `phase-3`

- [ ] Verify all 6 MCP server pods running (kubernetes, terraform, grafana, cloudflare, stripe, memory)
- [ ] Verify 1Password secrets sync (OnePasswordItem resources resolved)
- [ ] Test: add a new MCP server in `diixtra-mcp-servers` → verify Flux deploys it
- [ ] Verify Flux variable substitution works (cluster-vars ConfigMap)

---

## Phase 4: Extract Documentation

### Issue: Create diixtra-docs repository and migrate
**Labels:** `migration`, `phase-4`

- [ ] Create `Diixtra/diixtra-docs` repo on GitHub
- [ ] Run `git filter-repo --subdirectory-filter docs`
- [ ] Push filtered history to new repo
- [ ] Add `README.md` with navigation structure
- [ ] Move `MIGRATION-PLAN.md` to docs repo (after migration complete)

**Target structure:** `adr/` (001-009), `learning/`, `runbooks/`, `troubleshooting/`

---

### Issue: Clean up docs from diixtra-forge and update links
**Labels:** `migration`, `phase-4`

- [ ] Remove `docs/` directory from `diixtra-forge`
- [ ] Update `diixtra-forge/README.md` — replace doc links with links to `diixtra-docs`
- [ ] Update any ADR cross-references between repos
- [ ] Keep minimal `README.md` with architecture diagram, quick reference, and links

---

## Phase 5: Post-Migration Cleanup

### Issue: Switch Renovate from self-hosted to GitHub App
**Labels:** `migration`, `phase-5`

- [ ] Install [Renovate GitHub App](https://github.com/apps/renovate) on the Diixtra org
- [ ] Verify Renovate App creates PRs in all repos (backstage, packer, mcp-servers, forge)
- [ ] Remove `renovate.yaml` self-hosted workflow from `diixtra-forge`
- [ ] Remove `RENOVATE_TOKEN` PAT from 1Password
- [ ] Update `diixtra-forge/.renovaterc` — remove Backstage/Packer managers

---

### Issue: Update Backstage catalog for multi-repo
**Labels:** `migration`, `phase-5`

- [ ] Add `catalog-info.yaml` to `diixtra-backstage`
- [ ] Add `catalog-info.yaml` to `diixtra-packer`
- [ ] Add `catalog-info.yaml` to `diixtra-mcp-servers`
- [ ] Add `catalog-info.yaml` to `diixtra-docs`
- [ ] Update Backstage catalog config to discover entities from all org repos
- [ ] Update scaffolder templates if they reference monorepo paths

---

### Issue: Secrets audit and permissions review
**Labels:** `migration`, `phase-5`

- [ ] Add `OP_SERVICE_ACCOUNT_TOKEN` repo secret to `diixtra-packer`
- [ ] Verify `GITHUB_TOKEN` has `packages:write` for GHCR in `diixtra-backstage`
- [ ] Review repo visibility settings (public vs private) for each repo
- [ ] Verify 1Password service account scope covers new repos
- [ ] Document which secrets each repo needs

---

### Issue: Final migration validation
**Labels:** `migration`, `phase-5`

- [ ] All Flux Kustomizations reconcile cleanly (`flux get ks -A`)
- [ ] All HelmReleases are Ready (`flux get hr -A`)
- [ ] Backstage image builds and deploys from `diixtra-backstage`
- [ ] Packer builds run from `diixtra-packer`
- [ ] MCP server pods are healthy (all 6 servers)
- [ ] Renovate GitHub App creates PRs in all repos
- [ ] Self-hosted runners (homelab, packer) serve all repos
- [ ] DNS sync workflow triggers on `diixtra-forge` push
- [ ] Post-deploy health check runs on `diixtra-forge` push
- [ ] No dangling references to old paths in any repo
- [ ] `MIGRATION-PLAN.md` moved to `diixtra-docs`
- [ ] ADR-009 status changed from "Proposed" to "Accepted"
