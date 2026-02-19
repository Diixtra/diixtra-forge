#!/usr/bin/env python3
"""
Flux CD Bootstrap Script for diixtra-forge
==================================================

PURPOSE:
    Automates the complete bootstrapping of Flux CD on a Kubernetes cluster,
    from pre-flight validation through to verified reconciliation of all layers.

WHAT THIS SCRIPT DOES (in order):
    1. Pre-flight checks    — Verifies CLI tools, env vars, cluster connectivity,
                              node-level dependencies (open-iscsi), scaffold structure,
                              and UniFi network validation (advisory, see KAZ-61)
    2. GitHub repo setup    — Creates the private repo via `gh` CLI (idempotent)
    3. Git push             — Initializes local scaffold and pushes to GitHub
    4. Bootstrap secret     — Creates the 1Password SA token secret on the cluster
    5. Flux bootstrap       — Installs Flux controllers and configures GitOps sync
    6. RBAC recovery        — Applies gotk-components.yaml if controllers can't auth
    7. Verification         — Polls all 6 Flux Kustomizations until fully reconciled

LEARNING NOTES — WHY PYTHON AND NOT BASH:
    Bash is fine for linear "do A then B then C" scripts. But this bootstrap has:
      - Branching logic (different behavior if repo exists vs. doesn't)
      - Structured error handling (if step 3 fails, we need cleanup)
      - Complex string formatting (YAML generation, JSON parsing)
      - Retry logic with exponential backoff (waiting for reconciliation)
    Python handles all of these cleanly. The subprocess module gives us the same
    shell access as bash, but with proper return code handling and output capture.

LEARNING NOTES — WHY `subprocess.run` OVER `os.system`:
    os.system() runs a command and returns the exit code. That's it.
    subprocess.run() gives you:
      - stdout/stderr capture (check=True raises on non-zero exit)
      - Input piping (for passing tokens without shell history)
      - Timeout control (prevent hung processes)
      - Shell injection safety (when shell=False, args aren't interpreted)
    Rule of thumb: always use subprocess.run() in Python scripts.

USAGE:
    # Set the required environment variables (or use 1Password CLI to inject them):
    export GITHUB_TOKEN="ghp_..."          # GitHub PAT with repo admin permissions
    export OP_SA_TOKEN="ops_..."           # 1Password Service Account token

    # Run the bootstrap:
    python3 scripts/bootstrap.py

    # Or inject secrets via 1Password CLI:
    export OP_SERVICE_ACCOUNT_TOKEN="ops_..."
    op run --env-file=.env -- python3 scripts/bootstrap.py

    # Dry run (validates everything without making changes):
    python3 scripts/bootstrap.py --dry-run

    # Skip UniFi network checks (for offline/CI environments):
    python3 scripts/bootstrap.py --skip-network-checks
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from network_checks import run_network_checks


# =============================================================================
# CONFIGURATION — ALL VARIABLES DEFINED HERE, NO HARDCODED VALUES BELOW
# =============================================================================
#
# LEARNING NOTE — DATACLASS AS CONFIG:
#   Using a dataclass instead of loose variables gives us:
#     1. Type hints (your IDE can catch mistakes)
#     2. Single import point (other scripts can `from bootstrap import Config`)
#     3. Immutable-ish (frozen=True would prevent accidental mutation)
#     4. Clean __repr__ for logging (print(config) shows all values)
#   This pattern scales — when you have 50 config values, dataclass keeps
#   them organized. Environment variables override defaults at instantiation.
# =============================================================================

@dataclass
class Config:
    """All bootstrap configuration. No hardcoded values below this class."""

    # ── GitHub ──────────────────────────────────────────────────────────
    github_owner: str = "Diixtra"
    github_repo: str = "diixtra-forge"
    github_branch: str = "main"
    github_visibility: str = "private"

    # ── Flux ────────────────────────────────────────────────────────────
    # The cluster path tells Flux "watch this directory for your config."
    # Each cluster gets its own path inside the repo. When Flux bootstraps,
    # it creates a GitRepository + Kustomization in `flux-system/` that
    # points back at this path — creating a self-referencing loop.
    cluster_name: str = "homelab"
    cluster_path: str = "clusters/homelab"

    # Extra Flux components beyond the default four controllers.
    # Image reflector/automation enable automatic container image updates.
    flux_extra_components: str = "image-reflector-controller,image-automation-controller"

    # ── 1Password Bootstrap Secret ──────────────────────────────────────
    # LEARNING NOTE — THE BOOTSTRAP SECRET CHICKEN-AND-EGG:
    #   Every secret management system has exactly one secret it can't
    #   manage itself — its own credential. For us, that's the 1Password
    #   Service Account token. This token must exist as a Kubernetes Secret
    #   BEFORE Flux deploys the 1Password Operator HelmRelease, because
    #   the operator pod mounts it directly as a volume.
    #
    #   The secret name MUST match the Helm chart's default:
    #   `onepassword-service-account-token` with key `token`.
    #   This is set in the HelmRelease values at:
    #   operator.serviceAccountToken.name
    #
    #   This is universal: HashiCorp Vault needs an unseal key, AWS Secrets
    #   Manager needs IAM credentials, External Secrets Operator needs a
    #   provider token. There's always exactly one manual secret per cluster.
    op_secret_name: str = "onepassword-service-account-token"
    op_secret_namespace: str = "onepassword-system"
    op_secret_key: str = "token"

    # ── Kubernetes Context ──────────────────────────────────────────────
    # Which kubeconfig context to use. Empty string = current context.
    kube_context: str = ""

    # ── Retry Configuration ─────────────────────────────────────────────
    reconciliation_timeout_seconds: int = 600  # 10 minutes — HelmReleases take time
    reconciliation_poll_interval: int = 15     # Check every 15 seconds

    # ── RBAC Recovery ───────────────────────────────────────────────────
    # LEARNING NOTE — THE RBAC BOOTSTRAP CATCH-22:
    #   When Flux bootstrap installs controllers, it sometimes fails to
    #   create the RBAC resources (ServiceAccounts, ClusterRoleBindings)
    #   before the pods start. The pods crash with "the server has asked
    #   for the client to provide credentials" because they have no
    #   ServiceAccount. The fix is to manually apply gotk-components.yaml,
    #   which contains ALL Flux resources including RBAC. Once applied,
    #   the controllers restart and self-manage from there.
    rbac_recovery_enabled: bool = True

    # ── Local Paths ─────────────────────────────────────────────────────
    repo_root: str = ""

    # ── Dry Run ─────────────────────────────────────────────────────────
    dry_run: bool = False

    # ── Network Checks ──────────────────────────────────────────────────
    # When True, skip UniFi API pre-flight network validation.
    # Useful in offline/CI environments without UniFi controller access.
    skip_network_checks: bool = False

    # ── Expected Kustomizations ─────────────────────────────────────────
    # All 6 layers that must reconcile for a healthy cluster.
    # Order matches the dependency chain.
    expected_kustomizations: list = field(default_factory=lambda: [
        "flux-system",
        "infrastructure-crds",
        "infrastructure",
        "platform-crds",
        "platform",
        "apps",
    ])

    def __post_init__(self):
        """Resolve paths and override from environment variables."""
        if not self.repo_root:
            self.repo_root = str(Path(__file__).parent.parent.resolve())

        # Environment variable overrides — follows 12-Factor App principles.
        self.github_owner = os.environ.get("GITHUB_OWNER", self.github_owner)
        self.github_repo = os.environ.get("GITHUB_REPO", self.github_repo)
        self.github_branch = os.environ.get("GITHUB_BRANCH", self.github_branch)
        self.cluster_name = os.environ.get("CLUSTER_NAME", self.cluster_name)
        self.cluster_path = os.environ.get(
            "CLUSTER_PATH", f"clusters/{self.cluster_name}"
        )
        self.kube_context = os.environ.get("KUBE_CONTEXT", self.kube_context)


# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

def log(emoji: str, message: str) -> None:
    """Structured logging with emoji prefixes for visual clarity."""
    print(f"{emoji} {message}", flush=True)


def run_cmd(
    cmd: list[str],
    capture: bool = False,
    env_extra: Optional[dict] = None,
    check: bool = True,
    input_text: Optional[str] = None,
    cwd: Optional[str] = None,
    timeout: Optional[int] = None,
) -> subprocess.CompletedProcess:
    """
    Execute a shell command with proper error handling.

    LEARNING NOTE — WHY check=True IS IMPORTANT:
        By default, subprocess.run() doesn't raise on non-zero exit codes.
        This means a failed `kubectl` command would silently continue.
        check=True makes it raise subprocess.CalledProcessError instead,
        which is the behavior you almost always want in automation scripts.
        The few cases where you DON'T want it (checking if something exists)
        should explicitly pass check=False.

    LEARNING NOTE — WHY cwd INSTEAD OF os.chdir():
        os.chdir() changes the process-wide working directory, which is
        global state. If anything fails between chdir() and changing back,
        every subsequent command runs in the wrong directory. The cwd
        parameter is scoped to a single subprocess.run() call — it changes
        the working directory only for that child process, leaving the
        parent process unaffected. Always prefer cwd over os.chdir().
    """
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)

    kwargs = {
        "env": env,
        "check": check,
        "text": True,
    }

    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE
    if input_text is not None:
        kwargs["input"] = input_text
    if cwd is not None:
        kwargs["cwd"] = cwd
    if timeout is not None:
        kwargs["timeout"] = timeout

    return subprocess.run(cmd, **kwargs)


def cmd_exists(name: str) -> bool:
    """Check if a command-line tool is available on PATH."""
    return shutil.which(name) is not None


def kube_cmd(config: Config, *args: str) -> list[str]:
    """Build a kubectl command with optional context flag."""
    cmd = ["kubectl"] + list(args)
    if config.kube_context:
        cmd.extend(["--context", config.kube_context])
    return cmd


def flux_cmd(config: Config, *args: str) -> list[str]:
    """Build a flux command with optional context flag."""
    cmd = ["flux"] + list(args)
    if config.kube_context:
        cmd.extend(["--context", config.kube_context])
    return cmd


# =============================================================================
# STEP 1: PRE-FLIGHT CHECKS
# =============================================================================
#
# LEARNING NOTE — WHY PRE-FLIGHT CHECKS MATTER:
#   In infrastructure automation, failing EARLY with a clear error message
#   is infinitely better than failing MIDWAY through a state change.
#   If the script gets halfway through Flux bootstrap and then discovers
#   kubectl isn't installed, you're left in a partially-configured state
#   that's painful to debug and recover from.
#
#   Production-grade tools (Terraform, Flux, Helm) all do this — they
#   validate everything they can before making any changes. It's called
#   "fail fast" and it's a principle worth internalizing.
# =============================================================================

def preflight_checks(config: Config) -> None:
    """Verify all prerequisites before making any changes."""
    log("🔍", "Running pre-flight checks...")
    errors: list[str] = []

    # ── Required CLI tools ──────────────────────────────────────────
    required_tools = {
        "flux": "Flux CLI — install: curl -s https://fluxcd.io/install.sh | sudo bash",
        "kubectl": "Kubernetes CLI — install: https://kubernetes.io/docs/tasks/tools/",
        "gh": "GitHub CLI — install: https://cli.github.com/",
        "git": "Git — install: sudo apt install git",
        "op": "1Password CLI — install: https://developer.1password.com/docs/cli/get-started/",
    }

    for tool, install_hint in required_tools.items():
        if cmd_exists(tool):
            try:
                result = run_cmd([tool, "version" if tool != "op" else "--version"],
                                 capture=True, check=False)
                version = result.stdout.strip().split("\n")[0]
                log("  ✅", f"{tool}: {version}")
            except Exception:
                log("  ✅", f"{tool}: found")
        else:
            log("  ❌", f"{tool}: NOT FOUND — {install_hint}")
            errors.append(f"Missing tool: {tool}")

    # ── Environment variables ───────────────────────────────────────
    # LEARNING NOTE — GITHUB_TOKEN vs GH_TOKEN:
    #   The Flux CLI reads GITHUB_TOKEN. The GitHub CLI (gh) reads GH_TOKEN
    #   or GITHUB_TOKEN. We check for GITHUB_TOKEN since both tools use it.
    github_token = os.environ.get("GITHUB_TOKEN")
    if not github_token:
        log("❌", "GITHUB_TOKEN environment variable is not set.")
        log("  ", "Generate a fine-grained PAT at: https://github.com/settings/tokens")
        log("  ", "Required permissions: Contents R/W, Metadata R, Administration R/W")
        errors.append("GITHUB_TOKEN not set")
    else:
        log("  ✅", "GITHUB_TOKEN is set")

    op_sa_token = os.environ.get("OP_SA_TOKEN")
    if not op_sa_token:
        log("⚠️ ", "OP_SA_TOKEN not set — bootstrap secret step will be skipped.")
        log("  ", "You'll need to create it manually:")
        log("  ", f"  kubectl create secret generic {config.op_secret_name} \\")
        log("  ", f"    --namespace={config.op_secret_namespace} \\")
        log("  ", f"    --from-literal={config.op_secret_key}=<your-token>")
    else:
        log("  ✅", "OP_SA_TOKEN is set")

    # ── Kubernetes cluster connectivity ─────────────────────────────
    try:
        run_cmd(kube_cmd(config, "cluster-info"), capture=True)
        log("  ✅", "Kubernetes cluster is reachable")
    except subprocess.CalledProcessError:
        log("❌", "Cannot connect to Kubernetes cluster.")
        errors.append("Cluster unreachable")

    # ── Node-level dependency checks ────────────────────────────────
    # LEARNING NOTE — WHY CHECK NODES FROM THE CONTROL PLANE:
    #   open-iscsi must be installed on every worker node that will run
    #   iSCSI-backed pods (democratic-csi). We can't install packages via
    #   kubectl, but we CAN detect their absence by checking if the iscsid
    #   socket exists on each node. If missing, the bootstrap warns early
    #   instead of letting PVCs hang forever with no clear error.
    #
    #   This check uses `kubectl get nodes` to enumerate nodes, then for
    #   each node creates a debug pod to check for /etc/iscsi. In a Packer
    #   golden image world (KAZ-70), this check becomes a post-build
    #   validation — but until then, it catches missing packages early.
    try:
        result = run_cmd(
            kube_cmd(config, "get", "nodes", "-o", "jsonpath={.items[*].metadata.name}"),
            capture=True,
        )
        nodes = result.stdout.strip().split()
        log("  ✅", f"Found {len(nodes)} nodes: {', '.join(nodes)}")

        # Check for open-iscsi on worker nodes (skip control plane)
        for node in nodes:
            role_result = run_cmd(
                kube_cmd(config, "get", "node", node, "-o",
                         "jsonpath={.metadata.labels.node-role\\.kubernetes\\.io/control-plane}"),
                capture=True, check=False,
            )
            if role_result.stdout.strip():
                continue  # Skip control plane nodes

            # Check if iscsid is available on the node
            iscsi_check = run_cmd(
                kube_cmd(config, "debug", f"node/{node}", "--quiet", "--image=busybox",
                         "--", "ls", "/host/etc/iscsi"),
                capture=True, check=False, timeout=30,
            )
            if iscsi_check.returncode != 0:
                log("  ⚠️ ", f"Node {node}: open-iscsi may not be installed (iSCSI PVCs will fail)")
                log("  ", f"  Fix: ssh {node} && sudo apt install -y open-iscsi")
            else:
                log("  ✅", f"Node {node}: open-iscsi detected")
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        log("  ⚠️ ", "Could not validate node dependencies — check manually")

    # ── Flux pre-check ──────────────────────────────────────────────
    try:
        run_cmd(flux_cmd(config, "check", "--pre"), capture=True)
        log("  ✅", "Flux pre-check passed")
    except subprocess.CalledProcessError as e:
        log("⚠️ ", "Flux pre-check reported warnings (may be okay if already installed):")
        log("  ", e.stderr.strip() if e.stderr else "No details")

    # ── Scaffold validation ─────────────────────────────────────────
    required_dirs = [
        config.cluster_path,
        "infrastructure/base",
        f"infrastructure/{config.cluster_name}",
    ]
    required_files = [
        f"{config.cluster_path}/infrastructure.yaml",
        f"{config.cluster_path}/platform.yaml",
        f"{config.cluster_path}/apps.yaml",
        f"{config.cluster_path}/vars.yaml",
    ]

    root = Path(config.repo_root)
    missing_dirs = [d for d in required_dirs if not (root / d).is_dir()]
    missing_files = [f for f in required_files if not (root / f).is_file()]

    if missing_dirs or missing_files:
        log("❌", "Scaffold validation failed:")
        for d in missing_dirs:
            log("  ", f"  Missing directory: {d}")
        for f in missing_files:
            log("  ", f"  Missing file: {f}")
        errors.append("Scaffold incomplete")
    else:
        log("  ✅", f"Scaffold validated — {len(required_dirs)} dirs, {len(required_files)} files")

    # ── UniFi network validation (advisory) ─────────────────────────
    # LEARNING NOTE — ADVISORY CHECKS:
    #   Network checks query the UniFi controller to validate DHCP,
    #   MetalLB range, DNS, and inter-VLAN routing. These are warnings
    #   only — they don't block bootstrap. Use --skip-network-checks
    #   for offline/CI environments.
    if config.skip_network_checks:
        log("⏭️ ", "Network checks skipped (--skip-network-checks)")
    else:
        network_warnings = run_network_checks(
            kube_context=config.kube_context,
            repo_root=config.repo_root,
        )
        if network_warnings:
            log("⚠️ ", f"Network validation: {len(network_warnings)} advisory warning(s)")
            log("  ", "These are informational — bootstrap will continue.")

    # ── Config summary ──────────────────────────────────────────────
    log("📋", "Bootstrap configuration:")
    log("  ", f"GitHub:     {config.github_owner}/{config.github_repo}")
    log("  ", f"Branch:     {config.github_branch}")
    log("  ", f"Cluster:    {config.cluster_name}")
    log("  ", f"Flux path:  {config.cluster_path}")
    log("  ", f"Repo root:  {config.repo_root}")
    log("  ", f"Dry run:    {config.dry_run}")

    # ── Fail if any hard errors ─────────────────────────────────────
    if errors:
        log("💀", f"Pre-flight failed with {len(errors)} error(s):")
        for err in errors:
            log("  ", f"  • {err}")
        sys.exit(1)

    log("✅", "Pre-flight checks passed.\n")


# =============================================================================
# STEP 2: CREATE GITHUB REPOSITORY
# =============================================================================

def create_github_repo(config: Config) -> None:
    """Create the GitHub repository if it doesn't exist."""
    log("📦", f"Creating GitHub repository: {config.github_owner}/{config.github_repo}")

    if config.dry_run:
        log("  🏜️", "DRY RUN — would create repository")
        return

    check_result = run_cmd(
        ["gh", "repo", "view", f"{config.github_owner}/{config.github_repo}"],
        capture=True, check=False,
    )

    if check_result.returncode == 0:
        log("  ℹ️ ", "Repository already exists — skipping creation.")
        return

    create_cmd = [
        "gh", "repo", "create",
        f"{config.github_owner}/{config.github_repo}",
        f"--{config.github_visibility}",
        "--description", "Infrastructure monorepo — Flux CD, Terraform, IDP stack",
    ]

    create_result = run_cmd(create_cmd, capture=True, check=False)
    if create_result.returncode == 0:
        log("  ✅", "Repository created successfully.")
    elif "already exists" in (create_result.stderr or "").lower():
        log("  ℹ️ ", "Repository already exists — continuing.")
    else:
        log("💀", f"Failed to create repository")
        if create_result.stderr:
            log("  ", create_result.stderr.strip())
        sys.exit(1)


