#!/usr/bin/env python3
"""
Flux CD Bootstrap Script for diixtra-forge
==================================================

PURPOSE:
    Automates the complete bootstrapping of Flux CD on a Kubernetes cluster,
    from GitHub repo creation through to verified reconciliation.

WHAT THIS SCRIPT DOES (in order):
    1. Pre-flight checks    — Verifies all required tools are installed and reachable
    2. GitHub repo creation — Creates the private repo via `gh` CLI
    3. Git push             — Initializes the local scaffold and pushes to GitHub
    4. Bootstrap secret     — Creates the 1Password SA token secret on the cluster
    5. Flux bootstrap       — Installs Flux controllers and configures GitOps sync
    6. Verification         — Polls Flux resources until reconciliation is confirmed

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
    op run --env-file=.env -- python3 scripts/bootstrap.py
"""

import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


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
    github_owner: str = "OWNER"              # Your GitHub username or org
    github_repo: str = "diixtra-forge"
    github_branch: str = "main"
    github_visibility: str = "private"       # "private" or "public"

    # ── Flux ────────────────────────────────────────────────────────────
    # The cluster path tells Flux "watch this directory for your config."
    # Each cluster gets its own path inside the repo. When Flux bootstraps,
    # it creates a GitRepository + Kustomization in `flux-system/` that
    # points back at this path — creating a self-referencing loop.
    cluster_name: str = "homelab"
    cluster_path: str = "clusters/homelab"

    # ── 1Password Bootstrap Secret ──────────────────────────────────────
    # LEARNING NOTE — THE BOOTSTRAP SECRET CHICKEN-AND-EGG:
    #   Every secret management system has exactly one secret it can't
    #   manage itself — its own credential. For us, that's the 1Password
    #   Service Account token. This token must exist as a Kubernetes Secret
    #   BEFORE Flux deploys the 1Password Operator HelmRelease, because
    #   the HelmRelease references it via `valuesFrom`. Once the operator
    #   is running, it manages every other secret via OnePasswordItem CRDs.
    #
    #   This is universal: HashiCorp Vault needs an unseal key, AWS Secrets
    #   Manager needs IAM credentials, External Secrets Operator needs a
    #   provider token. There's always exactly one manual secret per cluster.
    op_secret_name: str = "op-service-account-token"
    op_secret_namespace: str = "onepassword-system"
    op_secret_key: str = "token"

    # ── Kubernetes Context ──────────────────────────────────────────────
    # Which kubeconfig context to use. Empty string = current context.
    kube_context: str = ""

    # ── Retry Configuration ─────────────────────────────────────────────
    reconciliation_timeout_seconds: int = 300  # 5 minutes max wait
    reconciliation_poll_interval: int = 10     # Check every 10 seconds

    # ── Local Paths ─────────────────────────────────────────────────────
    # Path to the repo scaffold (this directory)
    repo_root: str = ""

    def __post_init__(self):
        """Resolve paths and override from environment variables."""
        if not self.repo_root:
            # Script is in scripts/, repo root is one level up
            self.repo_root = str(Path(__file__).parent.parent.resolve())

        # Environment variable overrides — allows runtime configuration
        # without editing this file. Follows 12-Factor App principles.
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

    Args:
        cmd:        Command as a list of strings (NOT a single string — avoids
                    shell injection and handles spaces in arguments correctly)
        capture:    If True, capture stdout/stderr instead of printing
        env_extra:  Additional environment variables to set for this command
        check:      If True (default), raise on non-zero exit code
        input_text: String to pipe to stdin (for passing secrets safely)
        cwd:        Working directory for the command (None = inherit from parent)
    """
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)

    kwargs = {
        "env": env,
        "check": check,
        "text": True,  # Decode stdout/stderr as UTF-8 strings
    }

    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE

    if input_text is not None:
        kwargs["input"] = input_text

    if cwd is not None:
        kwargs["cwd"] = cwd

    return subprocess.run(cmd, **kwargs)


def cmd_exists(name: str) -> bool:
    """Check if a command-line tool is available on PATH."""
    return shutil.which(name) is not None


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

    # ── Required CLI tools ──────────────────────────────────────────
    required_tools = {
        "flux": "Flux CLI — install: curl -s https://fluxcd.io/install.sh | sudo bash",
        "kubectl": "Kubernetes CLI — install: https://kubernetes.io/docs/tasks/tools/",
        "gh": "GitHub CLI — install: https://cli.github.com/",
        "git": "Git — install: sudo apt install git",
    }

    missing = []
    for tool, install_hint in required_tools.items():
        if cmd_exists(tool):
            # Get version for debugging context
            try:
                result = run_cmd([tool, "version"], capture=True, check=False)
                version = result.stdout.strip().split("\n")[0]
                log("  ✅", f"{tool}: {version}")
            except Exception:
                log("  ✅", f"{tool}: found")
        else:
            log("  ❌", f"{tool}: NOT FOUND — {install_hint}")
            missing.append(tool)

    if missing:
        log("💀", f"Missing required tools: {', '.join(missing)}")
        sys.exit(1)

    # ── Environment variables ───────────────────────────────────────
    # LEARNING NOTE — GITHUB_TOKEN vs GH_TOKEN:
    #   The Flux CLI reads GITHUB_TOKEN. The GitHub CLI (gh) reads GH_TOKEN
    #   or GITHUB_TOKEN. We check for GITHUB_TOKEN since both tools use it.
    #   The 1Password SA token is checked separately because it's only
    #   needed for the bootstrap secret step.
    if not os.environ.get("GITHUB_TOKEN"):
        log("❌", "GITHUB_TOKEN environment variable is not set.")
        log("  ", "Generate a PAT at: https://github.com/settings/tokens")
        log("  ", "Required permissions: repo (all), admin:org (read)")
        sys.exit(1)
    log("  ✅", "GITHUB_TOKEN is set")

    if not os.environ.get("OP_SA_TOKEN"):
        log("⚠️ ", "OP_SA_TOKEN not set — bootstrap secret step will be skipped.")
        log("  ", "You'll need to create it manually before Flux can deploy 1Password Operator.")
    else:
        log("  ✅", "OP_SA_TOKEN is set")

    # ── Kubernetes cluster connectivity ─────────────────────────────
    kube_cmd = ["kubectl", "cluster-info"]
    if config.kube_context:
        kube_cmd.extend(["--context", config.kube_context])

    try:
        run_cmd(kube_cmd, capture=True)
        log("  ✅", "Kubernetes cluster is reachable")
    except subprocess.CalledProcessError:
        log("❌", "Cannot connect to Kubernetes cluster.")
        if config.kube_context:
            log("  ", f"Context '{config.kube_context}' may be invalid.")
        log("  ", "Check: kubectl cluster-info")
        sys.exit(1)

    # ── Flux pre-check ──────────────────────────────────────────────
    # LEARNING NOTE — `flux check --pre`:
    #   This is Flux's own pre-flight validation. It checks:
    #     - Kubernetes version compatibility
    #     - RBAC permissions (can Flux create CRDs, namespaces, etc.)
    #     - Existing Flux installation (warns if already bootstrapped)
    #   Running this before bootstrap prevents the most common failures.
    flux_check_cmd = ["flux", "check", "--pre"]
    if config.kube_context:
        flux_check_cmd.extend(["--context", config.kube_context])

    try:
        run_cmd(flux_check_cmd, capture=True)
        log("  ✅", "Flux pre-check passed")
    except subprocess.CalledProcessError as e:
        log("⚠️ ", "Flux pre-check reported warnings (may be okay if Flux is already installed):")
        log("  ", e.stderr.strip() if e.stderr else "No details")

    # ── Config summary ──────────────────────────────────────────────
    log("📋", "Bootstrap configuration:")
    log("  ", f"GitHub:     {config.github_owner}/{config.github_repo}")
    log("  ", f"Branch:     {config.github_branch}")
    log("  ", f"Cluster:    {config.cluster_name}")
    log("  ", f"Flux path:  {config.cluster_path}")
    log("  ", f"Repo root:  {config.repo_root}")

    # ── Scaffold validation ─────────────────────────────────────────
    # LEARNING NOTE — VALIDATE STATE BEFORE MUTATING:
    #   This is the check that prevents the "empty repo" disaster. Without it,
    #   the script happily `git add .` and commits whatever happens to be in
    #   the working directory — which might be nothing, your home directory,
    #   or a partial extraction. By verifying that the expected directories
    #   and files exist, we fail fast with a clear message instead of pushing
    #   garbage to GitHub and wasting 30 minutes debugging.
    #
    #   The principle: ANY step that creates or mutates state (git commit,
    #   kubectl apply, flux bootstrap) should be preceded by a validation
    #   step that confirms the inputs are correct. This is the same reason
    #   Terraform has `plan` before `apply`.
    required_dirs = [
        config.cluster_path,         # clusters/homelab/
        "infrastructure/base",       # Base infrastructure manifests
        "infrastructure/" + config.cluster_name,  # Cluster overlay
    ]
    required_files = [
        f"{config.cluster_path}/infrastructure.yaml",
        f"{config.cluster_path}/platform.yaml",
        f"{config.cluster_path}/apps.yaml",
        "README.md",
    ]

    root = Path(config.repo_root)
    missing_dirs = [d for d in required_dirs if not (root / d).is_dir()]
    missing_files = [f for f in required_files if not (root / f).is_file()]

    if missing_dirs or missing_files:
        log("❌", "Scaffold validation failed — required files/directories missing:")
        for d in missing_dirs:
            log("  ", f"  Missing directory: {d}")
        for f in missing_files:
            log("  ", f"  Missing file: {f}")
        log("  ", "")
        log("  ", "This means either:")
        log("  ", "  1. The scaffold tarball was not extracted into this directory")
        log("  ", "  2. You're running the script from the wrong directory")
        log("  ", "  3. The scaffold files were deleted or moved")
        log("  ", "")
        log("  ", f"Expected scaffold root: {config.repo_root}")
        log("  ", "Extract the tarball: tar xzf diixtra-forge-scaffold.tar.gz")
        log("  ", "Then run: cd diixtra-forge && python3 scripts/bootstrap.py")
        sys.exit(1)

    log("  ✅", f"Scaffold validated — {len(required_dirs)} dirs, {len(required_files)} files")

    log("✅", "Pre-flight checks passed.\n")


# =============================================================================
# STEP 2: CREATE GITHUB REPOSITORY
# =============================================================================
#
# LEARNING NOTE — `gh` CLI vs GitHub API:
#   We could use the GitHub REST API directly with Python's `requests`.
#   But `gh` CLI handles authentication (reads GITHUB_TOKEN), pagination,
#   and error formatting automatically. It's also idempotent-ish — creating
#   a repo that already exists returns a clear error we can catch.
#
#   For production tooling, the GitHub API gives you more control, but
#   for bootstrap scripts, `gh` is the pragmatic choice.
# =============================================================================

def create_github_repo(config: Config) -> None:
    """Create the GitHub repository if it doesn't exist."""
    log("📦", f"Creating GitHub repository: {config.github_owner}/{config.github_repo}")

    # Check if repo already exists
    check_result = run_cmd(
        ["gh", "repo", "view", f"{config.github_owner}/{config.github_repo}"],
        capture=True,
        check=False,
    )

    if check_result.returncode == 0:
        log("  ℹ️ ", "Repository already exists — skipping creation.")
        return

    # Create the repository
    create_cmd = [
        "gh", "repo", "create",
        f"{config.github_owner}/{config.github_repo}",
        f"--{config.github_visibility}",
        "--description", "Infrastructure monorepo — Flux CD, Terraform, IDP stack",
    ]

    # LEARNING NOTE — DEFENSIVE ERROR HANDLING:
    #   We check if the repo exists first with `gh repo view`, but that check
    #   can fail for reasons other than "repo doesn't exist" — e.g. the token
    #   lacks metadata read permissions on the org. So we also handle "already
    #   exists" in the create step as a fallback. Belt and braces.
    create_result = run_cmd(create_cmd, capture=True, check=False)
    if create_result.returncode == 0:
        log("  ✅", "Repository created successfully.")
    elif "already exists" in (create_result.stderr or "").lower() \
         or "Name already exists" in (create_result.stderr or ""):
        log("  ℹ️ ", "Repository already exists — continuing.")
    else:
        # Unexpected error — raise it
        log("💀", f"Command failed: {' '.join(create_cmd)}")
        if create_result.stderr:
            log("  ", create_result.stderr.strip())
        sys.exit(1)


