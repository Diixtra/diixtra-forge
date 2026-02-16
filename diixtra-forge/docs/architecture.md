# Diixtra Forge — Architecture Overview

## Vision

A production-grade Internal Developer Platform (IDP) spanning homelab and
cloud environments. Every infrastructure operation — from deploying a
container to assigning a network IP — flows through Git as the single
source of truth, reconciled by Kubernetes-native controllers.

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Git Repository                               │
│              diixtra-forge (monorepo)                         │
│                                                                     │
│  clusters/     infrastructure/    platform/    apps/    terraform/   │
│  (Flux         (Layer 1:          (Layer 2:    (Layer 3: (Cloud     │
│   entrypoints)  Caddy, MetalLB,   Kyverno,    Diixtra   resources  │
│                 1Password)        Alloy)      services)  via GHA)  │
└────────┬───────────────────────────┬───────────────────────┬────────┘
         │                           │                       │
    ┌────▼────┐                ┌─────▼─────┐          ┌─────▼──────┐
    │ Flux CD │                │  Renovate │          │  GitHub    │
    │ (GitOps)│                │  Bot      │          │  Actions   │
    │         │                │  (auto-   │          │  (CI/CD)   │
    └────┬────┘                │   merge)  │          └─────┬──────┘
         │                     └───────────┘                │
    ┌────▼─────────────────────────────────┐          ┌─────▼──────┐
    │         Kubernetes Cluster            │          │ Terraform  │
    │                                      │          │ (Cloudflare│
    │  ┌──────────┐  ┌──────────────────┐  │          │  AWS, etc) │
    │  │ Layer 1   │  │ Layer 2          │  │          └────────────┘
    │  │ MetalLB   │  │ Kyverno          │  │
    │  │ Caddy     │  │ Grafana Alloy    │  │
    │  │ 1Password │  │ (→ Backstage)    │  │
    │  │ Operator  │  │ (→ Crossplane)   │  │
    │  │ GHA Runner│  │                  │  │
    │  └──────────┘  └──────────────────┘  │
    │                                      │
    │  ┌──────────────────────────────────┐│
    │  │ Layer 3: Application Workloads   ││
    │  │ (future Diixtra services)        ││
    │  └──────────────────────────────────┘│
    └──────────────────────────────────────┘
