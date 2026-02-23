# Caddy to Traefik Migration & ACME TLS Fix (KAZ-84)

This document explains the migration from Caddy to Traefik as the reverse proxy / TLS terminator in the homelab, including the ACME certificate issue we hit and how it was resolved.

## Architecture Overview

The homelab runs Kubernetes (kubeadm) with Flux GitOps. A reverse proxy sits in front of all services, handling:

- **TLS termination** — obtains Let's Encrypt certificates via ACME DNS-01 challenge
- **Routing** — maps hostnames (e.g. `truenas.lab.kazie.co.uk`) to backend services
- **Security headers** — applies HSTS, X-Frame-Options, etc. via middleware

The proxy runs as a Kubernetes workload with a MetalLB `LoadBalancer` Service on IP `10.2.0.200`. Cloudflare DNS A records point each hostname to this IP.

## Caddy (Previous)

### How It Worked

Caddy ran as a plain `Deployment` with a `ConfigMap`-based Caddyfile. The Caddyfile defined each route:

```
truenas.lab.kazie.co.uk {
    reverse_proxy https://10.2.0.232:443 {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
```

Caddy's built-in ACME client used the Cloudflare DNS plugin (`caddy-cloudflare` image) to solve DNS-01 challenges. It requested a **wildcard certificate** (`*.lab.kazie.co.uk`) covering all subdomains.

### Key Components

| Resource | Purpose |
|----------|---------|
| `Deployment` (caddy) | Ran the Caddy container with Cloudflare DNS plugin |
| `ConfigMap` (caddy-config) | Caddyfile with route definitions |
| `Service` (LoadBalancer) | Exposed Caddy on `10.2.0.200` |
| `PVC` (caddy-data) | Persisted ACME certs in `/data` |
| `OnePasswordItem` | Synced `CF_API_TOKEN` from 1Password |

### Why We Moved Away

- **No Kubernetes-native integration** — routes were defined in a monolithic Caddyfile ConfigMap, not Kubernetes CRDs. Adding a route meant editing the ConfigMap and restarting Caddy.
- **No Helm chart** — Caddy was deployed as raw manifests. No community chart for updates, health checks, or configuration management.
- **Limited observability** — no built-in dashboard, metrics were harder to expose.
- **Custom image dependency** — required `caddy-cloudflare` (a third-party multi-arch build) for DNS-01 challenges. Upstream Caddy doesn't include Cloudflare DNS natively.

## Traefik (Current)

### How It Works

Traefik runs via the official Helm chart as a `HelmRelease` managed by Flux. Routes are defined as Kubernetes CRDs (`IngressRoute`), making them first-class Kubernetes resources.

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: truenas
  namespace: traefik-system
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`truenas.lab.kazie.co.uk`)
      kind: Rule
      services:
        - name: truenas-external
          port: 443
          scheme: https
          serversTransport: insecure-skip-verify
      middlewares:
        - name: security-headers
  tls:
    certResolver: letsencrypt