# =============================================================================
# STEP 3: GIT INIT, COMMIT, AND PUSH
# =============================================================================

def git_init_and_push(config: Config) -> None:
    """Initialize git in the scaffold directory and push to GitHub."""
    log("📤", "Initializing git and pushing scaffold to GitHub...")

    if config.dry_run:
        log("  🏜️", "DRY RUN — would init, commit, and push")
        return

    repo_root = config.repo_root
    git_dir = Path(repo_root) / ".git"

    def git(*args: str) -> subprocess.CompletedProcess:
        return run_cmd(["git"] + list(args), capture=True, check=True, cwd=repo_root)

    if not git_dir.exists():
        git("init", "-b", config.github_branch)
        log("  ✅", "Git initialized")
    else:
        log("  ℹ️ ", "Git already initialized — skipping init.")

    git("config", "user.email", "flux@kazie.co.uk")
    git("config", "user.name", "Flux Bootstrap")

    github_token = os.environ.get("GITHUB_TOKEN", "")
    cred_helper = (
        f"!f() {{ echo username=x-access-token; echo password={github_token}; }}; f"
    )

    def git_auth(*args: str) -> subprocess.CompletedProcess:
        """Run a git command with token authentication. Captures output to
        prevent tokens leaking into terminal history or logs."""
        cmd = ["git", "-c", f"credential.helper={cred_helper}"] + list(args)
        result = run_cmd(cmd, capture=True, check=False, cwd=repo_root)
        if result.returncode != 0:
            safe_cmd = f"git {' '.join(args)}"
            safe_stderr = (result.stderr or "").replace(github_token, "***")
            raise subprocess.CalledProcessError(
                result.returncode, safe_cmd,
                output=result.stdout, stderr=safe_stderr,
            )
        return result

    # Set remote
    remote_url = f"https://github.com/{config.github_owner}/{config.github_repo}.git"
    try:
        git("remote", "get-url", "origin")
        git("remote", "set-url", "origin", remote_url)
        log("  ℹ️ ", f"Updated remote origin to {remote_url}")
    except subprocess.CalledProcessError:
        git("remote", "add", "origin", remote_url)
        log("  ✅", f"Added remote origin: {remote_url}")

    # Stage and commit
    git("add", ".")
    status = git("status", "--porcelain")
    if status.stdout.strip():
        git("commit", "-m", "feat: initial scaffold for diixtra-forge\n\n"
            "- Infrastructure layer: Caddy, 1Password Operator, MetalLB, democratic-csi\n"
            "- Platform layer: Kyverno policies, Grafana Alloy\n"
            "- CI/CD: Flux validation, Terraform Cloudflare workflows\n"
            "- Scripts: bootstrap, ops runbooks")
        log("  ✅", "Commit created")
    else:
        log("  ℹ️ ", "No changes to commit")

    # Push with rebase fallback
    try:
        git_auth("push", "-u", "origin", config.github_branch)
        log("  ✅", "Pushed to GitHub")
    except subprocess.CalledProcessError as e:
        stderr = str(e.stderr or "")
        if "rejected" in stderr or "fetch first" in stderr:
            log("  ℹ️ ", "Remote has new commits — rebasing...")
            stash_result = git("stash", "--include-untracked")
            has_stash = "No local changes" not in (stash_result.stdout or "")
            git_auth("pull", "--rebase", "origin", config.github_branch)
            if has_stash:
                git("stash", "pop")
                git("add", ".")
                status = git("status", "--porcelain")
                if status.stdout.strip():
                    git("commit", "-m", "feat: add scaffold files after rebase")
            git_auth("push", "-u", "origin", config.github_branch)
            log("  ✅", "Rebased and pushed to GitHub")
        else:
            raise


