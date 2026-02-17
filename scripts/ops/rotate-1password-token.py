#!/usr/bin/env python3
"""
Rotate 1Password Service Account Token
========================================

Replaces the 1Password Operator bootstrap secret with a new token.
Use this when:
  - The Service Account token has been rotated in 1Password admin console
  - The operator is stuck in CrashLoopBackOff with "invalid token format"
  - You're recovering from a re-bootstrap that wiped the secret

LEARNING NOTE — WHY TOKEN ROTATION ISN'T GITOPS:
    The 1Password bootstrap secret is the ONE resource that CANNOT be
    managed via GitOps. It's the credential that enables the secret
    management system itself — a chicken-and-egg problem that every
    secret manager has.

    HashiCorp Vault has unseal keys. AWS has IAM credentials. External
    Secrets Operator has provider tokens. For us, it's the 1Password
    Service Account token stored as a Kubernetes Secret.

    This script is the ONLY way to update this secret. It:
      1. Deletes the old secret (if it exists)
      2. Creates a new one with the new token
      3. Restarts the operator pod to pick up the change
      4. Waits for the operator to become healthy

    The secret name MUST be `onepassword-service-account-token` — this is
    the Helm chart's default that the operator pod mounts directly. Previous
    versions used a different name (`op-service-account-token`) with
    HelmRelease valuesFrom indirection, which broke on every re-bootstrap.
    KAZ-71 fixed this to use direct mounting.

LEARNING NOTE — WHY DELETE + CREATE INSTEAD OF PATCH:
    `kubectl patch` on a Secret would work, but the value needs to be
    base64-encoded in the patch JSON, adding complexity and a chance for
    encoding errors. Delete + Create is simpler, idempotent, and the
    operator pod restart picks up the new secret regardless of how it
    was replaced.

    The brief window where the secret doesn't exist is fine — the
    operator is being restarted anyway and won't read the secret until
    its new pod starts.

USAGE:
    # With 1Password CLI (recommended):
    export OP_SERVICE_ACCOUNT_TOKEN="ops_..."
    python3 scripts/ops/rotate-1password-token.py

    # With manual token:
    python3 scripts/ops/rotate-1password-token.py --token "ops_..."

    # Dry run:
    python3 scripts/ops/rotate-1password-token.py --dry-run
"""

import argparse
import os
import subprocess
import sys
import time

# ── Configuration ───────────────────────────────────────────────────
# These MUST match the Helm chart values in:
#   infrastructure/base/onepassword-operator/helm-release.yaml
SECRET_NAME = os.environ.get("OP_SECRET_NAME", "onepassword-service-account-token")
SECRET_NAMESPACE = os.environ.get("OP_SECRET_NAMESPACE", "onepassword-system")
SECRET_KEY = os.environ.get("OP_SECRET_KEY", "token")

# 1Password CLI vault path for automated retrieval
OP_ITEM_PATH = os.environ.get(
    "OP_ITEM_PATH", "op://Homelab/1password-operator-service-account/credential"
)

OPERATOR_RESTART_WAIT_SECONDS = 15


def log(emoji: str, message: str) -> None:
    print(f"{emoji} {message}", flush=True)


def run_cmd(cmd: list[str], check: bool = True, capture: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=capture, text=True, check=check)


def get_token(args: argparse.Namespace) -> str:
    """Resolve the new token from args, env, or 1Password CLI.

    LEARNING NOTE — TOKEN RESOLUTION ORDER:
        1. --token flag (explicit, for manual rotation)
        2. OP_SA_TOKEN env var (for CI/CD or bootstrap scripts)
        3. `op read` from 1Password CLI (requires OP_SERVICE_ACCOUNT_TOKEN)

        This fallback chain means the script works in three contexts:
        - Manual: paste the token directly
        - Automated: set OP_SA_TOKEN in the environment
        - Interactive: have `op` CLI authenticated

        The `op read` approach is best — the token never touches disk or
        shell history. The CLI fetches it from 1Password's API at runtime.
    """
    # Priority 1: Explicit --token flag
    if args.token:
        log("  ℹ️ ", "Using token from --token flag")
        return args.token

    # Priority 2: OP_SA_TOKEN environment variable
    env_token = os.environ.get("OP_SA_TOKEN")
    if env_token:
        log("  ℹ️ ", "Using token from OP_SA_TOKEN environment variable")
        return env_token

    # Priority 3: Fetch from 1Password CLI
    log("  ℹ️ ", f"Fetching token from 1Password CLI: {OP_ITEM_PATH}")
    result = run_cmd(["op", "read", OP_ITEM_PATH], check=False)

    if result.returncode == 0 and result.stdout.strip():
        log("  ✅", "Token retrieved from 1Password")
        return result.stdout.strip()

    log("❌", "Could not resolve token from any source.")
    log("  ", "Provide it via one of:")
    log("  ", "  --token 'ops_...'")
    log("  ", "  export OP_SA_TOKEN='ops_...'")
    log("  ", f"  op read '{OP_ITEM_PATH}' (requires OP_SERVICE_ACCOUNT_TOKEN)")
    sys.exit(1)


