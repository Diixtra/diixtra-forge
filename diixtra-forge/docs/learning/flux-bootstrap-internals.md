# Learning: Flux CD Bootstrap — What Actually Happens

## Level 1: Core Concept

Flux CD is a **GitOps operator** — a set of Kubernetes controllers that continuously
ensure your cluster's state matches what's declared in a Git repository. The word
"bootstrap" means installing these controllers onto your cluster AND configuring them
to watch your specific Git repo.

The key insight is that **after bootstrap, Flux manages itself from Git**. If you want
to upgrade Flux, change its configuration, or add new sources, you do it by pushing a
commit to Git — not by running commands on the cluster. The cluster becomes a read-only
reflection of the Git repository.

### When you'd use this pattern
- You want every cluster change to be auditable (Git history = audit trail)
- You want to prevent configuration drift (someone manually `kubectl apply`s something)
- You want declarative, self-healing infrastructure
- You need multi-cluster management from a single repo

### How it fits into the broader architecture
```
                    ┌────────────────┐
                    │   GitHub Repo   │ ← You push changes here
                    │   (Git = Truth) │
                    └───────┬────────┘
                            │
                    ┌───────▼────────┐
                    │ source-controller│ ← Polls Git for new commits
                    └───────┬────────┘
                            │
              ┌─────────────┼─────────────┐
              │             │             │
    ┌─────────▼──┐  ┌──────▼─────┐  ┌───▼────────────┐
    │ kustomize- │  │   helm-    │  │  notification-  │
    │ controller │  │ controller │  │   controller    │
    └─────────┬──┘  └──────┬─────┘  └───┬────────────┘
              │             │             │
              ▼             ▼             ▼
         Kustomize     HelmRelease    Webhooks/
         overlays      lifecycle      Alerts
```

## Level 2: How It Works

### The Six Steps of Bootstrap

When you run `flux bootstrap github`, here's exactly what happens:

**Step 1 — Git Connection**: Flux clones your repo (or creates it if `--personal` is set).
It authenticates using the GITHUB_TOKEN you provided.

**Step 2 — Generate Controller Manifests**: Flux generates `gotk-components.yaml` — this
is roughly 10,000 lines of YAML containing CRDs, Deployments, Services, RBAC rules, and
NetworkPolicies for all four controllers. It's templated from the Flux version you have
installed.

**Step 3 — Commit to Git**: Flux writes `gotk-components.yaml` and `gotk-sync.yaml` into
`clusters/homelab/flux-system/` and commits them. This means **Flux's own configuration
is in your Git repo**. If you ever need to know exactly what version of Flux is running,
check this file.

**Step 4 — Push**: The commit is pushed to GitHub. At this point, your repo contains the
full Flux installation manifests alongside your infrastructure scaffold.

**Step 5 — Install on Cluster**: Flux runs `kubectl apply` to install the controllers.
Four pods start in the `flux-system` namespace.

**Step 6 — Self-Referencing Loop**: This is the clever part. Flux creates:
  - A `GitRepository` resource pointing at your GitHub repo
  - A `Kustomization` resource pointing at `clusters/homelab/`

This means Flux is now watching the same repo that contains its own configuration.
If you push a change to `gotk-components.yaml`, Flux will update itself. Git truly
becomes the single source of truth.

### The Dependency Chain

Once Flux is watching `clusters/homelab/`, it discovers three files:
  - `infrastructure.yaml` → Points at `infrastructure/homelab/`
  - `platform.yaml` → Points at `platform/homelab/` (dependsOn: infrastructure)
  - `apps.yaml` → Points at `apps/homelab/` (dependsOn: platform)

The `dependsOn` field is critical. It means:
  - infrastructure deploys first (Caddy, MetalLB, 1Password Operator)
  - platform waits until infrastructure health checks pass, then deploys
  - apps waits until platform is healthy, then deploys

This ordering prevents race conditions. You don't want Kyverno trying to enforce
policies before the policy engine's CRDs exist. You don't want apps requesting
LoadBalancer IPs before MetalLB is running.

### Key Tradeoffs

**Git polling vs. webhooks**: By default, Flux polls Git every `interval` (we set 10m).
You can add webhooks for instant reconciliation, but polling is simpler and works even
if GitHub can't reach your cluster (which is the case for a homelab behind NAT).

**`prune: true` is dangerous and powerful**: With pruning enabled, Flux will DELETE
resources from the cluster if they're removed from Git. This is correct GitOps behavior
(Git = truth) but can be scary at first. If you accidentally delete a file from Git,
Flux will delete the corresponding resources from the cluster.

**Flux stores the PAT in-cluster**: The GITHUB_TOKEN is stored as a Kubernetes Secret
in the flux-system namespace. Anyone with access to that namespace can read it. This
is why RBAC and namespace isolation matter.

### Edge Cases and Failure Modes

- **Git push race condition**: If you push while Flux is mid-reconciliation, it'll pick
  up the new commit on the next poll. No corruption risk — Git handles this.
- **Controller crash loop**: If a controller OOM-kills, Kubernetes restarts it. The
  controllers are stateless — they re-read from Git on startup.
- **Network partition**: If the cluster loses internet access, Flux can't pull from Git.
  Existing resources continue running. When connectivity returns, Flux catches up.
- **CRD ordering**: HelmRelease CRDs must exist before Flux can apply HelmReleases.
  Bootstrap handles this, but if you manually delete CRDs, everything breaks.

## Level 3: Deep Dive

### Server-Side Apply vs. Client-Side Apply

Flux uses **server-side apply** (SSA) by default since v2. This is significant:

- **Client-side apply** (`kubectl apply`): The client computes the diff and sends the
  full resource. Last-write-wins. If two tools manage the same resource, they fight.
- **Server-side apply**: The server tracks which "field manager" owns which fields.
  Flux owns the fields it manages; other tools can own other fields. Conflicts are
  detected and reported rather than silently overwritten.

This means you can have Flux managing a Deployment's `spec.template` while an HPA
manages `spec.replicas` — they don't conflict because they own different fields.

### The gotk-sync.yaml Self-Reference

The file Flux creates at `clusters/homelab/flux-system/gotk-sync.yaml` contains:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m0s
  ref:
    branch: main
  url: https://github.com/OWNER/diixtra-forge.git

---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./clusters/homelab
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

The GitRepository polls GitHub every minute for new commits. When it finds one,
it downloads the repo as a tarball. The Kustomization then builds whatever is at
`./clusters/homelab` and applies it to the cluster.

### Performance at Scale

Flux's architecture is designed for scale:
- source-controller caches Git/OCI/Helm artifacts on disk
- kustomize-controller uses server-side apply with field managers
- Controllers shard by namespace for multi-tenancy
- Each controller can be horizontally scaled independently

For a homelab, none of this matters — but it's why Flux is used by Deutsche Telekom
to manage 200+ clusters with a team of 10.

### Relationship to Kustomize

Flux's "Kustomization" CRD is NOT the same as `kustomize.config.k8s.io/v1beta1`.
Two different things that share a name (confusingly):

- **kustomize.config.k8s.io** — The vanilla Kustomize `kustomization.yaml` file that
  declares resources, patches, and overlays. This is what `kustomize build` reads.
- **kustomize.toolkit.fluxcd.io** — A Flux CRD that tells the kustomize-controller
  to run `kustomize build` on a path and apply the output to the cluster.

The Flux Kustomization "wraps" the Kustomize kustomization. It adds dependency
ordering, health checking, pruning, and reconciliation on top of vanilla Kustomize.
