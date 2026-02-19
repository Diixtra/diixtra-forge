#!/usr/bin/env bash
# =============================================================================
# K8s Node Provisioning Script — Shared Across All OS Variants
# =============================================================================
#
# PURPOSE:
#   Installs node-level packages and system configuration required for a
#   Kubernetes node to join the cluster and run all workloads. Run by Packer
#   as a provisioner during image build.
#
# WHAT THIS INSTALLS:
#   1password-cli   — Bootstrap secret creation (`op read`), ops runbooks
#   open-iscsi      — iSCSI initiator for democratic-csi TrueNAS storage
#   nfs-common      — NFS client for democratic-csi NFS volumes
#   jq              — JSON processing in bootstrap/ops scripts
#
# WHAT THIS CONFIGURES:
#   - Kernel modules for Kubernetes networking (br_netfilter, overlay)
#   - sysctl parameters for packet forwarding and bridge filtering
#   - iscsid service enabled (starts on boot)
#   - cgroup memory enabled (Raspberry Pi only — required for kubelet)
#
# LEARNING NOTE — WHY A SHELL SCRIPT AND NOT PYTHON:
#   Packer provisioners run inside the target image. During a Packer build,
#   the image may not have Python installed yet (minimal server installs
#   often omit it). Bash is guaranteed to exist on any Linux system.
#   The provisioning tasks here are linear "install A, configure B" — exactly
#   what bash excels at. The ops scripts (validate-cluster-health.py, etc.)
#   use Python because they run on an already-provisioned system.
#
# LEARNING NOTE — WHY THESE PACKAGES MATTER:
#   Without open-iscsi: PVCs using iSCSI (democratic-csi → TrueNAS) hang
#     forever in Pending. The iscsid daemon handles the iSCSI protocol
#     between the node and the TrueNAS storage server.
#   Without nfs-common: NFS-backed PVCs fail to mount. The mount.nfs
#     helper is needed by kubelet to attach NFS volumes to pods.
#   Without 1password-cli: The bootstrap secret (onepassword-service-account-token)
#     can't be created programmatically. You'd have to manually paste the
#     token, which defeats the purpose of automated bootstrapping.
#   Without jq: Bootstrap and ops scripts can't parse kubectl JSON output.
#
# USAGE (called by Packer, not manually):
#   sudo bash provision-k8s-node.sh [--role control-plane|worker] [--arch amd64|arm64]
#
# =============================================================================

set -euo pipefail

# ── Parse Arguments ─────────────────────────────────────────────────
NODE_ROLE="${1:-worker}"       # "control-plane" or "worker"
NODE_ARCH="${2:-amd64}"        # "amd64" or "arm64"

echo "═══════════════════════════════════════════════════"
echo "  K8s Node Provisioning"
echo "  Role: ${NODE_ROLE} | Arch: ${NODE_ARCH}"
echo "═══════════════════════════════════════════════════"

# ── Helper Functions ────────────────────────────────────────────────
log() { echo "▸ $*"; }
ok()  { echo "  ✅ $*"; }
warn(){ echo "  ⚠️  $*"; }

# ── 1. System Updates ───────────────────────────────────────────────
log "Updating package index..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
ok "System packages updated"

# ── 2. Install Core Packages ───────────────────────────────────────
log "Installing core packages..."
CORE_PACKAGES=(
    open-iscsi
    nfs-common
    jq
    curl
    gnupg
    apt-transport-https
    ca-certificates
)

# software-properties-common is Ubuntu-only (provides add-apt-repository)
if [ -f /etc/os-release ] && grep -qi ubuntu /etc/os-release; then
    CORE_PACKAGES+=(software-properties-common)
fi

apt-get install -y -qq "${CORE_PACKAGES[@]}"
ok "Core packages installed"

# ── 3. Install 1Password CLI ───────────────────────────────────────
# LEARNING NOTE — APT REPOSITORY VS STANDALONE BINARY:
#   We add the 1Password apt repository rather than downloading a static
#   binary. This means `op` stays updatable via normal `apt upgrade`,
#   which is important for security patches. The GPG key verifies that
#   packages genuinely come from 1Password (supply chain security).
log "Installing 1Password CLI..."

# Add 1Password GPG key
curl -sS https://downloads.1password.com/linux/keys/1password.asc \
    | gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg

# Add apt repository
# LEARNING NOTE — SIGNED-BY:
#   The `signed-by` option in the apt source ties THIS specific repository
#   to THIS specific GPG key. Without it, any trusted key could sign packages
#   for any repository — a security risk called "cross-signing." Modern
#   Debian/Ubuntu require signed-by for third-party repos.
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" \
    | tee /etc/apt/sources.list.d/1password.list > /dev/null

apt-get update -qq
apt-get install -y -qq 1password-cli
ok "1Password CLI installed: $(op --version)"

# ── 4. Enable iSCSI Daemon ─────────────────────────────────────────
# LEARNING NOTE — ENABLE VS START:
#   `systemctl enable` creates a symlink so the service starts on boot.
#   `systemctl start` starts it NOW. In a Packer build, we only `enable`
#   because the image isn't running as a real system — there's no init
#   system managing services during the build. The service will start
#   automatically on first boot of a VM cloned from this image.
log "Enabling iSCSI daemon..."
systemctl enable iscsid
ok "iscsid enabled (will start on boot)"