```

## Deployment Layers

Flux deploys resources in strict dependency order. Each layer must be
healthy before the next begins:

| Layer | Directory         | Contents                          | Depends On     |
|-------|-------------------|-----------------------------------|----------------|
| 1     | `infrastructure/` | Caddy, MetalLB, 1Password, GHA Runner, Flux addons | —  |
| 2     | `platform/`       | Kyverno, Grafana Alloy            | Infrastructure |
| 3     | `apps/`           | Diixtra services (future)         | Platform       |

This ordering guarantees:
- 1Password Operator is running before any workload needs secrets
- MetalLB is assigning IPs before any Service needs a LoadBalancer
- Kyverno policies are enforced before application pods are admitted
- Grafana Alloy is collecting metrics before apps start generating them

## Cluster Topology

| Cluster  | Nodes                                     | Purpose           |
|----------|-------------------------------------------|--------------------|
| Homelab  | kaz-k8-1 (amd64), k8-worker-1, pi4, pi5  | Production-like lab|
| Dev      | Rancher Desktop (Mac)                     | Local development  |

Both clusters reconcile from the same Git repo using Kustomize overlays.
Base manifests are shared; environment-specific differences (IP ranges,
domains, replica counts) are expressed as overlay patches.

## Networking

| Component     | Role                                           |
|---------------|------------------------------------------------|
| Unifi         | Physical network, VLANs, DHCP, DNS             |
| MetalLB       | Kubernetes LoadBalancer IPs (L2 mode, 10.2.0.200-210) |
| Caddy         | Reverse proxy, TLS termination (Cloudflare DNS-01) |
| Flannel       | Pod-to-pod networking (VXLAN overlay)           |
| CoreDNS       | Cluster DNS with explicit upstream servers      |

**Key learning**: Kubernetes nodes require static IP assignments. DHCP
reassignment causes silent Flannel VXLAN failures because the overlay
network tunnels are bound to specific node IPs. Future: UniFi API
pre-flight checks (KAZ-61) will validate this before bootstrap.

## Secrets Management (ADR-007)

All secrets follow the 1Password runtime-fetch pattern:

```
1Password Vault → Operator → K8s Secret → Pod
```

- Git contains only vault path references (`OnePasswordItem` CRDs)
- One bootstrap secret per cluster (SA token, created manually)
- Sealed Secrets explicitly NOT adopted — 1Password is architecturally stronger
- Phase 5 evolution: CSI driver eliminates K8s Secret objects entirely

See: `docs/runbooks/secrets-management.md` for operations guide.

## Auto-Update Strategy (ADR-005)

Three independent automation systems keep the homelab always-current:

| System              | Scope                  | Frequency | Mechanism              |
|---------------------|------------------------|-----------|------------------------|
| Flux helm-controller| Helm chart versions    | 1 hour    | Semver range `"*"`     |
| Flux Image Automation| Container image digests| 5 minutes | Registry scan + Git commit |
| Renovate Bot        | Everything else        | 6 hours   | GitHub PRs, auto-merge |

**Competing systems warning**: All three can touch the same resource.
Version pinning (Phase 2+) requires pausing all three atomically.

## Observability

Hybrid architecture — local collection, cloud backend:

- **Grafana Cloud**: Metrics, logs, traces storage + dashboards + alerting
- **Grafana Alloy**: DaemonSet on every node, collects and ships telemetry
- **OpenTelemetry**: Standard protocol for all telemetry data

This separates the monitoring failure domain from the cluster failure domain.
If the cluster is down, Grafana Cloud still has all historical data and
can alert on the absence of new data.

## Storage (ADR-006)

- **democratic-csi** with TrueNAS SCALE at 10.2.0.232
- ZFS-backed NFS (shared access) and iSCSI (block, databases)
- Dynamic provisioning via StorageClasses — create PVC, get storage
- ZFS snapshots enable backup/restore via VolumeSnapshots

## Evolution Roadmap

| Phase | Focus                          | Key Tools              |
|-------|--------------------------------|------------------------|
| 1     | GitOps bootstrap, auto-update  | Flux, Renovate         |
| 2     | Policy enforcement, supply chain| Kyverno, Trivy, Cosign|
| 3     | Developer self-service         | Backstage              |
| 4     | Declarative everything         | Crossplane, UniFi API  |
| 5     | Runtime security               | Falco, CSI driver, NetworkPolicies |

See `docs/adr/005-auto-update-strategy.md` for detailed phase descriptions.

## Architecture Decision Records

| ADR | Decision                                   | Date       |
|-----|--------------------------------------------|------------|
| 001 | Flux CD over Argo CD                       | 2026-02-13 |
| 002 | Monorepo for all infrastructure            | 2026-02-13 |
| 003 | Kyverno over OPA Gatekeeper                | 2026-02-13 |
| 004 | Terraform → Crossplane migration path      | 2026-02-13 |
| 005 | Auto-update strategy with phased evolution | 2026-02-14 |
| 006 | TrueNAS dynamic storage via democratic-csi | 2026-02-14 |
| 007 | 1Password Operator over Sealed Secrets     | 2026-02-14 |

## Runbooks

| Runbook              | Purpose                              |
|----------------------|--------------------------------------|
| `bootstrap.md`       | Initial Flux bootstrap procedure     |
| `secrets-management.md` | 1Password secrets lifecycle       |
| `truenas-setup.md`   | TrueNAS CSI driver configuration     |

## Repository Structure

```
diixtra-forge/
├── .github/workflows/       CI/CD pipelines
│   ├── flux-validate.yaml   Kustomize build + kubeconform on PRs
│   ├── renovate.yaml        Self-hosted Renovate Bot (every 6h)
│   └── terraform-*.yaml     Plan on PR, apply on merge
├── clusters/                Flux entrypoints (one dir per cluster)
│   ├── homelab/
│   │   ├── flux-system/     Auto-generated by flux bootstrap
│   │   ├── infrastructure.yaml
│   │   ├── platform.yaml
│   │   └── apps.yaml
│   └── dev/
├── infrastructure/          Layer 1: core cluster services
│   ├── base/                Shared manifests
│   │   ├── caddy/
│   │   ├── metallb/
│   │   ├── onepassword-operator/
│   │   └── flux-addons/     HelmRepositories, Image Automation
│   ├── homelab/             Homelab overlays (IP pool, Caddyfile)
│   └── dev/                 Dev overlays
├── platform/                Layer 2: IDP + observability
│   ├── base/
│   │   ├── kyverno/
│   │   ├── kyverno-policies/
│   │   └── grafana-alloy/
│   ├── homelab/
│   └── dev/
├── apps/                    Layer 3: application workloads
├── terraform/               Cloud resources (→ Crossplane in Phase 4)
├── scripts/                 Automation (bootstrap.py)
├── renovate.json            Renovate Bot configuration
└── docs/
    ├── architecture.md      ← you are here
    ├── adr/                 Architecture Decision Records
    ├── runbooks/            Operational procedures
    └── learning/            Deep-dive educational content
```