# =============================================================================
# STEP 4: CREATE 1PASSWORD BOOTSTRAP SECRET
# =============================================================================

def create_bootstrap_secret(config: Config) -> None:
    """Create the 1Password Service Account token as a Kubernetes Secret.

    LEARNING NOTE — ONE SECRET, NO INDIRECTION:
        The 1Password Helm chart mounts a Secret directly into the operator
        pod. The chart defaults to looking for a Secret named
        `onepassword-service-account-token` with key `token`.

        Previous versions of this script created a differently-named secret
        (`op-service-account-token`) and used HelmRelease `valuesFrom` to
        pipe the value through — creating TWO secrets with the same content.
        This broke on every re-bootstrap because the intermediate secret
        didn't exist yet when the chart tried to mount the final one.

        The fix (KAZ-71): create the secret with the EXACT name the chart
        expects. No valuesFrom, no indirection, no duplicate secrets.
    """
    op_token = os.environ.get("OP_SA_TOKEN")
    if not op_token:
        log("⏭️ ", "Skipping bootstrap secret — OP_SA_TOKEN not set.")
        log("  ", "Create it manually before Flux deploys 1Password Operator:")
        log("  ", f"  kubectl create namespace {config.op_secret_namespace}")
        log("  ", f"  kubectl create secret generic {config.op_secret_name} \\")
        log("  ", f"    --namespace={config.op_secret_namespace} \\")
        log("  ", f"    --from-literal={config.op_secret_key}=<your-token>")
        return

    log("🔐", "Creating 1Password bootstrap secret on cluster...")

    if config.dry_run:
        log("  🏜️", f"DRY RUN — would create {config.op_secret_namespace}/{config.op_secret_name}")
        return

    # Ensure namespace exists (idempotent)
    run_cmd(
        kube_cmd(config, "create", "namespace", config.op_secret_namespace),
        capture=True, check=False,
    )

    # Check if secret already exists
    check = run_cmd(
        kube_cmd(config, "get", "secret", config.op_secret_name,
                 "-n", config.op_secret_namespace),
        capture=True, check=False,
    )

    if check.returncode == 0:
        log("  ℹ️ ", "Bootstrap secret already exists — skipping.")
        log("  ", "To recreate: python3 scripts/ops/rotate-1password-token.py")
        return

    # Create the secret
    run_cmd(kube_cmd(
        config, "create", "secret", "generic", config.op_secret_name,
        "--namespace", config.op_secret_namespace,
        f"--from-literal={config.op_secret_key}={op_token}",
    ))
    log("  ✅", f"Bootstrap secret created: {config.op_secret_namespace}/{config.op_secret_name}")


