# ARC Org-Level Runner Setup — GitHub App Authentication

## Overview

Self-hosted GitHub Actions runners are managed by Actions Runner Controller (ARC)
and scoped to the **Diixtra organisation**, so any repo in the org can use
`runs-on: homelab` or `runs-on: packer`.

Authentication uses a **GitHub App** (not a PAT). This avoids tying runner
access to a personal account and provides fine-grained permissions with higher
API rate limits.

## Prerequisites

- Admin access to the [Diixtra GitHub organisation](https://github.com/Diixtra)
- Access to the `Homelab` vault in 1Password
- `kubectl` access to the homelab cluster (for verification)

## Step 1: Create the GitHub App

1. Go to **GitHub → Diixtra org → Settings → Developer settings → GitHub Apps → New GitHub App**
   (direct link: `https://github.com/organizations/Diixtra/settings/apps/new`)

2. Configure the app:

   | Field | Value |
   |---|---|
   | App name | `diixtra-arc-runners` (must be globally unique) |
   | Homepage URL | `https://github.com/Diixtra` |
   | Webhook | **Uncheck** "Active" (ARC uses polling, not webhooks) |

3. Set **Repository permissions**:

   | Permission | Access |
   |---|---|
   | Actions | Read-only |
   | Metadata | Read-only (auto-selected) |

4. Set **Organisation permissions**:

   | Permission | Access |
   |---|---|
   | Self-hosted runners | Read and write |

5. Under **"Where can this GitHub App be installed?"**, select **Only on this account**.

6. Click **Create GitHub App**.

7. Note the **App ID** from the app's settings page.

## Step 2: Generate a Private Key

1. On the GitHub App settings page, scroll to **Private keys**.
2. Click **Generate a private key**.
3. A `.pem` file will be downloaded — keep it safe.

## Step 3: Install the App on the Organisation

1. On the GitHub App settings page, click **Install App** in the sidebar.
2. Select the **Diixtra** organisation.
3. Choose **All repositories** (so future repos automatically get runner access).
4. Click **Install**.
5. Note the **Installation ID** from the URL:
   `https://github.com/organizations/Diixtra/settings/installations/<INSTALLATION_ID>`

## Step 4: Create the 1Password Item

Create a new item in the `Homelab` vault named **`github-actions-runner-app`**.

> **Important**: The private key **must** be stored as a **file attachment**,
> not a text field. The 1Password operator strips newlines from text fields,
> which breaks PEM parsing. File attachments preserve formatting.
> See `docs/troubleshooting/arc-org-runner-crash-loop.md` (Stage 3).

Using the `op` CLI (recommended):

```bash
# Download the .pem file from Step 2, then:
op item create \
  --vault Homelab \
  --category Login \
  --title "github-actions-runner-app" \
  "github_app_id[text]=<APP_ID>" \
  "github_app_installation_id[text]=<INSTALLATION_ID>" \
  "github_app_private_key[file]=</path/to/private-key.pem>"
```

Or if the item already exists and needs to be fixed (e.g. the private key was
stored as a text field):

```bash
# 1. Save the PEM to a temp file (skip if you still have the original .pem)
op read "op://Homelab/github-actions-runner-app/github_app_private_key" \
  > /tmp/github_app_private_key.pem

# 2. Delete the broken text field
op item edit "github-actions-runner-app" --vault Homelab \
  "github_app_private_key[delete]"

# 3. Re-add as a file attachment (preserves newlines)
op item edit "github-actions-runner-app" --vault Homelab \
  "github_app_private_key[file]=/tmp/github_app_private_key.pem"

# 4. Clean up the temp file
rm /tmp/github_app_private_key.pem

# 5. Force the 1Password operator to resync the secret
kubectl annotate onepassworditem github-config-secret -n arc-runners \
  force-sync=$(date +%s) --overwrite
kubectl annotate onepassworditem github-config-secret -n packer-runners \
  force-sync=$(date +%s) --overwrite

# 6. Verify the secret has properly-formatted PEM
kubectl get secret github-config-secret -n arc-runners \
  -o jsonpath='{.data.github_app_private_key}' | base64 -d | head -2
# Expected:
#   -----BEGIN RSA PRIVATE KEY-----
#   <base64 line>
```

| Field name | Type | Value |
|---|---|---|
| `github_app_id` | text | The App ID from Step 1 (e.g., `123456`) |
| `github_app_installation_id` | text | The Installation ID from Step 3 (e.g., `654321`) |
| `github_app_private_key` | **file** | The `.pem` file from Step 2 |

> **Why file, not text?** The 1Password operator syncs text fields as
> single-line strings (newlines become spaces). PEM keys require line breaks
> between the header, base64 body, and footer. File attachments are synced
> verbatim, preserving the required formatting.

After creating the item, you can delete the downloaded `.pem` file — 1Password
is now the source of truth.

## Step 5: Verify

After Flux reconciles (up to 10 minutes, or force with `flux reconcile`):

```bash
# Check the secrets exist in both runner namespaces
kubectl get secret github-config-secret -n arc-runners
kubectl get secret github-config-secret -n packer-runners

# Verify the secret has the correct keys (should show 3 keys, not 1)
kubectl get secret github-config-secret -n arc-runners -o jsonpath='{.data}' | jq 'keys'
# Expected: ["github_app_id", "github_app_installation_id", "github_app_private_key"]

# Check ARC runner sets are healthy
flux get helmreleases -n arc-runners
flux get helmreleases -n packer-runners

# Verify listener pods are running (they authenticate with the GitHub App)
kubectl get pods -n arc-runners
kubectl get pods -n packer-runners

# Check listener logs for successful authentication
kubectl logs -n arc-runners -l app.kubernetes.io/component=runner-scale-set-listener --tail=20
```

## Step 6: Test from Another Org Repo

Create a test workflow in any other Diixtra org repo:

```yaml
# .github/workflows/test-runner.yml
name: Test self-hosted runner
on: workflow_dispatch
jobs:
  test:
    runs-on: homelab
    steps:
      - run: echo "Running on self-hosted homelab runner"
      - run: uname -a
```

Trigger it via **Actions → Test self-hosted runner → Run workflow**. The job
should be picked up by the ARC runner within 30 seconds.

To also verify the packer runner, add a second job with `runs-on: packer`.
Test this separately since the packer runner uses a privileged security context
and has `maxRunners: 1`.

## Troubleshooting

### Listener pod not starting

```bash
kubectl describe pod -n arc-runners -l app.kubernetes.io/component=runner-scale-set-listener
kubectl logs -n arc-runners -l app.kubernetes.io/component=runner-scale-set-listener
```

Common causes:
- 1Password item field names don't match (check for typos, hyphens vs underscores)
- GitHub App not installed on the org
- GitHub App missing required permissions

### Runners not picking up jobs from other repos

- Verify the GitHub App is installed with **All repositories** access
- Verify `ARC_GITHUB_CONFIG_URL` in `clusters/homelab/vars.yaml` is set to
  `https://github.com/Diixtra` (org-level, not repo-level)
- Check the App's **Organisation permissions → Self-hosted runners** is set to
  Read and write

### Rolling back to PAT auth

If you need to revert temporarily (this uses the new variable-substitution
plumbing with a PAT item, not a full git revert):

1. In `clusters/homelab/vars.yaml`, change `ARC_GITHUB_CONFIG_URL` back to
   `https://github.com/Diixtra/diixtra-forge` and change `OP_ITEM_ARC_GITHUB_APP`
   to the name of a PAT-based 1Password item (e.g. `github-actions-runner-pat` —
   create this item in 1Password if it does not exist)
2. Ensure the 1Password item has a single `github_token` field with a classic PAT
   that has `repo` scope (repo-level URL) or `repo` + `admin:org` scope (org-level URL)
3. Commit and push — Flux will reconcile

## Architecture Reference

```
GitHub App (diixtra-arc-runners)
  installed on: Diixtra org (all repos)
  permissions: Actions (read), Self-hosted runners (read/write)
       │
       │  credentials stored in
       ▼
1Password vault "Homelab"
  item: "github-actions-runner-app"
  fields: github_app_id (text), github_app_installation_id (text),
          github_app_private_key (file attachment — NOT text field)
       │
       │  1Password Operator syncs to K8s
       ▼
K8s Secret "github-config-secret"
  ├── namespace: arc-runners     (for homelab runner set)
  └── namespace: packer-runners  (for packer runner set)
       │
       │  ARC reads at startup
       ▼
Listener pods authenticate as GitHub App
  → long-poll for queued jobs matching runs-on: homelab / packer
  → create JIT tokens for ephemeral runner pods
```
