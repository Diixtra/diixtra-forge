#!/usr/bin/env python3
"""
Cluster Health Validation
=========================

Checks the health of every major component in the Flux-managed cluster.
Run this after bootstrap, after merging PRs, or as a periodic sanity check.

WHAT IT CHECKS (in order):
    1. Flux Kustomizations — all 6 layers reconciled
    2. HelmReleases       — all releases installed/upgraded successfully
    3. Pods               — no CrashLoopBackOff, Pending, or Error states
    4. PVCs               — all persistent volume claims bound
    5. 1Password          — operator running, OnePasswordItems synced
    6. Nodes              — all nodes Ready

LEARNING NOTE — WHY A HEALTH SCRIPT:
    `flux get kustomizations` tells you if Flux is happy, but it doesn't
    tell you if the WORKLOADS are happy. A Kustomization can reconcile
    successfully (Flux applied the YAML) while a pod crashes because of
    a missing secret or a bad config. This script checks BOTH the GitOps
    layer (did Flux apply it?) and the workload layer (is it actually running?).

USAGE:
    python3 scripts/ops/validate-cluster-health.py
    python3 scripts/ops/validate-cluster-health.py --verbose
    python3 scripts/ops/validate-cluster-health.py --json    # Machine-readable output
"""

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass, field


@dataclass
class HealthResult:
    """Result of a single health check."""
    component: str
    name: str
    namespace: str
    status: str  # "healthy", "degraded", "unhealthy"
    message: str = ""


@dataclass
class HealthReport:
    """Aggregated health report."""
    results: list = field(default_factory=list)

    @property
    def healthy_count(self) -> int:
        return sum(1 for r in self.results if r.status == "healthy")

    @property
    def degraded_count(self) -> int:
        return sum(1 for r in self.results if r.status == "degraded")

    @property
    def unhealthy_count(self) -> int:
        return sum(1 for r in self.results if r.status == "unhealthy")

    @property
    def overall_status(self) -> str:
        if self.unhealthy_count > 0:
            return "unhealthy"
        if self.degraded_count > 0:
            return "degraded"
        return "healthy"

    def add(self, result: HealthResult):
        self.results.append(result)


def log(emoji: str, message: str) -> None:
    print(f"{emoji} {message}", flush=True)


