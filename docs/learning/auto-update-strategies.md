# Learning: Auto-Update Strategies in GitOps

## Level 1: Core Concept — Why Auto-Updates in GitOps Are Different

In traditional ops, auto-updates mean "pull the latest and restart." In GitOps,
auto-updates mean "detect something new exists, update Git, then let the normal
reconciliation loop deploy it." The crucial difference is that **Git is always
updated first**. Even automated changes go through Git, which gives you:

- Full audit trail (who/what changed, when, and why)
- Ability to revert by reverting a Git commit
- The exact same deployment path for manual and automated changes

There are three categories of things that update in your cluster:

```
┌──────────────────────────────────────────────────────────────────┐
│                    What Updates?                                  │
├──────────────────┬──────────────────┬────────────────────────────┤
│  Helm Charts     │  Container       │  Flux Controllers          │
│                  │  Images          │  (Flux itself)             │
│                  │                  │                            │
│  MetalLB 0.14→15 │  Backstage img   │  source-controller v1.5   │
│  Kyverno 3.3→3.4 │  Custom apps     │  helm-controller v1.2     │
│                  │                  │                            │
│  ┌────────────┐  │  ┌────────────┐  │  ┌────────────┐           │
│  │ Semver     │  │  │ Image      │  │  │ Renovate   │           │
│  │ ranges in  │  │  │ Automation │  │  │ Bot or     │           │
│  │ HelmRelease│  │  │ Controllers│  │  │ GH Actions │           │
│  └────────────┘  │  └────────────┘  │  └────────────┘           │
└──────────────────┴──────────────────┴────────────────────────────┘
```

## Level 2: How Each Mechanism Works

### Helm Chart Auto-Updates (Semver Ranges)

Your HelmRelease specs have a `version` field that supports semver ranges:
- `"0.14.*"` → Latest patch within 0.14 (conservative)
- `">=0.14.0"` → Any version 0.14.0 or newer (aggressive)
- `"*"` → Absolute latest (YOLO — perfect for a lab)

Flux's source-controller re-checks the Helm repository at the `interval` you
specified (1h in our config). When it finds a new version matching the range,
it downloads the new chart and the helm-controller upgrades the release.

This is the simplest mechanism — just change one field and you get auto-updates.
No extra controllers needed.

**Why production doesn't do this**: In production, you pin exact versions
(`"0.14.3"`) and use Renovate to create PRs for each update. This gives you
a review step and a Git commit for each version change. In a lab, the review
step is unnecessary overhead.

### Container Image Auto-Updates (Flux Image Automation)

Helm charts are only half the story. Your Backstage deployment uses a custom
container image (`ghcr.io/diixtra/backstage:latest`). When someone pushes
a new `:latest` image, your cluster has no idea unless something tells it.

Flux Image Automation is a two-controller system:

**image-reflector-controller** — Periodically scans container registries
(Docker Hub, GHCR, ECR, etc.) for new image tags. It stores the results
as `ImagePolicy` resources in the cluster.

**image-automation-controller** — Takes the latest tag from an ImagePolicy
and commits it back to your Git repo. It literally modifies the YAML files
in Git and pushes a commit like "Update backstage image to sha256:abc123".

The flow:
```
Container Registry (GHCR)
    │ new image pushed
    ▼
image-reflector-controller
    │ scans registry, finds new digest
    ▼
ImagePolicy (selects "latest")
    │
    ▼
image-automation-controller
    │ updates deployment.yaml in Git
    ▼
Git commit pushed to GitHub
    │
    ▼
source-controller detects new commit
    │
    ▼
kustomize-controller applies updated manifest
    │
    ▼
Kubernetes pulls new image, restarts pod
```

**The image marker pattern**: Image Automation needs to know WHERE in your
YAML files to write the updated tag. You add a comment marker:

```yaml
image: ghcr.io/diixtra/backstage:latest # {"$imagepolicy": "flux-system:backstage"}
```

The controller finds this marker and replaces the tag/digest. Without the
marker, it doesn't know which files to edit.

### Renovate Bot (Catches Everything Else)

Renovate is a GitHub bot that understands dozens of dependency formats:
Helm chart versions, Docker image tags, GitHub Actions versions, Terraform
provider versions, npm packages, pip requirements, and more.

It creates PRs for each update, which you can auto-merge. For a lab with
no users, you configure it to auto-merge everything without review.

Renovate catches things the other two mechanisms miss:
- GitHub Actions versions in `.github/workflows/`
- Terraform provider versions
- Flux controller upgrades
- Base image version bumps

## Level 3: Deep Dive — Why `:latest` Tags Are a Trap (Even in Labs)

The `:latest` tag is mutable — it can point to a different image digest
every time someone pushes. Kubernetes caches images locally and uses
`imagePullPolicy: IfNotPresent` by default. This means:

1. Pod starts, pulls `backstage:latest` → gets digest `sha256:aaa`
2. New image pushed to registry → `:latest` now points to `sha256:bbb`
3. Pod restarts (maybe on a different node) → pulls `sha256:bbb`
4. Node 1 still has `sha256:aaa` cached → runs the old version

You have different versions running on different nodes with no record
of when the change happened. This is drift with no audit trail.

**The GitOps solution**: Pin the image digest in Git, and let Image
Automation update it:

```yaml
image: ghcr.io/diixtra/backstage:latest@sha256:abc123
```

When Image Automation detects a new digest for `:latest`, it updates
the `@sha256:...` suffix in Git. Every node pulls the same digest.
The Git history shows exactly when each image change happened.

This is the best of both worlds: you get the convenience of `:latest`
with the reproducibility of pinned digests.