# =============================================================================
# STEP 5: FLUX BOOTSTRAP
# =============================================================================
#
# LEARNING NOTE — WHAT `flux bootstrap github` ACTUALLY DOES:
#   This command does SIX distinct things in sequence:
#
#   1. CONNECTS to GitHub and clones/creates the repository
#   2. GENERATES component manifests — YAML for all Flux controllers
#   3. COMMITS these manifests to `clusters/<name>/flux-system/`
#   4. PUSHES the commit to GitHub
#   5. INSTALLS the controllers on your cluster (kubectl apply)
#   6. CREATES a GitRepository + Kustomization that points back at itself
#
#   Step 6 is the clever part — the "self-referencing loop." After bootstrap,
#   Flux watches the Git repo for changes to its own configuration.
#
#   CRITICAL — KUSTOMIZATION.YAML IN CLUSTER PATH:
#   The flux-system Kustomization watches `clusters/homelab/` with
#   `prune: true`. Without an explicit `kustomization.yaml` in that
#   directory, Kustomize only discovers top-level .yaml files —
#   subdirectories like `flux-system/` are invisible. Flux treats its
#   own controllers as orphaned resources and PRUNES ITSELF.
#   KAZ-67 fixed this by adding `clusters/homelab/kustomization.yaml`
#   that explicitly lists `flux-system` as a resource.
#
#   FLAGS EXPLAINED:
#   --token-auth:     Use HTTPS + PAT (not SSH keys). Simpler for orgs.
#   --personal=false: Repository belongs to an org, not a personal account.
#   --components-extra: Install image reflector + automation controllers
#                       beyond the default four. These enable automatic
#                       container image updates via Git commits.
# =============================================================================

