# ADR-005: Auto-Update Strategy with Phased Evolution

## Status
Accepted

## Context
The homelab cluster has no external users and exists for learning and
experimentation. Manual version management adds overhead without benefit.
As the IDP matures, version control mechanisms will be introduced
incrementally through the tools already on the roadmap.

## Decision — Phase 1 (Current)
Implement aggressive auto-update with no manual controls:

1. **Helm charts**: Semver range `"*"` in all base HelmRelease specs.
   Flux source-controller re-checks every hour and auto-upgrades.

2. **Container images**: Flux Image Automation (image-reflector-controller +
   image-automation-controller) scans registries every 5 minutes. Updates
   are committed to Git automatically, maintaining the GitOps audit trail.

3. **Everything else**: Self-hosted Renovate Bot via GitHub Actions every
   6 hours. Auto-merges all PRs without review. Groups related updates.

No version pinning mechanism in this phase. If something breaks, rollback
is `git revert` on the automated commit.

## Evolution Roadmap

### Phase 2 — Kyverno Policy Maturity + Supply Chain Security
- Kyverno moves from Audit to Enforce mode for proven policies
- Image vulnerability scanning via Trivy integrated with Kyverno
  `verifyImages` policies — block deployment of images with critical CVEs
- SBOM (Software Bill of Materials) verification: require images to carry
  signed SBOMs before admission to the cluster
- Cosign image signature verification via Kyverno — ensure only trusted
  registries and signed images run in the cluster
- Kyverno generate policies auto-couple ImagePolicy suspends with image
  overrides (eliminates "forgot to pause automation" failure mode)

### Phase 3 — Backstage Self-Service Templates
- Version management abstracted into a UI workflow: pick a component,
  enter a version, optionally set an expiry
- Backstage creates Git commits via GitHub API
- Security dashboards: surface Kyverno policy reports, image scan results,
  and secret rotation status in the developer portal

### Phase 4 — Crossplane Compositions
- Custom `VersionPin` XRD expands into coordinated changes via Composition
- Crossplane manages external dependencies (GitHub, Cloudflare, 1Password)
- Backstage creates `VersionPin` resources instead of raw Git commits

### Phase 5 — Security Hardening + Secret Lifecycle
- Automatic secret rotation schedules in 1Password vault with pod restart
  triggers (Reloader or Flux annotation-based rollout on Secret change)
- 1Password CSI driver or sidecar injection — secrets never materialise
  as Kubernetes Secret objects, eliminating `kubectl get secret` exfiltration
- Runtime security monitoring (Falco or Tetragon) for anomaly detection
- Network policies (Cilium or Calico) for pod-to-pod traffic control
- OPA/Gatekeeper as a complement to Kyverno for complex Rego-based policies
  if needed (evaluate during Phase 2 whether Kyverno alone is sufficient)

**Note on Sealed Secrets**: Explicitly NOT adopted. The 1Password Operator
pattern (runtime fetch, secrets never in Git) is architecturally stronger
than Sealed Secrets (encrypted in Git, decrypted in cluster). Sealed Secrets
introduces a sealing key management burden and still produces plaintext
Kubernetes Secrets. The Phase 5 CSI driver approach eliminates even that.

**Key principle**: Each phase layers on top of existing foundations. The
base/overlay Kustomize structure, the Git-as-source-of-truth model, and
the Flux reconciliation loop never change — only what generates the
commits evolves.

## Consequences
- **Pro**: Zero manual version management. Always running latest.
- **Pro**: Git history records every change (even automated ones).
- **Pro**: Rollback is always `git revert` + Flux reconciliation.
- **Pro**: No premature complexity — controls arrive with the tools.
- **Con**: Breaking changes in major bumps could cause downtime.
- **Con**: No pin mechanism until Phase 2 — manual `git revert` only.
- **Mitigation**: Kyverno Audit policies catch misconfigured resources.
- **Mitigation**: Flux health checks prevent cascading failures.