```

Each `IngressRoute` gets its own Let's Encrypt certificate (per-hostname, not wildcard). Traefik's built-in ACME client uses DNS-01 challenges via Cloudflare.

### Key Components

| Resource | Purpose |
|----------|---------|
| `HelmRelease` (traefik) | Installs Traefik via official Helm chart |
| `IngressRoute` (per service) | Defines routing rules as Kubernetes CRDs |
| `Middleware` (security-headers) | Shared middleware for HSTS, XSS protection, etc. |
| `ServersTransport` (insecure-skip-verify) | Allows Traefik to connect to HTTPS backends with self-signed certs |
| `Service` + `Endpoints` (external) | Selectorless services pointing to external IPs (TrueNAS, Home Assistant) |
| `PVC` (traefik-data) | Persists ACME certs in `/data/acme.json` |
| `OnePasswordItem` | Syncs `CF_DNS_API_TOKEN` from 1Password |

### Advantages Over Caddy

- **Kubernetes-native routing** — each route is an `IngressRoute` CRD. Adding a route is a new YAML file, not editing a monolith.
- **Official Helm chart** — managed upgrades, configurable via `values`, CRD lifecycle handled automatically.
- **Dashboard** — built-in web UI at `test-traefik.lab.kazie.co.uk` showing all routes, middlewares, and services.
- **Middleware system** — reusable middleware resources (headers, rate limiting, auth) referenced by name from any route.
- **Backstage integration** — routes can be scaffolded via Backstage templates that generate `IngressRoute` YAML and open a PR.

## The ACME DNS-01 Challenge Issue

### Symptom

After migrating from Caddy to Traefik, all services showed `NET::ERR_CERT_AUTHORITY_INVALID` in the browser. Traefik was serving its default self-signed certificate instead of Let's Encrypt certs.

### Background: How DNS-01 Works

1. Traefik asks Let's Encrypt for a certificate for `truenas.lab.kazie.co.uk`
2. Let's Encrypt responds with a challenge token
3. Traefik creates a TXT record: `_acme-challenge.truenas.lab.kazie.co.uk` with the token value (via Cloudflare API)
4. Let's Encrypt queries Cloudflare's authoritative nameservers for the TXT record
5. If the TXT record matches, the certificate is issued
6. Traefik deletes the TXT record

### What Went Wrong

The ACME challenges failed at step 4 — Let's Encrypt couldn't find the TXT records. The lego ACME client (used by Traefik) also pre-checks TXT propagation before telling Let's Encrypt to verify, and these pre-checks were returning `NXDOMAIN`.

### Root Cause: Cloudflare Authoritative Nameserver Negative Caching

This was **not** an API issue — the TXT records were being created successfully via the Cloudflare API. The problem was at the DNS resolution layer.

**Cloudflare's authoritative nameservers cache negative (NXDOMAIN) responses.** When a DNS query for `_acme-challenge.truenas.lab.kazie.co.uk` returns NXDOMAIN (because the TXT record doesn't exist yet), Cloudflare caches that NXDOMAIN for the duration of the zone's SOA minimum TTL (1800 seconds = 30 minutes).

The sequence:

1. Traefik's lego client creates the TXT record via Cloudflare API (succeeds)
2. Lego immediately queries `_acme-challenge.truenas.lab.kazie.co.uk` to verify propagation
3. But Cloudflare's authoritative NS returns cached NXDOMAIN from a query moments earlier (when the record didn't exist yet)
4. Lego sees NXDOMAIN, retries, each retry refreshes the negative cache timer
5. After retries exhausted, lego gives up and the challenge fails

This was proven by testing:
- **Fresh names** (never queried before) resolved immediately after creation via API
- **Previously-queried names** returned NXDOMAIN for up to 30 minutes, even after the record existed
- The problem was specific to the authoritative NS negative cache, not Cloudflare's API or proxy layer

### The Fix

Two configuration changes in the Traefik HelmRelease:

```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      dnsChallenge:
        provider: cloudflare
        propagation:
          delayBeforeChecks: "60"    # Wait 60s after creating TXT before checking
          disableChecks: true         # Skip propagation verification entirely
        resolvers:
          - "1.1.1.1:53"
```

- **`propagation.delayBeforeChecks: "60"`** — after creating the TXT record via Cloudflare API, wait 60 seconds before proceeding. This gives Cloudflare's authoritative NS time to serve the new record even if there was a prior negative cache.
- **`propagation.disableChecks: true`** — skip lego's pre-verification DNS queries entirely. These queries would hit the authoritative NS, get cached NXDOMAINs, and refresh the negative cache timer. By skipping them, we avoid poisoning the cache ourselves.

With both settings, the flow becomes:
1. Create TXT record via API
2. Wait 60 seconds (no DNS queries during this time)
3. Tell Let's Encrypt to verify (Let's Encrypt queries the authoritative NS, which by now has the record)
4. Certificate issued

### Additional Fix: Wildcard Domain Removal

The initial Caddy→Traefik migration mistakenly included `domains` blocks in IngressRoutes that requested wildcard certs:

```yaml
# WRONG — requests a wildcard cert
tls:
  certResolver: letsencrypt
  domains:
    - main: "lab.kazie.co.uk"
      sans:
        - "*.lab.kazie.co.uk"