def flux_bootstrap(config: Config) -> None:
    """Run flux bootstrap github to install Flux and configure GitOps sync."""
    log("🚀", "Bootstrapping Flux CD on cluster...")

    if config.dry_run:
        log("  🏜️", "DRY RUN — would run flux bootstrap github")
        return

    github_token = os.environ.get("GITHUB_TOKEN", "")

    bootstrap_cmd = flux_cmd(
        config,
        "bootstrap", "github",
        "--token-auth",
        f"--owner={config.github_owner}",
        f"--repository={config.github_repo}",
        f"--branch={config.github_branch}",
        f"--path={config.cluster_path}",
        "--personal=false",
        "--reconcile",
        f"--components-extra={config.flux_extra_components}",
    )

    result = run_cmd(bootstrap_cmd, env_extra={"GITHUB_TOKEN": github_token}, check=False)

    if result.returncode == 0:
        log("  ✅", "Flux bootstrap completed.")
    else:
        # Bootstrap can timeout but still succeed — controllers may just be slow.
        # The RBAC recovery and verification steps handle this gracefully.
        log("  ⚠️ ", "Flux bootstrap exited with non-zero code (may still succeed).")
        log("  ", "Continuing to RBAC recovery and verification...")


# =============================================================================
# STEP 6: RBAC RECOVERY
# =============================================================================

