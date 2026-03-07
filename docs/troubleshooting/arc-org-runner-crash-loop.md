# ARC Org-Level Runner Crash Loop — Listeners Terminating

**Date:** 2026-03-06
**Affected Components:** ARC listener pods (homelab, packer) in `arc-system` namespace
**Impact:** All self-hosted runner workflows stuck in `queued` state; no runners spawning
**Root Cause:** Chain of 4 interrelated failures (1Password operator crash, stale PAT credentials, malformed PEM key, runner group public repo restriction)

## Symptoms

- All ARC listener pods crash-looping in `arc-system` (status: `Error` / `Terminating`)
- GitHub Actions workflows using `runs-on: homelab` or `runs-on: packer` stuck `queued` indefinitely
- ARC controller pod healthy (`Running 1/1`), but unable to maintain stable listeners
- Duplicate listener pods per runner set (two homelab listeners, two packer listeners)
- `gh api /orgs/Diixtra/actions/runners` returning 0 runners

## Root Cause Chain

### Stage 1: 1Password Operator WASM Crash

The 1Password Connect Operator hit a WASM out-of-bounds memory error, preventing all secret syncs across the cluster:

```
failed to GetVaultsByTitle using 1Password SDK: wasm error: out of bounds memory access
wasm stack trace:
    op_extism_core.wasm._ZN61_$LT$dlmalloc..sys..System$u20$as$u20$dlmalloc..Allocator$GT$5alloc...
```

This affected every `OnePasswordItem` CR in the cluster (ARC credentials, Backstage, Cloudflare, etc.). The operator was unable to sync the GitHub App credentials from 1Password to the `github-config-secret` Kubernetes secrets.

**Fix:** Restart the operator deployment:
```bash
kubectl rollout restart deployment -n onepassword-system onepassword-connect-operator
```

### Stage 2: Stale PAT Instead of GitHub App Credentials

Because the 1Password operator couldn't sync, the `github-config-secret` in both `arc-runners` and `packer-runners` namespaces contained stale PAT tokens (`github_token`, `token` fields) instead of the expected GitHub App credentials (`github_app_id`, `github_app_installation_id`, `github_app_private_key`).

The org-level config URL (`https://github.com/Diixtra`) requires GitHub App auth. PAT auth returned a 403:
```
Resource not accessible by personal access token
```

**Fix:** After restarting the operator, it re-synced the correct GitHub App credentials from the `github-actions-runner-app` 1Password item.

### Stage 3: Malformed PEM Private Key

The 1Password operator stored the `github_app_private_key` field as a single line with spaces instead of newlines. PEM keys require proper line breaks for parsing:

```
failed to parse RSA private key from PEM: invalid key: Key must be a PEM encoded PKCS1 or PKCS8 key
```

The same 1Password item also contained the key as a `.pem` file attachment (`Diixtra-Arc-Runners-Private-Key-Mar-05-2026.pem`), which preserved the correct formatting.

**Fix:** The root cause is that the `github_app_private_key` was stored as a text field in 1Password. The operator strips newlines from text fields. The permanent fix is to store the PEM as a **file attachment** instead:

```bash
# 1. Save the PEM (from the existing .pem attachment or from the text field)
op read "op://Homelab/github-actions-runner-app/github_app_private_key" \
  > /tmp/github_app_private_key.pem

# 2. Delete the text field
op item edit "github-actions-runner-app" --vault Homelab \
  "github_app_private_key[delete]"

# 3. Re-add as a file attachment (preserves newlines through operator syncs)
op item edit "github-actions-runner-app" --vault Homelab \
  "github_app_private_key[file]=/tmp/github_app_private_key.pem"

# 4. Clean up
rm /tmp/github_app_private_key.pem

# 5. Force resync
kubectl annotate onepassworditem github-config-secret -n arc-runners \
  force-sync=$(date +%s) --overwrite
kubectl annotate onepassworditem github-config-secret -n packer-runners \
  force-sync=$(date +%s) --overwrite
```

See `docs/runbooks/arc-org-runner-setup.md` Step 4 for full details.

### Stage 4: Stale Scale Set Registration

The `githubConfigUrl` had been changed from repo-level (`https://github.com/Diixtra/diixtra-forge`) to org-level (`https://github.com/Diixtra`), but the `AutoscalingRunnerSet` still had the old `runner-scale-set-id: 1` from the repo-level registration. The org-level GitHub endpoint didn't recognise this ID:

```
No runner scale set found with identifier 1
```

Additionally, stale `AutoscalingListener` resources remained from the old repo-scoped config, creating duplicate listeners per runner set.

**Fix:** Uninstall and reinstall the Helm releases to get fresh scale set registrations:
```bash
# For each runner set (homelab, packer):
flux suspend helmrelease <name> -n <namespace>
helm uninstall <release-name> -n <namespace>
flux resume helmrelease <name> -n <namespace>
```

### Stage 5: Runner Group Public Repo Restriction

After all the above fixes, the listeners were healthy but still showed `totalAvailableJobs: 0`. The org-level "Default" runner group had `allows_public_repositories: false`, but `diixtra-forge` is a public repository.

**Fix:** Enable public repo access on the runner group:
```bash
gh api -X PATCH /orgs/Diixtra/actions/runner-groups/1 --input - <<'EOF'
{"allows_public_repositories": true}
EOF
```

## Investigation Steps

1. **Check listener pods:** `kubectl get pods -n arc-system -o wide` — look for `Error`/`Terminating`/crash-loop
2. **Check listener logs:** `kubectl logs -n arc-system <listener-pod>` — reveals the specific auth/registration error
3. **Check 1Password operator:** `kubectl logs -n onepassword-system <operator-pod> --tail=30` — look for WASM or sync errors
4. **Check secret contents:** Verify the secret has `github_app_id`, `github_app_installation_id`, `github_app_private_key` (not `github_token`/`token`)
5. **Verify PEM formatting:** Decode `github_app_private_key` and check for proper newlines between base64 lines
6. **Check scale set registration:** Look for `No runner scale set found with identifier` errors in listener logs
7. **Check runner group:** `gh api /orgs/Diixtra/actions/runner-groups` — verify `allows_public_repositories` matches repo visibility
8. **Check listener count:** There should be exactly ONE listener per runner set. Duplicates indicate stale resources.

## Prevention

- Monitor 1Password operator health — the WASM crash is a known issue that requires operator restart
- When changing `githubConfigUrl` scope (repo to org or vice versa), always uninstall and reinstall the Helm release to re-register the scale set
- Store PEM keys as **file attachments** in 1Password, not as text fields — the operator strips newlines from text fields (see `docs/runbooks/arc-org-runner-setup.md` Step 4 for the `op` CLI commands)
- After any ARC configuration change, verify listeners are stable for >60 seconds before considering the change complete
- Ensure runner group settings match repo visibility (`allows_public_repositories` must be `true` if any target repo is public)
