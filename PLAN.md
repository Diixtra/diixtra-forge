# Flux CD Bootstrap — Implementation Plan

**Overall Progress:** `85%`

## TLDR
Bootstrap the `diixtra-forge` monorepo with Flux CD on the homelab cluster. Create the GitHub repo via Python script, push the full scaffold, bootstrap Flux, create the 1Password bootstrap secret, and verify reconciliation across all three deployment layers (infrastructure → platform → apps).

## Critical Decisions
- **Flux v2.7.x**: Latest GA release with Image Automation GA and ConfigMap/Secret watching
- **Token auth mode**: Using `--token-auth` with GitHub PAT (stored in 1Password) — avoids SSH key management complexity
- **Python bootstrap script**: All configuration as variables at the top, no hardcoded values anywhere
- **Bootstrap secret pattern**: 1Password SA token is the one manual secret per cluster — everything else flows from it
- **Fine-grained PAT**: Minimum permissions needed — Contents (R/W) for repo access, Administration (R/W) for deploy key setup

## Tasks:

- [x] 🟩 **Step 1: Reconstruct Repo Scaffold**
  - [x] 🟩 Rebuild all base manifests (Caddy, 1Password, MetalLB, flux-addons)
  - [x] 🟩 Rebuild all overlays (homelab, dev)
  - [x] 🟩 Rebuild cluster entrypoints (Flux Kustomizations with dependency ordering)
  - [x] 🟩 Rebuild platform layer (Kyverno, Grafana Alloy)
  - [x] 🟩 Rebuild CI/CD workflows
  - [x] 🟩 Rebuild ADRs and documentation

- [x] 🟩 **Step 2: Write Python Bootstrap Script**
  - [x] 🟩 All config as variables (GitHub owner, repo name, cluster name, branch, etc.)
  - [x] 🟩 Pre-flight checks (flux CLI, kubectl, gh CLI, cluster connectivity)
  - [x] 🟩 GitHub repo creation via `gh` CLI
  - [x] 🟩 Git init, commit, and push scaffold
  - [x] 🟩 Create 1Password bootstrap secret on cluster
  - [x] 🟩 Run `flux bootstrap github` with all vars
  - [x] 🟩 Verify reconciliation (poll Flux Kustomizations until healthy)

- [ ] 🟥 **Step 3: Verify & Document** ← YOU RUN THIS ON YOUR CLUSTER
  - [ ] 🟥 Verify all Flux controllers are running
  - [ ] 🟥 Verify GitRepository source is synced
  - [ ] 🟥 Verify Kustomization reconciliation for each layer
  - [x] 🟩 Document the bootstrap runbook