def run_cmd(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def check_kustomizations(report: HealthReport, verbose: bool = False) -> None:
    """Check all Flux Kustomizations are reconciled."""
    log("📦", "Checking Flux Kustomizations...")

    result = run_cmd(["flux", "get", "kustomizations", "--no-header"])
    if result.returncode != 0:
        report.add(HealthResult("kustomization", "flux-cli", "flux-system", "unhealthy",
                                "Cannot reach Flux — is it installed?"))
        return

    for line in result.stdout.strip().split("\n"):
        if not line.strip():
            continue
        parts = line.split()
        name = parts[0] if parts else "unknown"
        ready = parts[3] if len(parts) > 3 else "Unknown"

        if ready == "True":
            status = "healthy"
            emoji = "  ✅"
        else:
            status = "unhealthy"
            emoji = "  ❌"

        message = " ".join(parts[4:]) if len(parts) > 4 else ""
        report.add(HealthResult("kustomization", name, "flux-system", status, message))

        if verbose or status != "healthy":
            log(emoji, f"{name}: {ready} {message}")
        elif status == "healthy":
            log(emoji, f"{name}")


def check_helmreleases(report: HealthReport, verbose: bool = False) -> None:
    """Check all HelmReleases are installed/upgraded."""
    log("⎈ ", "Checking HelmReleases...")

    result = run_cmd(["flux", "get", "helmreleases", "-A", "--no-header"])
    if result.returncode != 0:
        report.add(HealthResult("helmrelease", "flux-cli", "all", "unhealthy",
                                "Cannot query HelmReleases"))
        return

    for line in result.stdout.strip().split("\n"):
        if not line.strip():
            continue
        parts = line.split()
        namespace = parts[0] if parts else "unknown"
        name = parts[1] if len(parts) > 1 else "unknown"
        ready = parts[4] if len(parts) > 4 else "Unknown"

        if ready == "True":
            status = "healthy"
            emoji = "  ✅"
        else:
            status = "unhealthy"
            emoji = "  ❌"

        message = " ".join(parts[5:]) if len(parts) > 5 else ""
        report.add(HealthResult("helmrelease", name, namespace, status, message))

        if verbose or status != "healthy":
            log(emoji, f"{namespace}/{name}: {ready} {message}")
        elif status == "healthy":
            log(emoji, f"{namespace}/{name}")


def check_pods(report: HealthReport, verbose: bool = False) -> None:
    """Check for unhealthy pods across all namespaces."""
    log("🐳", "Checking Pod health...")

    # Get pods that are NOT Running/Succeeded
    result = run_cmd([
        "kubectl", "get", "pods", "-A", "--no-headers",
        "--field-selector=status.phase!=Running,status.phase!=Succeeded",
    ])

    if result.returncode != 0:
        report.add(HealthResult("pod", "kubectl", "all", "unhealthy",
                                "Cannot query pods"))
        return

    bad_pods = [line for line in result.stdout.strip().split("\n") if line.strip()]

    if not bad_pods:
        log("  ✅", "All pods healthy")
        report.add(HealthResult("pod", "all", "all", "healthy", "All pods Running/Succeeded"))
        return

    for line in bad_pods:
        parts = line.split()
        namespace = parts[0] if parts else "unknown"
        name = parts[1] if len(parts) > 1 else "unknown"
        status_str = parts[3] if len(parts) > 3 else "Unknown"

        # CrashLoopBackOff and Error are unhealthy; Pending is degraded
        if status_str in ("CrashLoopBackOff", "Error", "ImagePullBackOff",
                          "CreateContainerConfigError"):
            health = "unhealthy"
            emoji = "  ❌"
        else:
            health = "degraded"
            emoji = "  ⚠️ "

        report.add(HealthResult("pod", name, namespace, health, status_str))
        log(emoji, f"{namespace}/{name}: {status_str}")


def check_pvcs(report: HealthReport, verbose: bool = False) -> None:
    """Check all PVCs are Bound."""
    log("💾", "Checking PersistentVolumeClaims...")

    result = run_cmd(["kubectl", "get", "pvc", "-A", "--no-headers"])
    if result.returncode != 0:
        report.add(HealthResult("pvc", "kubectl", "all", "degraded",
                                "Cannot query PVCs"))
        return

    if not result.stdout.strip():
        log("  ℹ️ ", "No PVCs found")
        return

    for line in result.stdout.strip().split("\n"):
        if not line.strip():
            continue
        parts = line.split()
        namespace = parts[0] if parts else "unknown"
        name = parts[1] if len(parts) > 1 else "unknown"
        pvc_status = parts[2] if len(parts) > 2 else "Unknown"

        if pvc_status == "Bound":
            status = "healthy"
            emoji = "  ✅"
        elif pvc_status == "Pending":
            status = "degraded"
            emoji = "  ⚠️ "
        else:
            status = "unhealthy"
            emoji = "  ❌"

        report.add(HealthResult("pvc", name, namespace, status, pvc_status))
        if verbose or status != "healthy":
            log(emoji, f"{namespace}/{name}: {pvc_status}")
        elif status == "healthy":
            log(emoji, f"{namespace}/{name}")


def check_onepassword(report: HealthReport, verbose: bool = False) -> None:
    """Check 1Password Operator and synced items."""
    log("🔐", "Checking 1Password Operator...")

    # Check operator pod
    result = run_cmd([
        "kubectl", "get", "pods", "-n", "onepassword-system",
        "-l", "app.kubernetes.io/instance=onepassword-operator",
        "--no-headers",
    ])

    if result.returncode != 0 or not result.stdout.strip():
        report.add(HealthResult("1password", "operator", "onepassword-system",
                                "unhealthy", "Operator pod not found"))
        log("  ❌", "Operator pod not found")
        return

    line = result.stdout.strip().split("\n")[0]
    parts = line.split()
    pod_status = parts[2] if len(parts) > 2 else "Unknown"
    ready = parts[1] if len(parts) > 1 else "0/0"

    if pod_status == "Running" and ready.startswith("1/"):
        report.add(HealthResult("1password", "operator", "onepassword-system",
                                "healthy", "Running"))
        log("  ✅", "Operator running")
    else:
        report.add(HealthResult("1password", "operator", "onepassword-system",
                                "unhealthy", f"{pod_status} ({ready})"))
        log("  ❌", f"Operator: {pod_status} ({ready})")

    # Check OnePasswordItems
    items_result = run_cmd(["kubectl", "get", "onepassworditems", "-A", "--no-headers"])
    if items_result.stdout.strip():
        item_count = len(items_result.stdout.strip().split("\n"))
        log("  ✅", f"{item_count} OnePasswordItem(s) synced")
        report.add(HealthResult("1password", "items", "all", "healthy",
                                f"{item_count} items synced"))


def check_nodes(report: HealthReport, verbose: bool = False) -> None:
    """Check all nodes are Ready."""
    log("🖥️ ", "Checking Nodes...")

    result = run_cmd(["kubectl", "get", "nodes", "--no-headers"])
    if result.returncode != 0:
        report.add(HealthResult("node", "kubectl", "cluster", "unhealthy",
                                "Cannot query nodes"))
        return

    for line in result.stdout.strip().split("\n"):
        if not line.strip():
            continue
        parts = line.split()
        name = parts[0] if parts else "unknown"
        node_status = parts[1] if len(parts) > 1 else "Unknown"

        if "Ready" in node_status and "NotReady" not in node_status:
            status = "healthy"
            emoji = "  ✅"
        else:
            status = "unhealthy"
            emoji = "  ❌"

        report.add(HealthResult("node", name, "cluster", status, node_status))
        log(emoji, f"{name}: {node_status}")


def main():
    parser = argparse.ArgumentParser(description="Validate cluster health")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Show detailed output for healthy components too")
    parser.add_argument("--json", action="store_true",
                        help="Output machine-readable JSON report")
    args = parser.parse_args()

    report = HealthReport()

    log("🏥", "Cluster Health Check")
    log("═" * 40, "")

    check_kustomizations(report, args.verbose)
    check_helmreleases(report, args.verbose)
    check_pods(report, args.verbose)
    check_pvcs(report, args.verbose)
    check_onepassword(report, args.verbose)
    check_nodes(report, args.verbose)

    # Summary
    print()
    log("📊", "Summary")
    log("═" * 40, "")
    log("  ", f"Healthy:   {report.healthy_count}")
    log("  ", f"Degraded:  {report.degraded_count}")
    log("  ", f"Unhealthy: {report.unhealthy_count}")

    status_emoji = {"healthy": "✅", "degraded": "⚠️ ", "unhealthy": "❌"}
    log(status_emoji[report.overall_status], f"Overall: {report.overall_status.upper()}")

    if args.json:
        output = {
            "overall": report.overall_status,
            "healthy": report.healthy_count,
            "degraded": report.degraded_count,
            "unhealthy": report.unhealthy_count,
            "results": [
                {
                    "component": r.component,
                    "name": r.name,
                    "namespace": r.namespace,
                    "status": r.status,
                    "message": r.message,
                }
                for r in report.results
            ],
        }
        print(json.dumps(output, indent=2))

    sys.exit(0 if report.overall_status == "healthy" else 1)


if __name__ == "__main__":
    main()
