#!/usr/bin/env python3
"""
Force Reconcile All Flux Resources
====================================

Triggers an immediate reconciliation of all Flux resources in dependency order.
Useful after merging PRs, recovering from errors, or debugging sync issues.

WHAT IT DOES:
    1. Reconciles the GitRepository source (pulls latest commit)
    2. Reconciles all 6 Kustomizations in dependency order
    3. Optionally reconciles all HelmReleases
    4. Reports final status

LEARNING NOTE — WHY DEPENDENCY ORDER MATTERS:
    Flux Kustomizations form a dependency chain:
      flux-system → infrastructure-crds → infrastructure
                  → platform-crds → platform → apps

    If you reconcile `infrastructure` before `infrastructure-crds`, it will
    fail because the CRDs it depends on haven't been installed yet. By
    reconciling in dependency order, each layer has its prerequisites
    satisfied before it runs.

    `flux reconcile` doesn't wait for dependencies automatically — it just
    triggers the reconciliation loop for that specific resource. We add
    a short wait between layers to give each one time to apply before
    triggering the next.

LEARNING NOTE — RECONCILE vs RESTART:
    `flux reconcile` tells the controller to check Git NOW instead of
    waiting for the next poll interval. It doesn't restart pods, delete
    resources, or force-apply anything. It's the equivalent of pressing
    "refresh" — the controller pulls the latest Git state and compares
    it to the cluster state.

    If a Kustomization was in a failed state, reconciling it makes the
    controller retry the apply. If the underlying issue (missing CRD,
    bad YAML, missing secret) is now fixed, the retry will succeed.

USAGE:
    python3 scripts/ops/force-reconcile-all.py
    python3 scripts/ops/force-reconcile-all.py --include-helm
    python3 scripts/ops/force-reconcile-all.py --dry-run
"""

import argparse
import subprocess
import sys
import time


# Kustomizations in dependency order — matches the Flux dependency chain
KUSTOMIZATION_ORDER = [
    "flux-system",
    "infrastructure-crds",
    "infrastructure",
    "platform-crds",
    "platform",
    "apps",
]

# Pause between layers to let each one apply before triggering the next
INTER_LAYER_PAUSE_SECONDS = 5


def log(emoji: str, message: str) -> None:
    print(f"{emoji} {message}", flush=True)


def run_cmd(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def reconcile_source(dry_run: bool = False) -> bool:
    """Reconcile the GitRepository source to pull the latest commit."""
    log("📡", "Reconciling GitRepository source...")

    if dry_run:
        log("  🏜️", "DRY RUN — would reconcile source git flux-system")
        return True

    result = run_cmd(
        ["flux", "reconcile", "source", "git", "flux-system", "-n", "flux-system"],
        check=False,
    )

    if result.returncode == 0:
        log("  ✅", "GitRepository reconciled — latest commit pulled")
        return True

    log("  ❌", f"GitRepository reconcile failed: {result.stderr.strip()}")
    return False


def reconcile_kustomizations(dry_run: bool = False) -> dict[str, bool]:
    """Reconcile all Kustomizations in dependency order."""
    log("📦", "Reconciling Kustomizations in dependency order...")

    results = {}

    for i, ks_name in enumerate(KUSTOMIZATION_ORDER):
        if dry_run:
            log(f"  🏜️", f"DRY RUN — would reconcile kustomization {ks_name}")
            results[ks_name] = True
            continue

        result = run_cmd(
            ["flux", "reconcile", "kustomization", ks_name, "-n", "flux-system"],
            check=False,
        )

        if result.returncode == 0:
            log("  ✅", f"{ks_name}: reconciled")
            results[ks_name] = True
        else:
            stderr = result.stderr.strip()
            log("  ❌", f"{ks_name}: {stderr}")
            results[ks_name] = False

        # Pause between layers (not after the last one)
        if i < len(KUSTOMIZATION_ORDER) - 1 and not dry_run:
            log("  ⏳", f"Waiting {INTER_LAYER_PAUSE_SECONDS}s for {ks_name} to apply...")
            time.sleep(INTER_LAYER_PAUSE_SECONDS)

    return results


def reconcile_helmreleases(dry_run: bool = False) -> dict[str, bool]:
    """Reconcile all HelmReleases across all namespaces."""
    log("⎈ ", "Reconciling HelmReleases...")

    if dry_run:
        log("  🏜️", "DRY RUN — would reconcile all HelmReleases")
        return {}

    # Get list of all HelmReleases
    result = run_cmd(
        ["flux", "get", "helmreleases", "-A", "--no-header"],
        check=False,
    )

    if result.returncode != 0 or not result.stdout.strip():
        log("  ℹ️ ", "No HelmReleases found")
        return {}

    results = {}
    for line in result.stdout.strip().split("\n"):
        if not line.strip():
            continue
        parts = line.split()
        namespace = parts[0] if parts else "unknown"
        name = parts[1] if len(parts) > 1 else "unknown"

        hr_result = run_cmd(
            ["flux", "reconcile", "helmrelease", name, "-n", namespace],
            check=False,
        )

        key = f"{namespace}/{name}"
        if hr_result.returncode == 0:
            log("  ✅", f"{key}: reconciled")
            results[key] = True
        else:
            stderr = hr_result.stderr.strip()
            log("  ❌", f"{key}: {stderr}")
            results[key] = False

    return results


def show_final_status() -> None:
    """Display final Kustomization status after reconciliation."""
    log("\n📊", "Final status:")
    result = run_cmd(["flux", "get", "kustomizations"], check=False)
    if result.returncode == 0:
        # Print the flux output directly — it has nice formatting
        for line in result.stdout.strip().split("\n"):
            print(f"  {line}")


def main():
    parser = argparse.ArgumentParser(
        description="Force reconcile all Flux resources in dependency order",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show what would be reconciled without making changes",
    )
    parser.add_argument(
        "--include-helm", action="store_true",
        help="Also reconcile all HelmReleases (slower, usually not needed)",
    )
    args = parser.parse_args()

    log("🔄", "Force Reconcile All")
    log("═" * 40, "")

    if args.dry_run:
        log("🏜️", "DRY RUN MODE — no changes will be made\n")

    # Step 1: Pull latest from Git
    source_ok = reconcile_source(args.dry_run)
    if not source_ok and not args.dry_run:
        log("💀", "Cannot reconcile Git source — aborting.")
        log("  ", "Check: flux get sources git -A")
        sys.exit(1)

    print()

    # Step 2: Reconcile Kustomizations in order
    ks_results = reconcile_kustomizations(args.dry_run)

    # Step 3: Optionally reconcile HelmReleases
    if args.include_helm:
        print()
        reconcile_helmreleases(args.dry_run)

    # Step 4: Show final status
    if not args.dry_run:
        show_final_status()

    # Exit code
    failed = [name for name, ok in ks_results.items() if not ok]
    if failed:
        log("⚠️ ", f"{len(failed)} Kustomization(s) failed: {', '.join(failed)}")
        sys.exit(1)
    else:
        log("✅", "All reconciliations triggered successfully")


if __name__ == "__main__":
    main()
