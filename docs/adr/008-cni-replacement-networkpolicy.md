# ADR-008: CNI Replacement and NetworkPolicy Implementation

## Status
Proposed

## Date
2026-02-24

## Context

The Diixtra Forge homelab Kubernetes (kubeadm) cluster currently runs Flannel VXLAN as its CNI with no NetworkPolicy enforcement. This cluster is not just a homelab -- it is a control plane used to build and manage environments elsewhere (Packer image builds, Crossplane infrastructure provisioning, Flux GitOps). Security is critical: a compromise of this cluster could propagate to every environment it manages.

The current state:
- **CNI:** Flannel VXLAN -- no native NetworkPolicy support
- **NetworkPolicy controller:** None. Flannel does not implement the NetworkPolicy API. kube-proxy handles Service routing only.
- **Zero NetworkPolicies deployed** -- all pod-to-pod traffic is unrestricted
- **Kyverno** handles admission policies (PSS, resource limits, registry allowlist) but cannot enforce network segmentation
- **MetalLB** provides LoadBalancer IPs via L2/ARP (10.2.0.200-210)
- **Traefik** is the ingress controller with IngressRoute CRDs, pinned to MetalLB IP 10.2.0.200
- **democratic-csi** provides iSCSI and NFS storage from TrueNAS at 10.2.0.232
- **Grafana Alloy** ships metrics and logs to Grafana Cloud
- **ARC runners** execute GitHub Actions workflows with cluster access (Flux reader RBAC)

### Threat Model

The most sensitive components in this cluster are:
1. **ARC runners** -- execute arbitrary workflow code, have Flux reader access
2. **1Password operator** -- syncs secrets from 1Password to Kubernetes Secrets
3. **Flux controllers** -- have write access to the cluster, pull from GitHub
4. **Crossplane** -- provisions infrastructure in external environments
5. **Backstage** -- has a GitHub App credential and Kubernetes plugin access

Without NetworkPolicies, a compromised pod in any namespace can reach all of these.

---

## Decision

**Replace Flannel with Cilium** and implement a default-deny NetworkPolicy posture with explicit allowlists per namespace.

---

## Options Evaluated

### Option 1: Add a Standalone NetworkPolicy Controller (Keep Flannel)

**How it works:** Keep Flannel for pod networking but deploy a standalone NetworkPolicy controller (e.g., kube-router or Antrea in NetworkPolicy-only mode) alongside it.

**Pros:**
- No CNI swap, lower migration risk
- Flannel continues handling pod networking

**Cons:**
- **Two CNI-related components** -- Flannel for networking plus a separate controller for policy. More moving parts.
- **iptables-only implementation** (kube-router) -- scales poorly with large numbers of policies. Every policy change rewrites iptables chains.
- **No L7 visibility** -- cannot see HTTP methods, paths, or DNS queries in policy decisions. Policies are IP:port only.
- **No observability** -- no equivalent to Hubble. When a connection fails, you have no tooling to determine whether a NetworkPolicy blocked it or something else went wrong.
- **Community is moving away** -- standalone NetworkPolicy controllers are losing mindshare. Cilium and Calico provide CNI + policy in one package.

**Verdict:** Acceptable for a throwaway lab. Not acceptable for a control plane that manages production infrastructure.

### Option 2: Calico

**How it works:** Replace Flannel with Calico. Remove the Flannel DaemonSet, then deploy Calico as the CNI with NetworkPolicy support built in.

**Pros:**
- Mature, battle-tested NetworkPolicy implementation
- Supports both standard Kubernetes NetworkPolicy and extended Calico NetworkPolicy CRDs (GlobalNetworkPolicy, host endpoint policies)
- Lightweight -- the iptables data plane uses ~100-150MB RAM per node
- Optional eBPF data plane for performance parity with Cilium
- Good documentation for kubeadm clusters

**Cons:**
- **No built-in observability** -- no equivalent to Hubble. You get policy enforcement but no network flow visibility without adding a separate tool.
- **No L7 policy support in the open-source edition** -- L7 policies (HTTP method/path matching) require Calico Enterprise (paid).
- **Smaller ecosystem momentum** -- Cilium has become the de facto CNCF CNI. Calico is still actively maintained but has lost mindshare.
- **Cannot replace MetalLB** -- Calico's BGP mode is powerful but its L2 announcement support is less mature than Cilium's. You would keep MetalLB.
- **No kube-proxy replacement** -- still relies on kube-proxy/iptables for Service routing.

