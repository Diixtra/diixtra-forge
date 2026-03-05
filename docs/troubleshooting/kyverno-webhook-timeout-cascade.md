# Kyverno Webhook Timeout Cascade — Flux Reconciliation Blocked

**Date:** 2026-03-05
**Affected Components:** Kyverno, Flux CD (all controllers)
**Impact:** When Kyverno is unhealthy, its fail-closed validating webhook times out on every Flux dry-run, blocking the entire reconciliation chain — including flux-system itself.
**Root Cause:** Kyverno's webhook is called by the API server for every dry-run, even in namespaces where no Enforce policies apply.

## Symptoms

- All Flux Kustomizations stuck in `Not Ready` with timeout errors
- `flux get kustomizations` shows errors like `context deadline exceeded`
- Kyverno pods crash-looping or not ready
- Manual `kubectl` operations in affected namespaces hang for 30 seconds before failing

## Root Cause

Kyverno's validating webhook uses `failurePolicy: Fail` (fail-closed). The API server calls this webhook for **every** dry-run and create/update operation across all namespaces. When Kyverno is unhealthy (crash loop, startup, OOM), the webhook times out (default 30s) and the API server rejects the request.

Flux controllers perform dry-runs during every reconciliation cycle. When the webhook times out, the dry-run fails, and Flux marks the Kustomization as `Not Ready`. This affects **all** Flux Kustomizations — including the infrastructure layer that deploys Kyverno itself — creating a circular dependency.

The critical distinction:

| Mechanism | How it works | When Kyverno is down |
|---|---|---|
| `config.resourceFilters` | Kyverno receives the request and returns immediate allow | **Still blocks** — Kyverno must be reachable |
| `config.webhooks.namespaceSelector` | API server skips the webhook entirely for excluded namespaces | **Works** — API server never calls Kyverno |

Only the `namespaceSelector` approach prevents timeouts when Kyverno is completely unreachable.

## Fix Applied

Added a `namespaceSelector` to Kyverno's webhook configuration in `platform/base/kyverno/helm-release.yaml`:

```yaml
config:
  webhooks:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values:
            - kyverno-system
            - kube-system
            - flux-system
            - monitoring
            - democratic-csi
```

This tells the API server to skip the Kyverno webhook entirely for these namespaces. The namespaces were chosen because every Enforce policy in `kyverno-policies/` already excludes them.

**Helm chart syntax note:** The Kyverno Helm chart expects `config.webhooks` as a map, not a list. Using list syntax (`- namespaceSelector:`) silently fails to apply the exclusion.

See: commit 8b78780 (`fix(kyverno): exclude system namespaces from webhook to prevent timeout cascade (#650)`)

## Important Caveat

If you add a new Enforce policy to `kyverno-policies/`, verify its `exclude` list covers the namespaces listed in the webhook selector above. Otherwise, the webhook exclusion creates a gap where the policy is not enforced in those namespaces but the policy's exclude list doesn't explicitly account for it.

## Diagnostic Commands

```bash
# Check if Kyverno webhook is configured with namespace exclusions
kubectl get validatingwebhookconfigurations -l app.kubernetes.io/instance=kyverno -o yaml | grep -A 10 namespaceSelector

# Check Kyverno pod health
kubectl get pods -n kyverno-system

# Test if dry-runs work in an excluded namespace (should succeed even if Kyverno is down)
kubectl create deployment test --image=nginx --dry-run=server -n flux-system

# Test if dry-runs work in a non-excluded namespace (will timeout if Kyverno is down)
kubectl create deployment test --image=nginx --dry-run=server -n backstage

# Check Flux reconciliation status
flux get kustomizations
```

## Prevention

1. The webhook `namespaceSelector` ensures that critical system namespaces (flux-system, kube-system) are never blocked by Kyverno outages.
2. Kyverno is scheduled on amd64 nodes only — Pi nodes lack sufficient memory for the admission controller.
3. Kyverno has GPU node tolerations to allow scheduling flexibility.