def rbac_recovery(config: Config) -> None:
    """Apply gotk-components.yaml to fix missing RBAC resources.

    LEARNING NOTE — WHY THIS IS NEEDED:
        The Flux bootstrap sometimes fails to create ServiceAccounts and
        ClusterRoleBindings before starting controller pods. The pods crash
        with auth errors because they have no identity.

        The gotk-components.yaml file (created by bootstrap in the flux-system
        directory) contains ALL Flux resources — CRDs, namespaces, RBAC, and
        deployments. Applying it is idempotent and ensures everything exists.

        This is NOT a workaround — it's a bootstrap prerequisite. The
        controllers need RBAC to authenticate with the API server. Once RBAC
        is in place, the controllers self-manage via GitOps and this manual
        step is never needed again (until the next full re-bootstrap).
    """
    if not config.rbac_recovery_enabled:
        log("⏭️ ", "RBAC recovery disabled — skipping.")
        return

    log("🔧", "Applying RBAC recovery (gotk-components.yaml)...")

    if config.dry_run:
        log("  🏜️", "DRY RUN — would apply gotk-components.yaml")
        return

    gotk_path = Path(config.repo_root) / config.cluster_path / "flux-system" / "gotk-components.yaml"

    if not gotk_path.exists():
        # Pull latest — bootstrap may have committed it
        run_cmd(["git", "pull"], capture=True, check=False, cwd=config.repo_root)

    if not gotk_path.exists():
        log("  ⚠️ ", f"gotk-components.yaml not found at {gotk_path}")
        log("  ", "This means bootstrap didn't create the flux-system directory.")
        log("  ", "Run bootstrap again or check git log for the flux-system commit.")
        return

    run_cmd(kube_cmd(config, "apply", "-f", str(gotk_path)), check=False)
    log("  ✅", "gotk-components.yaml applied")

    # Also apply sync manifests if they exist
    gotk_sync = gotk_path.parent / "gotk-sync.yaml"
    if gotk_sync.exists():
        run_cmd(kube_cmd(config, "apply", "-f", str(gotk_sync)), check=False)
        log("  ✅", "gotk-sync.yaml applied")

    # Give controllers time to restart with correct RBAC
    log("  ⏳", "Waiting 15s for controllers to restart...")
    time.sleep(15)