**Verdict:** Solid choice if you want minimal complexity. But for a cluster that also needs network observability and is already investing in Grafana Cloud, the lack of Hubble-like tooling is a significant gap.

### Option 3: Cilium (Recommended)

**How it works:** Replace Flannel with Cilium. Remove the Flannel DaemonSet and kube-proxy, then deploy Cilium with kube-proxy replacement enabled.

**Pros:**
- **eBPF-native networking** -- policies are enforced in the kernel before packets reach userspace. No iptables chains to manage. No enforcement delay on pod startup.
- **Hubble observability** -- real-time network flow visibility. When a connection is blocked, Hubble tells you which policy blocked it, from which pod, to which destination. This is invaluable for debugging NetworkPolicy rollouts.
- **Hubble metrics integrate with Grafana** -- Hubble exports Prometheus metrics that Grafana Alloy can scrape and ship to Grafana Cloud. This complements (not replaces) the existing Alloy setup by adding network-layer metrics (flows/sec, policy drops, DNS latency, HTTP error rates).
- **L3/L4/L7 policy support** -- CiliumNetworkPolicy CRDs support HTTP method/path matching, DNS-aware policies (allow egress only to specific FQDNs), and Kafka/gRPC-aware policies. All in the open-source edition.
- **Replaces kube-proxy** -- Cilium's eBPF-based service routing is more efficient than iptables kube-proxy. One less component to run.
- **Can replace MetalLB** -- Cilium 1.14+ supports L2 announcements and LB-IPAM natively. This is optional -- you can keep MetalLB initially and migrate later if desired.
- **CiliumNetworkPolicy supports FQDN-based egress** -- you can write policies like "allow egress to github.com" instead of hardcoding IP ranges. Critical for allowing Flux to reach GitHub while blocking everything else.
- **Traefik compatibility is explicitly supported** -- Traefik Labs [published a joint blog post](https://traefik.io/blog/cilium-and-traefik-together) confirming they complement each other. Cilium handles L3/L4, Traefik handles L7 ingress routing. No conflicts with IngressRoute CRDs.
- **CNCF graduated project** -- the most actively developed CNI in the Kubernetes ecosystem.

**Cons:**
- **Higher memory footprint** -- Cilium agent uses ~300-500MB RAM per node (vs ~50MB for Flannel). On a homelab with limited RAM, this matters. However, Cilium replaces both Flannel AND kube-proxy, so the net increase is ~200-300MB per node.
- **Migration requires downtime** -- replacing the CNI on a running cluster requires restarting all pods. The "zero-downtime" dual-overlay migration is complex and not worth the effort for a small cluster. A planned maintenance window (30-60 minutes) is the pragmatic approach.
- **eBPF kernel requirements** -- requires Linux kernel 4.19+ (ideally 5.10+). The Packer images run Ubuntu/Debian with kernel 6.x. Not a concern.
- **More complex to debug** -- when something goes wrong with Cilium itself, debugging eBPF programs is harder than debugging iptables rules. Mitigated by Hubble and Cilium's excellent troubleshooting docs.
- **Flux chicken-and-egg** -- Cilium installation cannot be managed by Flux if Flux depends on the CNI being operational. Cilium must be bootstrapped outside Flux, then optionally managed by Flux afterward.

**Verdict:** The right choice for a security-critical control plane. The observability benefits alone justify the migration, and the eBPF-based policy enforcement eliminates the enforcement delay that makes kube-router unsuitable.

---

## Recommendation: Cilium

### Architecture After Migration

```
                    Internet
                        |
                   [Cloudflare DNS]
                        |
              [Traefik - 10.2.0.200]  <-- MetalLB L2 (keep initially)
                   /    |    \
          IngressRoutes to services
                        |
    +---------+---------+---------+---------+
    |  flux   | onepass | arc-sys | backstg |  ... namespaces
    | system  | system  | runners | age     |
    +---------+---------+---------+---------+
         |         |         |         |
    [Cilium eBPF dataplane - pod-to-pod routing]
    [CiliumNetworkPolicy - default deny + allowlists]
    [Hubble - flow visibility -> Grafana Alloy -> Grafana Cloud]
         |
    [Node network - 10.2.0.0/24]
         |
    [TrueNAS - 10.2.0.232]  <-- iSCSI (port 3260) + NFS (port 2049)
```

---

## Impact on Existing Stack

### 1. democratic-csi (iSCSI + NFS) -- NO IMPACT

iSCSI and NFS traffic flows between the **node** and TrueNAS, not between pods. The kubelet on each node initiates iSCSI connections (port 3260) and NFS mounts (port 2049) to 10.2.0.232. This traffic uses the node's network stack, not the pod overlay network. CNI replacement does not affect it.

The democratic-csi controller pod (which talks to the TrueNAS API on port 443) will need a CiliumNetworkPolicy allowing egress to 10.2.0.232:443. This is covered in the NetworkPolicy strategy below.

### 2. MetalLB -- KEEP INITIALLY, MIGRATE LATER (OPTIONAL)

Cilium and MetalLB coexist without conflict. MetalLB's L2 speaker responds to ARP requests for the LoadBalancer IP range (10.2.0.200-210). Cilium does not interfere with this -- it operates on the pod overlay, not on the node's L2 announcements.

**Future option:** Cilium 1.14+ can replace MetalLB entirely with native L2 announcements. This requires `kubeProxyReplacement: true` (which we are enabling). The migration would be:
1. Configure Cilium LB-IPAM with the same IP pool (10.2.0.200-210)
2. Enable Cilium L2 announcements
3. Remove MetalLB HelmRelease
4. One fewer component to maintain

This is a separate, lower-priority change. Keep MetalLB for now.

### 3. Traefik -- NO IMPACT

Traefik operates at L7 (HTTP routing via IngressRoute CRDs). Cilium operates at L3/L4 (packet routing and policy enforcement). They are complementary, not competing. Traefik's service of type LoadBalancer still gets its IP from MetalLB. Traefik's IngressRoute CRDs are unaffected by the CNI.

The only NetworkPolicy consideration: Traefik pods in `traefik-system` need ingress from the internet (ports 80, 443) and egress to backend services in various namespaces. This is covered below.

Cilium's own ingress controller and service mesh mode are **not needed** -- Traefik already handles L7 routing well. Do not enable Cilium's Envoy-based features; they would duplicate Traefik's role.

### 4. Flux -- CHICKEN-AND-EGG, SOLVABLE

Flux cannot manage the CNI that Flux itself depends on. If Cilium is deployed as a Flux HelmRelease, and Cilium is down, Flux cannot reconcile to bring Cilium back up.

**Solution:** Install Cilium outside of Flux during the initial migration, then optionally bring it under Flux management with a `dependsOn` chain that ensures Cilium is the first thing reconciled. Practically:

- During migration: install Cilium via `helm install` directly
- Post-migration: create a Flux HelmRelease for Cilium in the `infrastructure-crds` layer (it installs CRDs). Add a Flux Kustomization health check for Cilium. If Cilium fails, Flux's retry logic handles it -- the CNI doesn't disappear just because the HelmRelease is unhealthy; the DaemonSet pods keep running.

The real risk is not "Flux can't reconcile Cilium" — it is "a Cilium upgrade via Flux breaks networking." Mitigate this by pinning the Cilium Helm chart version (unlike other charts in this lab that use `version: "*"`).

### 5. GPU Workloads -- MINOR CONSIDERATION

The GPU node runs a separate standalone k3s cluster (per `provision-gpu-node.sh`). It is not part of the main homelab kubeadm cluster. The CNI change on the main cluster does not affect the GPU node.

If the GPU node is later joined to the main cluster, it would need Cilium installed. The Packer provisioning script (`provision-k8s-node.sh`) would also need updating to skip Flannel installation and prepare nodes for Cilium.

### 6. Grafana Cloud Observability -- ENHANCED

Hubble does not replace Grafana Alloy. It complements it:

| Layer | Current (Alloy) | Added (Hubble) |
|-------|-----------------|----------------|
| Metrics | kube-state-metrics, node metrics | Network flow rates, policy drop counts, DNS latency, HTTP error rates per service |
| Logs | Pod stdout/stderr via Alloy | Hubble flow logs (optional, can export to Loki) |
| Traces | Not configured | Hubble can extract trace IDs from HTTP headers and attach them to flow metrics as exemplars |

Hubble metrics are exposed as Prometheus metrics. Grafana Alloy can scrape them and ship to Grafana Cloud. Pre-built Grafana dashboards are available for [Cilium/Hubble metrics](https://grafana.com/grafana/dashboards/16613-hubble/).

### 7. Kyverno -- NO OVERLAP, NO CONFLICT

Kyverno enforces admission policies (what can be **created** in the cluster). Cilium enforces network policies (what can **communicate** in the cluster). They operate at different points in the request lifecycle and do not conflict.

Cilium's L7 policies could theoretically replace some Traefik middleware (e.g., rate limiting), but this is not recommended. Keep Traefik middleware for L7 concerns (security headers, basic auth) and Cilium for network segmentation.

---

## NetworkPolicy Strategy

### Default Posture: Deny All Ingress and Egress

Every namespace gets a default-deny CiliumNetworkPolicy. Pods that need network access get explicit allowlists. This is the only defensible posture for a control-plane cluster.

> **Correction (2026-03-05):** The original template below with empty `ingress: []` /
> `egress: []` arrays is **invalid** in Cilium 1.19.1. Cilium rejects
> CiliumNetworkPolicy resources that have empty rule arrays AND standalone
> `enableDefaultDeny` without rule stanzas. All 14 default-deny policies
> using this template were `VALID: False` and not enforced.
>
> The corrected approach depends on whether the namespace has allow policies:
>
> - **Namespaces with both ingress and egress allow policies** (e.g.
>   backstage, flux-system, traefik-system): No standalone default-deny
>   policy needed. The presence of an ingress/egress allow policy
>   implicitly activates Cilium's default deny for that direction.
>
> - **Egress-only namespaces with no inbound connections** (e.g.
>   arc-runners, democratic-csi, onepassword-system): Use explicit
>   `ingressDeny: [{fromEntities: [all]}]` to deny ingress. The egress
>   allow policies already activate egress default deny implicitly.
>
> See commit 41ec178 (`fix(netpol): fix invalid default-deny policies
> across all namespaces (#646)`) for the full fix.

```yaml
# DEPRECATED — this template is invalid in Cilium 1.19.1.
# See correction note above for the valid approaches.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: <namespace>
spec:
  endpointSelector: {}  # Matches all pods in the namespace
  ingress: []            # Deny all ingress
  egress: []             # Deny all egress
```

### Namespace-by-Namespace Allowlists

The following table summarizes the required network access per namespace. Each row becomes one or more CiliumNetworkPolicy resources.

| Namespace | Ingress From | Egress To | Notes |
|-----------|-------------|-----------|-------|
| **kube-system** | All pods (for CoreDNS) | Internet (for DNS forwarders) | CoreDNS must be reachable from every pod. Apply default-deny EXCEPT for CoreDNS pods. |
| **flux-system** | None (controllers initiate outbound only) | github.com (HTTPS), Kubernetes API, all namespaces (for apply) | FQDN-based egress policy for GitHub. Flux controllers need egress to the Kubernetes API server and to any namespace they manage. |
| **onepassword-system** | None | 1password.com (HTTPS), Kubernetes API | The operator polls 1Password and creates/updates Secrets. FQDN-based egress. |
| **traefik-system** | Internet (ports 80, 443), all namespaces (for health checks from pods) | All namespaces (for backend routing), 10.2.0.232 (TrueNAS backends), 10.2.20.171 (Home Assistant) | Traefik needs broad egress because it routes to services in multiple namespaces and to external IPs. |
| **democratic-csi** | None (CSI controller initiates outbound) | 10.2.0.232:443 (TrueNAS API) | The controller pod talks to TrueNAS API. Node-level iSCSI/NFS traffic is not affected by pod policies. |
| **metallb-system** | All nodes (for health probes) | None (MetalLB speaker uses host networking) | MetalLB speaker pods may use hostNetwork, which bypasses CNI. Verify after deployment. |
| **arc-system** | None | Kubernetes API, github.com (HTTPS) | ARC controller watches CRDs and talks to GitHub API. |
| **arc-runners** | None | github.com (HTTPS), Kubernetes API (read-only, for Flux status), ghcr.io (for pulling images) | **Runners are the highest-risk namespace.** They execute arbitrary workflow code. Lock down egress tightly. Consider: do runners need internet access beyond GitHub? If they run `packer build`, they need access to Proxmox API and package mirrors. |
| **packer-runners** | None | Proxmox API, package mirrors (Ubuntu, Debian, 1Password, NVIDIA repos) | Packer runners need broad internet egress for image builds. Consider a separate, more permissive policy for this namespace. |
| **backstage** | traefik-system (ingress via IngressRoute) | Kubernetes API, github.com (HTTPS) | Backstage reads cluster state and GitHub data. |
| **monitoring** | Prometheus scrape targets (all namespaces) | Grafana Cloud endpoints (HTTPS) | Alloy needs egress to Grafana Cloud URLs and ingress from nothing (it scrapes outbound). |
| **kyverno-system** | Kubernetes API (webhook callbacks) | Kubernetes API | Kyverno is an admission webhook -- the API server calls it. |
| **crossplane-system** | None | External cloud APIs (depends on providers configured) | Lock down to specific provider endpoints as they are added. |

### DNS Egress: The Universal Exception

Almost every pod needs DNS resolution. Rather than adding DNS egress to every policy, use a CiliumClusterwideNetworkPolicy to allow all pods to reach CoreDNS:

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: allow-dns
spec:
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
```

### iSCSI/NFS Traffic: Not Pod-Level

iSCSI (port 3260) and NFS (port 2049) traffic between nodes and TrueNAS (10.2.0.232) is **node-level**, initiated by kubelet and the iSCSI initiator on the host. This traffic does not traverse the CNI overlay and is not subject to CiliumNetworkPolicy.

If you later enable Cilium host firewall policies (CiliumClusterwideNetworkPolicy with `nodeSelector`), you would need to explicitly allow node-to-TrueNAS traffic on ports 3260 (iSCSI) and 2049 (NFS). This is an advanced feature and not recommended for the initial rollout.

### GPU Workloads

The GPU node is a separate k3s cluster. If it is later joined to the main cluster, GPU workloads would need:
- Egress to container registries (for pulling model images)
- Egress to any inference API clients
- Ingress from monitoring (for Prometheus scraping)
- A dedicated namespace with a permissive-but-explicit policy

---

## Migration Plan

### Prerequisites

1. **Kernel version check:** Verify all nodes run kernel 5.10+. The Packer-built Proxmox VMs run 6.x kernels. Confirm with `uname -r` on each node.
2. **Backup:** Take an etcd snapshot (`ETCDCTL_API=3 etcdctl snapshot save /tmp/etcd-backup.db`) and a Flux state export.
3. **Schedule maintenance window:** 30-60 minutes. All in-cluster services will be unavailable during pod restarts.
4. **Notify dependents:** If any external systems depend on services in this cluster, notify them.

### Phase 1: Cilium Installation (Maintenance Window)

**Step 1: Remove Flannel and kube-proxy**

```bash
# Delete the Flannel DaemonSet
kubectl delete daemonset -n kube-system kube-flannel-ds

# Remove Flannel CNI config from all nodes (run on each node)
rm -f /etc/cni/net.d/10-flannel.conflist
rm -rf /run/flannel

# Delete kube-proxy DaemonSet (Cilium will replace it)
kubectl delete daemonset -n kube-system kube-proxy
kubectl delete configmap -n kube-system kube-proxy

# Clean up iptables rules left by kube-proxy (run on each node)
iptables-save | grep -v KUBE | iptables-restore
```

**WARNING:** After this step, pod networking will be broken until Cilium is installed. All pods will lose connectivity. This is why a maintenance window is required.

**Step 2: Install Cilium via Helm (outside of Flux)**

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium \
  --version 1.19.1 \
  --namespace kube-system \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="10.244.0.0/16" \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="<control-plane-ip>" \
  --set k8sServicePort=6443 \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.metrics.enableOpenMetrics=true \
  --set hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp,httpV2:exemplars=true;labelsContext=source_ip\,source_namespace\,source_workload\,destination_ip\,destination_namespace\,destination_workload\,traffic_direction}" \
  --set operator.replicas=1 \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=256Mi \
  --set resources.limits.cpu=500m \
  --set resources.limits.memory=512Mi \
  --set operator.resources.requests.cpu=50m \
  --set operator.resources.requests.memory=128Mi \
  --set operator.resources.limits.cpu=250m \
  --set operator.resources.limits.memory=256Mi
```

Notes:
- `clusterPoolIPv4PodCIDRList="10.244.0.0/16"` matches the kubeadm default pod CIDR. Verify with `kubectl cluster-info dump | grep -m 1 cluster-cidr`.
- `kubeProxyReplacement=true` replaces kube-proxy with Cilium's eBPF implementation
- `k8sServiceHost` must be the actual IP of the control plane node (not a DNS name)
- Resource limits satisfy the Kyverno `require-resource-limits` policy
- `operator.replicas=1` is appropriate for a small cluster
- Hubble metrics are configured for Grafana Cloud integration

**Step 3: Verify Cilium is healthy**

```bash
cilium status --wait
cilium connectivity test
```

**Step 4: Restart all pods to pick up the new CNI**

```bash
# Restart all deployments
kubectl get deployments -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name --no-headers | \
  while read ns name; do kubectl rollout restart deployment/$name -n $ns; done

# Restart all statefulsets
kubectl get statefulsets -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name --no-headers | \
  while read ns name; do kubectl rollout restart statefulset/$name -n $ns; done

# Restart all daemonsets (except Cilium itself)
kubectl get daemonsets -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name --no-headers | \
  grep -v cilium | while read ns name; do kubectl rollout restart daemonset/$name -n $ns; done
```

**Step 5: Verify cluster health**

```bash
# All pods running
kubectl get pods -A

# Flux reconciling
flux get kustomizations
flux get helmreleases -A

# Hubble flows visible
hubble observe --last 10

# Storage still working
kubectl get pvc -A
```

**Step 6: Verify Flannel remnants are cleaned up**

```bash
# Confirm no Flannel CNI config remains (should have been removed in Step 1)
ls /etc/cni/net.d/
# Should only show Cilium's 05-cilium.conflist
```

### Phase 2: Bring Cilium Under Flux Management (Post-Migration, No Downtime)

Create the following files in the repository:

1. **`infrastructure/base/cilium/namespace.yaml`** -- Cilium runs in `kube-system`, no namespace needed
2. **`infrastructure/base/cilium/helm-release.yaml`** -- HelmRelease matching the Helm values from Phase 1
3. **`infrastructure/base/cilium/kustomization.yaml`** -- Kustomize wrapper

Add the Cilium HelmRepository to Flux addons. Add the Cilium HelmRelease health check to the `infrastructure-crds` Kustomization (since Cilium installs CRDs).

**Critical:** Pin the Cilium chart version. Do not use `version: "*"` for the CNI. A broken Cilium upgrade kills all networking.

```yaml
# infrastructure/base/cilium/helm-release.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cilium
  namespace: kube-system
spec:
  interval: 30m
  chart:
    spec:
      chart: cilium
      version: "1.19.1"  # PIN THIS. Never use * for the CNI.
      sourceRef:
        kind: HelmRepository
        name: cilium
        namespace: flux-system
      interval: 1h
  install:
    crds: CreateReplace
  upgrade:
    crds: CreateReplace
  values:
    # ... same values as Phase 1 helm install
```

### Phase 3: NetworkPolicy Rollout (Gradual, Over Multiple PRs)

**Do not deploy all NetworkPolicies at once.** Roll them out namespace by namespace, starting with the least critical.

**Order of rollout:**
1. **monitoring** -- low risk, easy to test (metrics still flowing to Grafana Cloud?)
2. **backstage** -- low risk, easy to test (can you load the Backstage UI?)
3. **democratic-csi** -- test PVC creation and mounting
4. **arc-runners / packer-runners** -- test a GitHub Actions workflow
5. **traefik-system** -- test all IngressRoutes still work
6. **flux-system** -- test reconciliation still works
7. **onepassword-system** -- test secret sync
8. **kube-system** -- highest risk, test last. CoreDNS must remain reachable.

For each namespace:
1. Deploy the default-deny policy in **audit mode** first (Cilium supports `policy-audit-mode` per endpoint)
2. Monitor Hubble for dropped flows -- these are the allowlist entries you need
3. Write the allowlist policies
4. Switch from audit to enforce
5. Verify the service still works
6. Commit and PR

### Phase 4: Packer Image Update (Separate PR)

Update `packer/scripts/provision-k8s-node.sh` to skip Flannel installation and prepare new nodes for Cilium. This ensures new nodes join the cluster with the correct CNI configuration. The kubeadm join command should not install Flannel or kube-proxy.

### Rollback Plan

If Cilium installation fails or causes irrecoverable issues:

1. **Uninstall Cilium:** `helm uninstall cilium -n kube-system`
2. **Re-deploy Flannel:** `kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml`
3. **Re-deploy kube-proxy:** `kubeadm init phase addon kube-proxy --kubeconfig /etc/kubernetes/admin.conf`
4. **Restart all pods** to pick up Flannel networking again
5. **Verify:** Run the post-deploy health check

The rollback window is the same 30-60 minutes. Keep the etcd snapshot from the prerequisites in case of catastrophic failure.

---

## Cilium-Specific Decisions

### Hubble: Complement, Not Replace, Grafana Cloud

Hubble adds a **network observability layer** that Grafana Alloy does not provide. The architecture:

```
Cilium Agent (per node)
    |
    v
Hubble (per node) -- collects eBPF flow data
    |
    v
Hubble Relay -- aggregates flows across nodes
    |
    v
Hubble UI -- local web UI for ad-hoc debugging (optional)
    |
    v
Hubble Metrics (/metrics endpoint)
    |
    v
Grafana Alloy -- scrapes Hubble metrics
    |
    v
Grafana Cloud -- dashboards, alerts
```

Deploy the [Cilium/Hubble Grafana dashboards](https://grafana.com/grafana/dashboards/16613-hubble/) to Grafana Cloud for visibility into:
- Policy drop rates per namespace
- DNS query latency and failure rates
- HTTP request rates and error percentages per service pair
- TCP connection establishment times

### Cilium Service Mesh: Do NOT Enable

Cilium offers an Envoy-based service mesh mode. Do not enable it. Traefik already handles L7 routing, TLS termination, and middleware. Cilium's service mesh would duplicate this functionality, add complexity, and create confusion about which component is handling what.

### Cilium L7 Policies: Use Sparingly

CiliumNetworkPolicy supports L7 rules (HTTP method/path matching). These are powerful but add Envoy proxy overhead to affected pods. Use L7 policies only where L4 policies are insufficient -- for example, if you need to allow Backstage to call only specific Kubernetes API paths.

For the initial rollout, stick to L3/L4 policies (IP + port). Add L7 policies later if a specific threat model requires them.

### Cilium L2 Announcements (MetalLB Replacement): Defer

Cilium can replace MetalLB for L2 load balancer IP announcements. This is a worthwhile simplification (one fewer component), but it should be a separate, later change. Reason: the CNI migration is already high-risk. Do not combine it with a MetalLB migration. Stabilize Cilium first, then evaluate MetalLB replacement as a follow-up.

---

## Estimated Effort

| Phase | Effort | Risk | Downtime |
|-------|--------|------|----------|
| Phase 1: Cilium install | 2-4 hours | High (CNI swap) | 30-60 min |
| Phase 2: Flux management | 1-2 hours | Low | None |
| Phase 3: NetworkPolicy rollout | 1-2 weeks (incremental) | Medium (per namespace) | None (if done in audit-first mode) |
| Phase 4: Packer update | 1 hour | Low | None |

---

## References

- [Cilium Quick Installation (kubeadm)](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/)
- [Cilium Migration Guide](https://docs.cilium.io/en/latest/installation/k8s-install-migration/)
- [Cilium kube-proxy Replacement](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
- [Cilium and Traefik: Better Together](https://traefik.io/blog/cilium-and-traefik-together)
- [Cilium L2 Announcements (MetalLB Alternative)](https://blog.stonegarden.dev/articles/2023/12/migrating-from-metallb-to-cilium/)
- [Cilium Hubble Grafana Dashboard](https://grafana.com/grafana/dashboards/16613-hubble/)
- [Cilium Enterprise Grafana Cloud Integration](https://grafana.com/docs/grafana-cloud/monitor-infrastructure/integrations/integration-reference/integration-cilium-enterprise/)
- [CNI Comparison 2025: Flannel vs Calico vs Cilium](https://blog.devops.dev/stop-using-the-wrong-cni-flannel-vs-calico-vs-cilium-in-2025-c11b42ce05a3)
- [Isovalent Cilium Migration Tutorial](https://isovalent.com/blog/post/tutorial-migrating-to-cilium-part-1/)