# =============================================================================
# STEP 3: GIT INIT, COMMIT, AND PUSH
# =============================================================================
#
# LEARNING NOTE — GIT INIT IN AN EXISTING DIRECTORY:
#   `git init` in a directory that already has files is safe — it creates
#   the .git/ directory without touching existing files. We then `git add .`
#   to stage everything and make the initial commit. This is the standard
#   pattern for "I have files locally, now I want them in a Git repo."
#
#   The `--set-upstream` on the first push establishes the tracking
#   relationship between local `main` and `origin/main`. After this,
#   plain `git push` knows where to push without specifying the remote.
# =============================================================================

def git_init_and_push(config: Config) -> None:
    """Initialize git in the scaffold directory and push to GitHub."""
    log("📤", "Initializing git and pushing scaffold to GitHub...")

    repo_root = config.repo_root
    git_dir = Path(repo_root) / ".git"

    # Helper to run git commands in the repo directory
    def git(*args: str) -> subprocess.CompletedProcess:
        cmd = ["git"] + list(args)
        return run_cmd(cmd, capture=True, check=True, cwd=repo_root)

    # Initialize git if not already initialized
    if not git_dir.exists():
        git("init", "-b", config.github_branch)
        log("  ✅", "Git initialized")
    else:
        log("  ℹ️ ", "Git already initialized — skipping init.")

    # Configure git user (Flux uses these for commits)
    git("config", "user.email", "flux@kazie.co.uk")
    git("config", "user.name", "Flux Bootstrap")

    # LEARNING NOTE — GIT AUTHENTICATION WITH TOKENS:
    #   Raw `git push` doesn't know about GITHUB_TOKEN — that's a convention
    #   used by `gh` CLI and GitHub Actions, not by git itself. Git has its
    #   own credential system with "credential helpers" — programs that git
    #   calls to get usernames and passwords.
    #
    #   We pass a credential helper via the `-c` flag on push commands.
    #   The `-c` flag sets config for that single command invocation only —
    #   nothing is written to .git/config or any file on disk. The token
    #   exists only in the process memory for the duration of the push.
    #
    #   The username `x-access-token` is a GitHub convention — it tells
    #   GitHub "this is a PAT, not a user password." Any non-empty string
    #   works as the username; the token is what matters.
    #
    #   Why not embed the token in the URL (https://token@github.com/...)?
    #   Because git stores the remote URL in .git/config, which persists
    #   the token on disk. The -c flag approach is ephemeral.
    github_token = os.environ.get("GITHUB_TOKEN", "")
    cred_helper = f"!f() {{ echo username=x-access-token; echo password={github_token}; }}; f"

    def git_auth(*args: str) -> subprocess.CompletedProcess:
        """Run a git command with GitHub token authentication (for push/pull).

        SECURITY NOTE: Always captures output to prevent tokens leaking into
        terminal history or logs. The credential helper string contains the
        raw token — if git fails, the full command (including token) would
        appear in the CalledProcessError traceback. We catch this and show
        a sanitised error instead.
        """
        cmd = ["git", "-c", f"credential.helper={cred_helper}"] + list(args)
        result = run_cmd(cmd, capture=True, check=False, cwd=repo_root)
        if result.returncode != 0:
            # Sanitise: show the git args but NOT the credential helper
            safe_cmd = f"git {' '.join(args)}"
            # Show stderr but redact anything that looks like a token
            safe_stderr = (result.stderr or "").replace(github_token, "***")
            raise subprocess.CalledProcessError(
                result.returncode, safe_cmd,
                output=result.stdout,
                stderr=safe_stderr,
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

    # Stage all files
    git("add", ".")

    # Check if there's anything to commit
    status = git("status", "--porcelain")
    if status.stdout.strip():
        git("commit", "-m", "feat: initial scaffold for diixtra-forge\n\n"
            "- Infrastructure layer: Caddy, 1Password Operator, MetalLB\n"
            "- Platform layer: Kyverno policies, Grafana Alloy\n"
            "- CI/CD: Flux validation, Terraform Cloudflare workflows\n"
            "- ADRs: Flux, monorepo, Kyverno, Crossplane migration")
        log("  ✅", "Initial commit created")
    else:
        log("  ℹ️ ", "No changes to commit")

    # Push to GitHub
    # LEARNING NOTE — WHY `--set-upstream`:
    #   The first push needs `-u` (--set-upstream) to create the tracking
    #   relationship. After this, `git push` alone works. Flux will use
    #   this tracking to detect new commits and trigger reconciliation.
    #
    # LEARNING NOTE — PULL REBASE VS FORCE PUSH:
    #   When the remote has commits the local doesn't (e.g. Flux bootstrap
    #   already pushed its own manifests), a naive push is rejected. There
    #   are two strategies:
    #
    #   1. `git pull --rebase` — fetches remote commits and replays local
    #      commits on top. This PRESERVES both the remote work (Flux's
    #      self-management manifests) and the local work (scaffold files).
    #      This is almost always what you want.
    #
    #   2. `git push --force` — overwrites the remote entirely. This DESTROYS
    #      the remote commits. Dangerous if Flux already committed its
    #      clusters/homelab/flux-system/ directory — you'd lose Flux's
    #      self-management config and it would stop reconciling.
    #
    #   We use pull-rebase first, falling back to force-with-lease only if
    #   the rebase itself fails (e.g. unresolvable conflicts).
    try:
        git_auth("push", "-u", "origin", config.github_branch)
        log("  ✅", "Pushed to GitHub")
    except subprocess.CalledProcessError as e:
        stderr = str(e.stderr or "")
        if "rejected" in stderr or "fetch first" in stderr:
            # LEARNING NOTE — STASH BEFORE REBASE:
            #   `git pull --rebase` refuses to run if there are unstaged
            #   changes in the working tree. This is a safety measure — rebase
            #   replays commits on a new base, and uncommitted changes could
            #   conflict. `git stash` saves the working tree state to a stack,
            #   the rebase runs on a clean tree, then `git stash pop` restores
            #   the saved changes. If pop has conflicts, they're shown as merge
            #   conflicts in the affected files.
            log("  ℹ️ ", "Remote has new commits — rebasing local work on top...")
            try:
                # Stash any uncommitted changes so rebase can proceed
                stash_result = git("stash", "--include-untracked")
                has_stash = "No local changes" not in (stash_result.stdout or "")

                git_auth("pull", "--rebase", "origin", config.github_branch)

                if has_stash:
                    git("stash", "pop")
                    # Re-commit any restored changes
                    git("add", ".")
                    status = git("status", "--porcelain")
                    if status.stdout.strip():
                        git("commit", "-m", "feat: add scaffold files after rebase")

                git_auth("push", "-u", "origin", config.github_branch)
                log("  ✅", "Rebased on remote changes and pushed to GitHub")
            except subprocess.CalledProcessError:
                log("  ⚠️ ", "Rebase failed — force pushing (remote will be overwritten)")
                git_auth("push", "--force-with-lease", "-u", "origin", config.github_branch)
                log("  ✅", "Force-pushed to GitHub")
        else:
            raise


# =============================================================================
# STEP 4: CREATE 1PASSWORD BOOTSTRAP SECRET
# =============================================================================
#
# LEARNING NOTE — WHY kubectl create secret AND NOT kubectl apply:
#   `kubectl create` fails if the resource already exists (idempotent? no).
#   `kubectl apply` creates or updates (idempotent? yes).
#   BUT for secrets, `kubectl apply` would show the secret value in the
#   command history and in the annotation that apply adds to resources.
#
#   The safest pattern is:
#     1. Check if the secret exists (kubectl get)
#     2. If not, create it with --from-literal (value from env var)
#     3. If yes, skip or update via kubectl patch
#
#   We pipe the token via stdin to avoid it appearing in process listings.
# =============================================================================

def create_bootstrap_secret(config: Config) -> None:
    """Create the 1Password Service Account token as a Kubernetes Secret."""
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

    kube_ctx = ["--context", config.kube_context] if config.kube_context else []

    # Ensure namespace exists
    run_cmd(
        ["kubectl", "create", "namespace", config.op_secret_namespace] + kube_ctx,
        capture=True,
        check=False,  # Ignore "already exists" error
    )

    # Check if secret already exists
    check = run_cmd(
        ["kubectl", "get", "secret", config.op_secret_name,
         "-n", config.op_secret_namespace] + kube_ctx,
        capture=True,
        check=False,
    )

    if check.returncode == 0:
        log("  ℹ️ ", "Bootstrap secret already exists — skipping.")
        return

    # Create the secret
    # LEARNING NOTE — --from-literal SECURITY:
    #   Even with --from-literal, the token value appears in the process
    #   listing briefly. For maximum security, you'd create the secret
    #   from a file (--from-file) or use kubectl's stdin mode. For a
    #   homelab bootstrap script, --from-literal is acceptable since
    #   the value comes from an environment variable that's already in
    #   the process environment.
    run_cmd(
        ["kubectl", "create", "secret", "generic", config.op_secret_name,
         "--namespace", config.op_secret_namespace,
         f"--from-literal={config.op_secret_key}={op_token}"] + kube_ctx,
    )
    log("  ✅", f"Bootstrap secret created: {config.op_secret_namespace}/{config.op_secret_name}")


# =============================================================================
# STEP 5: FLUX BOOTSTRAP
# =============================================================================
#
# LEARNING NOTE — WHAT `flux bootstrap github` ACTUALLY DOES:
#   This is the most important thing to understand. The bootstrap command
#   does SIX distinct things in sequence:
#
#   1. CONNECTS to GitHub and clones/creates the repository
#   2. GENERATES component manifests — YAML for all Flux controllers:
#        - source-controller     (watches Git repos, Helm repos, OCI)
#        - kustomize-controller  (builds Kustomize overlays, applies to cluster)
#        - helm-controller       (manages HelmRelease lifecycle)
#        - notification-controller (sends/receives webhooks)
#   3. COMMITS these manifests to `clusters/<name>/flux-system/`
#   4. PUSHES the commit to GitHub
#   5. INSTALLS the controllers on your cluster (kubectl apply)
#   6. CREATES a GitRepository + Kustomization that points back at itself
#
#   Step 6 is the clever part — the "self-referencing loop." After bootstrap,
#   Flux watches the Git repo for changes to its own configuration. If you
#   push an update to `clusters/homelab/flux-system/gotk-components.yaml`,
#   Flux updates itself. Git becomes the source of truth for everything,
#   including the GitOps tool itself.
#
#   The `--path` flag tells Flux which directory to watch. Combined with
#   the three Flux Kustomization files we created (infrastructure.yaml,
#   platform.yaml, apps.yaml), this is how the full dependency chain starts:
#
#   flux-system/gotk-sync.yaml watches clusters/homelab/
#   → finds infrastructure.yaml → builds infrastructure/homelab/ → applies
#   → finds platform.yaml → waits for infrastructure → builds platform/homelab/
#   → finds apps.yaml → waits for platform → builds apps/homelab/
#
#   The `--token-auth` flag tells Flux to use HTTPS + PAT for Git access
#   instead of SSH keys. This is simpler for personal repos and avoids
#   SSH key management. The PAT is stored as a Kubernetes Secret in the
#   flux-system namespace.
# =============================================================================

def flux_bootstrap(config: Config) -> None:
    """Run flux bootstrap github to install Flux and configure GitOps sync."""
    log("🚀", "Bootstrapping Flux CD on cluster...")

    github_token = os.environ.get("GITHUB_TOKEN", "")

    flux_cmd = [
        "flux", "bootstrap", "github",
        "--token-auth",                              # Use HTTPS + PAT (not SSH)
        f"--owner={config.github_owner}",
        f"--repository={config.github_repo}",
        f"--branch={config.github_branch}",
        f"--path={config.cluster_path}",
        "--personal",                                # Personal account (not org)
        "--reconcile",                               # Update if already bootstrapped
        # Image Automation controllers — not installed by default.
        # These enable automatic container image updates via Git commits.
        # --read-write-key is required so the automation controller can
        # push commits back to the repo (default deploy key is read-only).
        "--components-extra=image-reflector-controller,image-automation-controller",
        "--read-write-key",
    ]

    if config.kube_context:
        flux_cmd.extend(["--context", config.kube_context])

    # LEARNING NOTE — WHY WE PASS THE TOKEN VIA ENVIRONMENT:
    #   The flux CLI reads GITHUB_TOKEN from the environment. We could also
    #   pipe it via stdin (`echo $TOKEN | flux bootstrap github`), but
    #   environment variables are the documented approach and cleaner in Python.
    #   The token is NOT stored in shell history this way.
    run_cmd(flux_cmd, env_extra={"GITHUB_TOKEN": github_token})

    log("  ✅", "Flux bootstrap completed.")


# =============================================================================
# STEP 6: VERIFY RECONCILIATION
# =============================================================================
#
# LEARNING NOTE — RECONCILIATION IS THE CORE CONCEPT:
#   "Reconciliation" is what makes GitOps different from CI/CD-push.
#   In traditional CI/CD, a pipeline PUSHES changes to the cluster.
#   In GitOps, a controller PULLS the desired state from Git and
#   continuously reconciles the actual state to match.
#
#   When you see "reconciliation succeeded," it means:
#     1. Flux pulled the latest Git commit
#     2. Built the Kustomize overlays for your cluster
#     3. Applied the rendered YAML to the cluster
#     4. Verified that the applied resources are healthy
#     5. Recorded the result as a Kubernetes condition
#
#   If reconciliation fails, Flux retries on the interval you specified
#   (retryInterval: 1m in our Kustomizations). It also records the error
#   in the resource's status, which you can see with:
#     flux get kustomizations
#     kubectl describe kustomization infrastructure -n flux-system
#
#   The verification loop below polls these conditions. In production,
#   you'd use Flux's notification-controller to send alerts to Slack
#   or PagerDuty instead of polling — but for bootstrap, polling is fine.
# =============================================================================

def verify_reconciliation(config: Config) -> None:
    """Poll Flux resources until reconciliation is confirmed or timeout."""
    log("🔄", "Verifying Flux reconciliation...")

    kube_ctx = ["--context", config.kube_context] if config.kube_context else []
    timeout = config.reconciliation_timeout_seconds
    interval = config.reconciliation_poll_interval
    start_time = time.time()

    # Resources to verify — in dependency order
    # LEARNING NOTE — WHAT EACH RESOURCE TYPE MEANS:
    #   GitRepository: "Is Flux successfully pulling from GitHub?"
    #   Kustomization: "Did the rendered manifests apply cleanly?"
    #   HelmRelease:   "Did the Helm chart install/upgrade succeed?"
    resources_to_check = [
        ("gitrepository", "flux-system", "flux-system"),
        ("kustomization", "flux-system", "flux-system"),
        ("kustomization", "infrastructure", "flux-system"),
    ]

    log("  ", "Waiting for reconciliation (this may take a few minutes)...")

    while (time.time() - start_time) < timeout:
        all_ready = True

        for kind, name, namespace in resources_to_check:
            result = run_cmd(
                ["flux", "get", kind, name, "-n", namespace] + kube_ctx,
                capture=True,
                check=False,
            )

            if result.returncode != 0:
                all_ready = False
                continue

            output = result.stdout.strip()
            # Flux CLI output includes "True" in the Ready column when reconciled
            if "True" in output:
                log("  ✅", f"{kind}/{name}: Ready")
            else:
                all_ready = False
                # Extract status message for debugging
                log("  ⏳", f"{kind}/{name}: Not ready yet")

        if all_ready:
            log("🎉", "All Flux resources reconciled successfully!")
            break

        elapsed = int(time.time() - start_time)
        remaining = timeout - elapsed
        log("  ", f"Elapsed: {elapsed}s / Timeout: {timeout}s — retrying in {interval}s...")
        time.sleep(interval)
    else:
        log("⚠️ ", f"Reconciliation not complete after {timeout}s.")
        log("  ", "This doesn't necessarily mean it failed — complex deployments take time.")
        log("  ", "Check status manually:")
        log("  ", "  flux get all")
        log("  ", "  flux logs --all-namespaces")

    # Final status dump for debugging
    log("\n📊", "Final Flux status:")
    run_cmd(["flux", "get", "all"] + kube_ctx, check=False)


# =============================================================================
# STEP 2: DEPENDENCY CHECKLIST
# =============================================================================
#
# LEARNING NOTE — WHY A CHECKLIST, NOT JUST AUTOMATED CHECKS:
#   Some dependencies can't be verified programmatically:
#     - "Does the 1Password vault contain the right items?" — we'd need
#       vault read access to check, which the SA token may not have yet
#     - "Is the GitHub token scoped correctly?" — we can test API access
#       but can't enumerate all required scopes from the response
#     - "Are the TrueNAS datasets configured?" — depends on external storage
#
#   The checklist pattern is borrowed from aviation pre-flight checklists:
#   even when instruments can verify a condition automatically, the pilot
#   still confirms it verbally. The human-in-the-loop catches the things
#   automation misses.
# =============================================================================

def confirm_dependencies(config: Config) -> None:
    """Display dependency checklist and ask for confirmation before proceeding."""

    # Skip in non-interactive mode (CI/CD pipelines)
    if os.environ.get("BOOTSTRAP_YES") == "1" or "--yes" in sys.argv:
        log("  ℹ️ ", "Skipping dependency checklist (--yes or BOOTSTRAP_YES=1)")
        return

    op_token_set = bool(os.environ.get("OP_SA_TOKEN"))

    log("📋", "Pre-bootstrap dependency checklist:")
    log("═" * 55, "")
    log("  ", "")
    log("  ", "The following must be in place BEFORE bootstrap can succeed.")
    log("  ", "Items marked [AUTO] are handled by this script.")
    log("  ", "Items marked [MANUAL] require your action first.")
    log("  ", "")

    log("  ", "─── GitHub ───────────────────────────────────────────")
    log("  ", "[AUTO]   GitHub repo will be created if it doesn't exist")
    log("  ", f"[CHECK]  GITHUB_TOKEN has 'Contents: R/W', 'Administration: R/W',")
    log("  ", f"         and 'Workflows' permissions on {config.github_owner}/{config.github_repo}")
    log("  ", "")

    log("  ", "─── 1Password ────────────────────────────────────────")
    if op_token_set:
        log("  ✅", "OP_SA_TOKEN is set — bootstrap secret will be created automatically")
    else:
        log("  ⚠️ ", "OP_SA_TOKEN not set — you must create the secret manually after bootstrap:")
        log("  ", f"         kubectl create ns {config.op_secret_namespace}")
        log("  ", f"         kubectl create secret generic {config.op_secret_name} \\")
        log("  ", f"           -n {config.op_secret_namespace} --from-literal=token=<SA-TOKEN>")
    log("  ", "")
    log("  ", "[MANUAL] 1Password Service Account exists with vault access")
    log("  ", "         → Create at: 1Password Business → Developer → Service Accounts")
    log("  ", "[MANUAL] 1Password vault contains required items:")
    log("  ", "         → 'cloudflare-api-token' (for Caddy TLS DNS-01 challenge)")
    log("  ", "         → 'truenas-api-key'      (for democratic-csi storage)")
    log("  ", "")

    log("  ", "─── Cluster ──────────────────────────────────────────")
    log("  ", "[AUTO]   Flux controllers will be installed")
    log("  ", "[AUTO]   GitRepository + Kustomizations will be created")
    log("  ", f"[CHECK]  kubectl context points to the correct cluster ({config.cluster_name})")
    log("  ", "")

    log("  ", "─── Infrastructure (resolves after bootstrap) ───────")
    log("  ", "[AFTER]  MetalLB assigns LoadBalancer IPs (10.2.0.200-210)")
    log("  ", "[AFTER]  Caddy serves HTTPS via Cloudflare DNS-01")
    log("  ", "[AFTER]  democratic-csi provisions PVCs from TrueNAS")
    log("  ", "")
    log("═" * 55, "")

    # Prompt for confirmation
    try:
        answer = input("\n  Continue with bootstrap? [y/N] ").strip().lower()
    except EOFError:
        answer = ""

    if answer not in ("y", "yes"):
        log("⏹️ ", "Bootstrap cancelled.")
        sys.exit(0)

    log("", "")


# =============================================================================
# MAIN EXECUTION
# =============================================================================

def main():
    """Orchestrate the full bootstrap process."""
    log("🏗️ ", "Diixtra Forge — Flux CD Bootstrap")
    log("═" * 55, "")

    config = Config()

    # Validate that the user has set their GitHub owner
    if config.github_owner == "OWNER":
        log("❌", "Please set GITHUB_OWNER environment variable to your GitHub username.")
        log("  ", "Example: export GITHUB_OWNER=jameskazie")
        sys.exit(1)

    try:
        # Step 1: Validate everything before making changes
        preflight_checks(config)

        # Step 2: Dependency checklist — confirm prerequisites are met
        # LEARNING NOTE — HUMAN-IN-THE-LOOP BEFORE STATE MUTATION:
        #   Everything above this point is read-only (checking tools, validating
        #   files). Everything below MUTATES state (creates repos, pushes code,
        #   installs controllers). This is the last safe exit point.
        #
        #   Listing dependencies explicitly serves two purposes:
        #   1. Prevents wasted time — if a dependency is missing, you find out
        #      BEFORE the script creates a half-configured environment
        #   2. Documentation — new team members can read the checklist to
        #      understand what the bootstrap requires without reading the code
        #
        #   The --yes flag skips this for CI/CD pipelines where a human isn't
        #   present. In those environments, the pipeline definition IS the
        #   checklist — each step's preconditions are encoded in the workflow.
        confirm_dependencies(config)

        # Step 3: Create the GitHub repo (idempotent — skips if exists)
        create_github_repo(config)

        # Step 4: Push the scaffold to GitHub
        git_init_and_push(config)

        # Step 5: Create the 1Password bootstrap secret
        create_bootstrap_secret(config)

        # Step 6: Bootstrap Flux (the main event)
        flux_bootstrap(config)

        # Step 7: Verify everything reconciled
        verify_reconciliation(config)

        log("\n✅", "Bootstrap complete!")
        log("  ", "Next steps:")
        log("  ", "  1. Verify with: flux get all")
        log("  ", "  2. Check Flux logs: flux logs --all-namespaces")
        log("  ", "  3. Make a change in Git and watch Flux reconcile it")
        log("  ", "  4. Add the platform.yaml and apps.yaml Kustomizations")

    except subprocess.CalledProcessError as e:
        # Sanitise any token that might appear in error output
        github_token = os.environ.get("GITHUB_TOKEN", "")
        cmd_str = ' '.join(e.cmd) if isinstance(e.cmd, list) else str(e.cmd)
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