# ── 5. Kubernetes Networking Prerequisites ──────────────────────────
# LEARNING NOTE — WHY THESE KERNEL MODULES:
#   br_netfilter: Allows iptables rules to see bridged traffic. Without
#     this, kube-proxy can't do Service-to-Pod routing because packets
#     crossing the container bridge bypass iptables entirely.
#   overlay: The overlay filesystem is used by containerd to layer
#     container images efficiently. Each container image layer is an
#     overlay mount, avoiding copying the full filesystem per container.
log "Configuring kernel modules for Kubernetes..."

cat > /etc/modules-load.d/k8s.conf << 'EOF'
# Kubernetes networking requires these kernel modules.
# br_netfilter: enables iptables to process bridged traffic
# overlay: containerd storage driver for container image layers
br_netfilter
overlay
EOF

# Load them now for verification (they'll auto-load on boot via the file above)
modprobe br_netfilter 2>/dev/null || warn "br_netfilter not available (OK in chroot/container)"
modprobe overlay 2>/dev/null || warn "overlay not available (OK in chroot/container)"
ok "Kernel modules configured"

# LEARNING NOTE — SYSCTL FOR KUBERNETES:
#   net.bridge.bridge-nf-call-iptables: Makes bridged IPv4 traffic pass
#     through iptables. Required for kube-proxy to intercept Service traffic.
#   net.bridge.bridge-nf-call-ip6tables: Same for IPv6.
#   net.ipv4.ip_forward: Allows the node to forward packets between
#     interfaces. Required for pod-to-pod traffic across nodes — without
#     this, packets from one pod destined for another node are dropped.
log "Configuring sysctl parameters..."

cat > /etc/sysctl.d/k8s.conf << 'EOF'
# Kubernetes networking: enable bridge traffic filtering and IP forwarding
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system > /dev/null 2>&1 || warn "sysctl apply skipped (OK in chroot/container)"
ok "sysctl parameters configured"

# ── 6. Raspberry Pi Specific Configuration ──────────────────────────
# LEARNING NOTE — CGROUP MEMORY ON RASPBERRY PI:
#   The Raspberry Pi's default kernel boot parameters don't enable the
#   memory cgroup controller. Kubelet REQUIRES memory cgroups to enforce
#   pod memory limits (resources.limits.memory in pod specs). Without it,
#   kubelet refuses to start with the error:
#     "Failed to start ContainerManager: missing cgroups: memory"
#
#   The fix is adding `cgroup_memory=1 cgroup_enable=memory` to the
#   kernel command line in /boot/firmware/cmdline.txt (Pi OS/Debian) or
#   /boot/cmdline.txt (older images).
#
#   We detect Pi hardware by checking /proc/cpuinfo for the BCM2835
#   family (covers Pi 3, 4, and 5) or by checking if /boot/firmware exists.
if [ "${NODE_ARCH}" = "arm64" ]; then
    log "Applying Raspberry Pi specific configuration..."

    CMDLINE_PATH=""
    if [ -f /boot/firmware/cmdline.txt ]; then
        CMDLINE_PATH="/boot/firmware/cmdline.txt"
    elif [ -f /boot/cmdline.txt ]; then
        CMDLINE_PATH="/boot/cmdline.txt"
    fi

    if [ -n "${CMDLINE_PATH}" ]; then
        if ! grep -q "cgroup_memory=1" "${CMDLINE_PATH}"; then
            # cmdline.txt must be a single line — append to existing content
            sed -i 's/$/ cgroup_memory=1 cgroup_enable=memory/' "${CMDLINE_PATH}"
            ok "cgroup memory enabled in ${CMDLINE_PATH}"
        else
            ok "cgroup memory already enabled"
        fi
    else
        warn "No cmdline.txt found — cgroup memory not configured"
        warn "If this is a Pi, check /boot/firmware/cmdline.txt exists"
    fi
fi

# ── 7. Cleanup ──────────────────────────────────────────────────────
# LEARNING NOTE — WHY CLEAN UP IN A PACKER BUILD:
#   Packer captures the VM state as a template image. Any temporary files,
#   apt caches, or logs from the provisioning process are baked into the
#   image permanently. Cleaning up reduces image size and avoids leaking
#   build-time information (like apt package lists that reveal when the
#   image was built, or /tmp files with transient data).
#
#   cloud-init clean resets cloud-init's state so it runs fresh on first
#   boot of a cloned VM. Without this, cloud-init thinks it already ran
#   and skips initialization (hostname setup, SSH key injection, etc.).
log "Cleaning up..."
apt-get autoremove -y -qq
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*

# Reset cloud-init so it runs on first boot of cloned VMs
if command -v cloud-init &> /dev/null; then
    cloud-init clean --logs 2>/dev/null || true
    ok "cloud-init state reset"
fi

# Clear machine-id so each clone gets a unique one
# LEARNING NOTE — MACHINE-ID AND DHCP:
#   /etc/machine-id is used by systemd and DHCP clients as a unique
#   identifier. If two VMs cloned from the same template have the same
#   machine-id, they'll get the same DHCP lease (same IP address) —
#   causing network conflicts. Truncating it forces systemd to generate
#   a new one on first boot.
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ok "machine-id cleared (will regenerate on first boot)"

echo ""
echo "═══════════════════════════════════════════════════"
echo "  ✅ Provisioning complete"
echo "  Packages: open-iscsi, nfs-common, 1password-cli, jq"
echo "  Configs:  kernel modules, sysctl, iscsid enabled"
echo "  Role: ${NODE_ROLE} | Arch: ${NODE_ARCH}"
echo "═══════════════════════════════════════════════════"
