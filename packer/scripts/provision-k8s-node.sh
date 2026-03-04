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
#   sudo bash provision-k8s-node.sh [control-plane|worker] [amd64|arm64]
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

# ── 4. Install Helm CLI ──────────────────────────────────────────────
# LEARNING NOTE — WHY HELM ON THE NODE IMAGE:
#   The bootstrap script (bootstrap.py) installs Cilium CNI via Helm
#   BEFORE Flux is running. This solves the CNI chicken-and-egg problem:
#   kubeadm needs a CNI for CoreDNS → DNS → Flux, but Flux deploys the
#   CNI HelmRelease. By pre-installing Cilium via Helm CLI, the cluster
#   has a working CNI immediately, and Flux adopts the existing release.
#
#   Helm is only needed on the control plane node, but installing it on
#   all images keeps them identical (same template, different roles).
log "Installing Helm CLI..."

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
ok "Helm installed: $(helm version --short)"

# ── 5. Enable iSCSI Daemon ─────────────────────────────────────────
# LEARNING NOTE — ENABLE VS START:
#   `systemctl enable` creates a symlink so the service starts on boot.
#   `systemctl start` starts it NOW. In a Packer build, we only `enable`
#   because the image isn't running as a real system — there's no init
#   system managing services during the build. The service will start
#   automatically on first boot of a VM cloned from this image.
log "Enabling iSCSI daemon..."
systemctl enable iscsid
ok "iscsid enabled (will start on boot)"

# ── 6. Kubernetes Networking Prerequisites ──────────────────────────
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

# ── 7. Kubelet DNS Configuration ──────────────────────────────────────
# LEARNING NOTE — WHY A CUSTOM RESOLV.CONF FOR KUBELET:
#   By default, kubelet reads the node's /etc/resolv.conf and propagates
#   its search domains into every pod. If the node has `search kazie.co.uk`
#   (from DHCP or static config), pods inherit it. Combined with a wildcard
#   DNS record (*.kazie.co.uk → Caddy LB IP), this hijacks ALL external
#   DNS lookups from pods — e.g. github.com becomes github.com.kazie.co.uk
#   → resolves to the Caddy IP instead of the real GitHub server.
#
#   This breaks Flux (can't pull from GitHub), ACME certificate issuance
#   (can't reach Let's Encrypt), and any other outbound HTTPS from pods.
#
#   The fix: give kubelet a dedicated resolv.conf with only nameserver
#   entries (no search domains). Pods then get clean DNS:
#     search <ns>.svc.cluster.local svc.cluster.local cluster.local
#   without the node's search domain appended.
log "Configuring kubelet DNS..."

mkdir -p /etc/kubernetes
cat > /etc/kubernetes/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

ok "Kubelet DNS resolv.conf created (/etc/kubernetes/resolv.conf)"

# ── 8. Dedicated etcd Disk ──────────────────────────────────────────
# LEARNING NOTE — WHY A DEDICATED ETCD DISK:
#   etcd uses a write-ahead log (WAL) that requires fast, synchronous writes
#   (fdatasync). When etcd shares a disk with containerd images, kubelet, and
#   container logs, I/O contention causes fdatasync latency to spike from <10ms
#   to 10-30 seconds. This makes etcd unresponsive, the API server times out,
#   and the entire control plane crash-loops.
#
#   The Packer template attaches a second disk (sdb) specifically for etcd.
#   This script formats it, mounts it at /var/lib/etcd, and adds an fstab
#   entry so it persists across reboots. etcd then has dedicated I/O bandwidth
#   and the control plane stays stable.
#
#   We only do this on control-plane nodes (workers don't run etcd).
#   The disk is detected by looking for an unformatted second SCSI disk.
if [ "${NODE_ROLE}" = "control-plane" ]; then
    log "Configuring dedicated etcd disk..."

    # Find the second disk (sdb) — added by Packer template
    ETCD_DISK="/dev/sdb"
    if [ -b "${ETCD_DISK}" ]; then
        # Format with ext4 — etcd's recommended filesystem
        mkfs.ext4 -q -L etcd-data "${ETCD_DISK}"

        # Create mount point and add fstab entry
        # LEARNING NOTE — DISCARD ON LOCAL NVMe VS NAS:
        #   The etcd disk should be on local NVMe (etcd_disk_storage = "local-lvm").
        #   On local NVMe, discard/TRIM is fast and reclaims thin pool space.
        #   On NAS (TrueNAS), large TRIM requests stall the virtual disk completely
        #   (100% util, zero throughput). We previously used `nodiscard` and a udev
        #   rule to block TRIMs when etcd was on NAS — those workarounds were removed
        #   when we moved to local NVMe. If you must use NAS storage, add `nodiscard`
        #   to the mount options and restore the udev rule from git history.
        mkdir -p /var/lib/etcd
        echo "LABEL=etcd-data /var/lib/etcd ext4 defaults,noatime,discard 0 2" >> /etc/fstab

        # Mount now to verify it works
        mount /var/lib/etcd

        # Set permissions — etcd runs as root in the static pod but the
        # data directory needs restricted access
        chmod 700 /var/lib/etcd

        ok "etcd disk formatted and mounted at /var/lib/etcd (${ETCD_DISK})"
    else
        echo "ERROR: No dedicated etcd disk found at ${ETCD_DISK}"
        echo "  Control-plane nodes MUST have a dedicated etcd disk."
        echo "  Ensure the Packer template includes a second disk block with etcd_disk_storage."
        echo "  See: docs/troubleshooting/etcd-io-saturation-control-plane-crash.md"
        exit 1
    fi

    # ── etcd Defragmentation Timer ─────────────────────────────────────
    # LEARNING NOTE — WHY PERIODIC DEFRAG:
    #   Kubernetes auto-compacts etcd (marks old revisions deletable) but
    #   never defrags (reclaims the space on disk). Over time the DB file
    #   grows with dead space — we've seen 90MB files with only 29MB of
    #   real data (68% waste). Every read/write scans the full file, so
    #   bloat directly increases I/O and etcd latency.
    #
    #   This timer runs compact + defrag weekly. It uses crictl exec to
    #   run etcdctl inside the etcd container, so it works without
    #   installing etcdctl on the host. The timer runs on the host (not
    #   as a K8s CronJob) because etcd issues can make K8s too unstable
    #   to schedule pods reliably.
    cat > /etc/systemd/system/etcd-defrag.service << 'SYSTEMD'