def rotate_secret(token: str, dry_run: bool = False) -> None:
    """Delete old secret and create new one with the provided token."""
    log("🔐", f"Rotating secret: {SECRET_NAMESPACE}/{SECRET_NAME}")

    if dry_run:
        log("  🏜️", "DRY RUN — would delete and recreate secret")
        return

    # Ensure namespace exists
    run_cmd(
        ["kubectl", "create", "namespace", SECRET_NAMESPACE],
        check=False,
    )

    # Delete existing secret (ignore if not found)
    delete_result = run_cmd(
        ["kubectl", "delete", "secret", SECRET_NAME, "-n", SECRET_NAMESPACE],
        check=False,
    )
    if delete_result.returncode == 0:
        log("  ✅", "Old secret deleted")
    else:
        log("  ℹ️ ", "No existing secret found (fresh creation)")

    # Create new secret
    run_cmd(
        ["kubectl", "create", "secret", "generic", SECRET_NAME,
         "--namespace", SECRET_NAMESPACE,
         f"--from-literal={SECRET_KEY}={token}"],
    )
    log("  ✅", "New secret created")


def restart_operator(dry_run: bool = False) -> None:
    """Restart the 1Password Operator pods to pick up the new secret."""
    log("🔄", "Restarting 1Password Operator...")

    if dry_run:
        log("  🏜️", "DRY RUN — would restart operator pods")
        return

    # Delete all pods in the namespace — the deployment controller recreates them
    # LEARNING NOTE — WHY DELETE PODS INSTEAD OF ROLLOUT RESTART:
    #   `kubectl rollout restart deployment/onepassword-operator` is cleaner
    #   for deployments, but the 1Password Operator uses a custom controller
    #   that may not respond to rollout restart. Deleting pods is universally
    #   reliable — the ReplicaSet controller always recreates them.
    run_cmd(
        ["kubectl", "delete", "pods", "-n", SECRET_NAMESPACE, "--all"],
        check=False,
    )
    log("  ✅", "Operator pods deleted — waiting for restart...")

    time.sleep(OPERATOR_RESTART_WAIT_SECONDS)

    # Verify operator is running
    result = run_cmd(
        ["kubectl", "get", "pods", "-n", SECRET_NAMESPACE, "--no-headers"],
        check=False,
    )

    if result.returncode == 0 and result.stdout.strip():
        for line in result.stdout.strip().split("\n"):
            parts = line.split()
            name = parts[0] if parts else "unknown"
            status = parts[2] if len(parts) > 2 else "Unknown"
            ready = parts[1] if len(parts) > 1 else "0/0"

            if status == "Running":
                log("  ✅", f"{name}: {status} ({ready})")
            else:
                log("  ⚠️ ", f"{name}: {status} ({ready}) — may still be starting")
    else:
        log("  ⚠️ ", "Could not verify operator status — check manually:")
        log("  ", f"  kubectl get pods -n {SECRET_NAMESPACE}")


def verify_sync(dry_run: bool = False) -> None:
    """Check that OnePasswordItems are syncing after the token rotation."""
    log("🔍", "Verifying 1Password sync...")

    if dry_run:
        log("  🏜️", "DRY RUN — would verify OnePasswordItem sync")
        return

    result = run_cmd(
        ["kubectl", "get", "onepassworditems", "-A", "--no-headers"],
        check=False,
    )

    if result.returncode != 0:
        log("  ⚠️ ", "Cannot query OnePasswordItems — CRD may not be installed yet")
        return

    if not result.stdout.strip():
        log("  ℹ️ ", "No OnePasswordItems found (they'll sync when Flux reconciles)")
        return

    items = result.stdout.strip().split("\n")
    log("  ✅", f"{len(items)} OnePasswordItem(s) found — operator will re-sync shortly")


def main():
    parser = argparse.ArgumentParser(
        description="Rotate the 1Password Operator bootstrap secret",
    )
    parser.add_argument(
        "--token", type=str, default=None,
        help="New Service Account token (if not using env var or 1Password CLI)",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show what would happen without making changes",
    )
    args = parser.parse_args()

    log("🔑", "1Password Token Rotation")
    log("═" * 40, "")

    if args.dry_run:
        log("🏜️", "DRY RUN MODE — no changes will be made\n")

    # Step 1: Resolve the new token
    token = get_token(args)

    # Basic token format validation
    if not token.startswith("ops_"):
        log("⚠️ ", "Token doesn't start with 'ops_' — are you sure this is a Service Account token?")
        log("  ", "Service Account tokens always start with 'ops_'")
        log("  ", "User tokens start with 'eyJ' — these won't work for the operator")
        response = input("Continue anyway? (y/N): ").strip().lower()
        if response != "y":
            log("⏹️ ", "Aborted.")
            sys.exit(0)

    # Step 2: Replace the secret
    rotate_secret(token, args.dry_run)

    # Step 3: Restart operator
    restart_operator(args.dry_run)

    # Step 4: Verify sync
    verify_sync(args.dry_run)

    log("\n✅", "Token rotation complete!")
    log("  ", "If secrets aren't syncing, check operator logs:")
    log("  ", f"  kubectl logs -n {SECRET_NAMESPACE} -l app.kubernetes.io/instance=onepassword-operator")


if __name__ == "__main__":
    main()