# =============================================================================
# STEP 7: VERIFY RECONCILIATION
# =============================================================================

def verify_reconciliation(config: Config) -> None:
    """Poll all 6 Flux Kustomizations until reconciled or timeout.

    LEARNING NOTE — RECONCILIATION IS THE CORE CONCEPT:
        "Reconciliation" is what makes GitOps different from CI/CD-push.
        In traditional CI/CD, a pipeline PUSHES changes to the cluster.
        In GitOps, a controller PULLS the desired state from Git and
        continuously reconciles the actual state to match.

        When you see "reconciliation succeeded," it means:
          1. Flux pulled the latest Git commit
          2. Built the Kustomize overlays for your cluster
          3. Applied the rendered YAML to the cluster
          4. Verified that the applied resources are healthy
          5. Recorded the result as a Kubernetes condition

        We verify ALL 6 layers in the dependency chain:
          flux-system → infrastructure-crds → infrastructure
          → platform-crds → platform → apps
    """
    log("🔄", "Verifying Flux reconciliation (all 6 layers)...")

    if config.dry_run:
        log("  🏜️", "DRY RUN — would verify reconciliation")
        return

    timeout = config.reconciliation_timeout_seconds
    interval = config.reconciliation_poll_interval
    start_time = time.time()

    log("  ", f"Timeout: {timeout}s | Poll interval: {interval}s")
    log("  ", f"Expected layers: {', '.join(config.expected_kustomizations)}")

    while (time.time() - start_time) < timeout:
        result = run_cmd(
            flux_cmd(config, "get", "kustomizations", "--no-header"),
            capture=True, check=False,
        )

        if result.returncode != 0:
            elapsed = int(time.time() - start_time)
            log("  ⏳", f"Flux not responding yet ({elapsed}s elapsed)...")
            time.sleep(interval)
            continue

        # Parse flux output into name → ready status
        statuses = {}
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split()
            if len(parts) >= 4:
                name = parts[0]
                ready = parts[3]  # "True" or "False"
                statuses[name] = ready

        # Check all expected kustomizations
        all_ready = True
        for ks in config.expected_kustomizations:
            status = statuses.get(ks)
            if status == "True":
                log("  ✅", f"{ks}: Ready")
            elif status == "False":
                all_ready = False
                # Get error message for debugging
                detail = run_cmd(
                    flux_cmd(config, "get", "kustomization", ks, "-n", "flux-system"),
                    capture=True, check=False,
                )
                msg = detail.stdout.strip().split("\n")[-1] if detail.stdout else "Unknown"
                log("  ❌", f"{ks}: Failed — {msg}")
            else:
                all_ready = False
                log("  ⏳", f"{ks}: {'In progress' if status else 'Not found yet'}")

        if all_ready:
            elapsed = int(time.time() - start_time)
            log("🎉", f"All 6 layers reconciled successfully! ({elapsed}s)")
            return

        elapsed = int(time.time() - start_time)
        remaining = timeout - elapsed
        log("  ", f"[{elapsed}s / {timeout}s] — next check in {interval}s...")
        print()  # Visual separator between poll rounds
        time.sleep(interval)

    # Timeout reached
    log("⚠️ ", f"Reconciliation not complete after {timeout}s.")
    log("  ", "Check status manually:")
    log("  ", "  flux get kustomizations")
    log("  ", "  flux get helmreleases -A")
    log("  ", "  flux logs --all-namespaces")

    # Show final state
    log("\n📊", "Final Flux status:")
    run_cmd(flux_cmd(config, "get", "kustomizations"), check=False)