```

This was removed from all IngressRoutes. Each route now uses per-hostname certs:

```yaml
# CORRECT — cert is derived from the Host() match
tls:
  certResolver: letsencrypt
```

### Deprecated Config Gotcha

Traefik v3.6 **deprecated and silently ignores** the old `delayBeforeCheck` option (singular "Check"). The replacement is `propagation.delayBeforeChecks` (plural "Checks"). The deprecation warning appears in logs but the old value has **no effect** — it doesn't just warn, it completely ignores the setting.

## Caddy vs Traefik Comparison

| Feature | Caddy | Traefik |
|---------|-------|---------|
| **Configuration** | Caddyfile (text file, ConfigMap) | Kubernetes CRDs (`IngressRoute`, `Middleware`) |
| **Route definition** | Inline in Caddyfile | Separate YAML per route |
| **ACME client** | Built-in, automatic per hostname | Built-in (lego), needs explicit `certResolver` |
| **DNS-01 provider** | Plugin (requires custom image) | Built-in (Cloudflare, Route53, etc.) |
| **Certificate scope** | Per-hostname or wildcard | Per-hostname or wildcard (per IngressRoute) |
| **Middleware** | Inline in Caddyfile blocks | Reusable CRD resources |
| **Dashboard** | None built-in | Built-in web UI |
| **Helm chart** | No official chart | Official, well-maintained chart |
| **Backend TLS** | `tls_insecure_skip_verify` in Caddyfile | `ServersTransport` CRD |
| **External services** | Direct IP in `reverse_proxy` | Selectorless `Service` + `Endpoints` |
| **Kubernetes-native** | No (raw Deployment) | Yes (CRDs, Helm, providers) |
| **Configuration reload** | Automatic on ConfigMap change | Automatic on CRD change |
| **Resource usage** | ~50m CPU / 64Mi RAM | ~100m CPU / 128Mi RAM |

### When to Use Each

**Caddy** is better when:
- Running outside Kubernetes (bare metal, Docker Compose)
- You want the simplest possible configuration (Caddyfile is very readable)
- Automatic HTTPS with zero configuration is the priority
- You don't need Kubernetes-native integration

**Traefik** is better when:
- Running in Kubernetes and want native CRD-based routing
- You need a Helm chart for managed upgrades
- You want reusable middleware as Kubernetes resources
- You need a dashboard for route visibility
- Routes should be managed as individual YAML files (GitOps-friendly)

## File Locations

```
infrastructure/base/traefik/
  helm-release.yaml          # Traefik HelmRelease (chart config, ACME, resources)
  helm-repository.yaml       # Helm repo source
  kustomization.yaml         # Kustomize resources list
  namespace.yaml             # traefik-system namespace
  pvc.yaml                   # Persistent volume for ACME data

platform/base/traefik-config/
  kustomization.yaml          # Kustomize resources list
  middleware.yaml              # Security headers middleware
  servers-transport.yaml       # Skip TLS verify for self-signed backends
  external-services.yaml       # Service+Endpoints for TrueNAS, Home Assistant, Backstage
  ingressroutes.yaml           # All application IngressRoutes
  test-ingressroute.yaml       # Traefik dashboard IngressRoute

platform/base/backstage/templates/add-reverse-proxy/
  template.yaml                # Backstage scaffolder template
  skeleton/                    # Generated files (IngressRoute + optional Service)
```