[Unit]
Description=Compact and defragment etcd
After=containerd.service

[Service]
Type=oneshot
SuccessExitStatus=75
ExecStart=/usr/local/bin/etcd-defrag.sh
SYSTEMD

    cat > /etc/systemd/system/etcd-defrag.timer << 'SYSTEMD'
[Unit]
Description=Weekly etcd defragmentation

[Timer]
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
SYSTEMD

    cat > /usr/local/bin/etcd-defrag.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail

CRICTL_STDERR=$(mktemp)
if ! ETCD_CONTAINER=$(crictl ps --name etcd -q 2>"$CRICTL_STDERR"); then
    echo "ERROR: crictl failed — container runtime may be unavailable" >&2
    [ -s "$CRICTL_STDERR" ] && echo "crictl stderr: $(cat "$CRICTL_STDERR")" >&2
    rm -f "$CRICTL_STDERR"
    exit 1
fi
[ -s "$CRICTL_STDERR" ] && echo "WARN: crictl stderr: $(cat "$CRICTL_STDERR")" >&2
rm -f "$CRICTL_STDERR"

if [ -z "$ETCD_CONTAINER" ]; then
    logger -p daemon.warning "etcd-defrag: container not found, skipping"
    echo "etcd container not found, skipping"
    # Exit 75 (EX_TEMPFAIL) so systemd distinguishes "skipped" from "success"
    exit 75
fi

CERTS="--endpoints=https://127.0.0.1:2379 \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
--cacert=/etc/kubernetes/pki/etcd/ca.crt"

# Get current revision and compact
ETCD_STDERR=$(mktemp)
REV=$(crictl exec "$ETCD_CONTAINER" etcdctl $CERTS endpoint status --write-out=json 2>"$ETCD_STDERR" \
    | jq -r '.[0].Status.header.revision') || {
    echo "ERROR: Failed to get etcd revision, skipping defrag" >&2
    [ -s "$ETCD_STDERR" ] && echo "etcdctl stderr: $(cat "$ETCD_STDERR")" >&2
    rm -f "$ETCD_STDERR"
    exit 1
}
rm -f "$ETCD_STDERR"
if [ -z "$REV" ] || [ "$REV" = "null" ]; then
    echo "ERROR: Failed to parse etcd revision from endpoint status" >&2
    exit 1
fi
echo "Compacting to revision $REV..."
crictl exec "$ETCD_CONTAINER" etcdctl $CERTS compact "$REV"

echo "Defragmenting..."
crictl exec "$ETCD_CONTAINER" etcdctl $CERTS defrag

echo "Status after defrag:"
crictl exec "$ETCD_CONTAINER" etcdctl $CERTS endpoint status --write-out=table
SCRIPT

    chmod +x /usr/local/bin/etcd-defrag.sh
    systemctl daemon-reload
    systemctl enable etcd-defrag.timer

    ok "etcd defrag timer installed (weekly, Sundays 04:00)"
else
    log "Skipping etcd disk setup (worker node)"
fi

# ── 9. Raspberry Pi Specific Configuration ─────────────────────────
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

# ── 10. Cleanup ─────────────────────────────────────────────────────
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
    if cloud-init clean --logs 2>&1; then
        ok "cloud-init state reset"
    else
        warn "cloud-init clean failed (image may retain stale state)"
    fi
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
echo "  Packages: open-iscsi, nfs-common, 1password-cli, jq, helm"
echo "  Configs:  kernel modules, sysctl, iscsid, kubelet DNS"
echo "  Role: ${NODE_ROLE} | Arch: ${NODE_ARCH}"
echo "═══════════════════════════════════════════════════"