# =============================================================================
# MAIN EXECUTION
# =============================================================================

def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Bootstrap Flux CD on a Kubernetes cluster",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Full bootstrap with all env vars set:
  export GITHUB_TOKEN="ghp_..."
  export OP_SA_TOKEN="ops_..."
  python3 scripts/bootstrap.py

  # Dry run — validate without making changes:
  python3 scripts/bootstrap.py --dry-run

  # Bootstrap with 1Password CLI:
  export OP_SERVICE_ACCOUNT_TOKEN="ops_..."
  export GITHUB_TOKEN=$(gh auth token)
  export OP_SA_TOKEN=$(op read "op://Homelab/<item-id>/credential")
  python3 scripts/bootstrap.py

  # Custom cluster:
  CLUSTER_NAME=dev python3 scripts/bootstrap.py
        """,
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Validate everything without making changes",
    )
    parser.add_argument(
        "--skip-rbac-recovery", action="store_true",
        help="Skip the gotk-components.yaml apply step",
    )
    parser.add_argument(
        "--skip-network-checks", action="store_true",
        help="Skip UniFi API network validation (for offline/CI environments)",
    )
    return parser.parse_args()


def main():
    """Orchestrate the full bootstrap process."""
    args = parse_args()

    log("🏗️ ", "Diixtra Forge — Flux CD Bootstrap")
    log("═" * 55, "")

    config = Config()
    config.dry_run = args.dry_run
    config.rbac_recovery_enabled = not args.skip_rbac_recovery
    config.skip_network_checks = args.skip_network_checks

    try:
        preflight_checks(config)
        create_github_repo(config)
        git_init_and_push(config)
        create_bootstrap_secret(config)
        flux_bootstrap(config)
        rbac_recovery(config)
        verify_reconciliation(config)

        log("\n✅", "Bootstrap complete!")
        log("  ", "Next steps:")
        log("  ", "  1. Verify:    flux get kustomizations")
        log("  ", "  2. Logs:      flux logs --all-namespaces")
        log("  ", "  3. Health:    python3 scripts/ops/validate-cluster-health.py")
        log("  ", "  4. Git test:  make a change, push, watch Flux reconcile")

    except subprocess.CalledProcessError as e:
        github_token = os.environ.get("GITHUB_TOKEN", "")
        cmd_str = " ".join(e.cmd) if isinstance(e.cmd, list) else str(e.cmd)
        if github_token:
            cmd_str = cmd_str.replace(github_token, "***")
        log("💀", f"Command failed: {cmd_str}")
        if e.stdout:
            stdout = e.stdout.strip()
            if github_token:
                stdout = stdout.replace(github_token, "***")
            log("  ", f"stdout: {stdout}")
        if e.stderr:
            stderr = e.stderr.strip()
            if github_token:
                stderr = stderr.replace(github_token, "***")
            log("  ", f"stderr: {stderr}")
        sys.exit(1)
    except KeyboardInterrupt:
        log("\n⏹️ ", "Bootstrap interrupted by user.")
        sys.exit(130)


if __name__ == "__main__":
    main()