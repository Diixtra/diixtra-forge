#!/usr/bin/env bash
# =============================================================================
# GPU Node Provisioning Script — NVIDIA + kubeadm Worker Layer
# =============================================================================
#
# PURPOSE:
#   Installs GPU-specific packages on top of the base K8s node image.
#   Run AFTER provision-k8s-node.sh. This script adds:
#     - NVIDIA driver (570+ for Blackwell/RTX 5070 Ti)
#     - NVIDIA Container Toolkit (lets containerd expose GPU to containers)
#     - First-boot script for kubeadm join + GPU taint/labels
#
#   kubeadm, kubelet, and kubectl are already installed by provision-k8s-node.sh.
#   This script does NOT install a separate Kubernetes distribution.
#
# LEARNING NOTE — WHY A SEPARATE SCRIPT:
#   The shared provision-k8s-node.sh handles packages every K8s node needs
#   (open-iscsi, nfs-common, 1password-cli, kernel modules, kubeadm/kubelet).
#   This script adds GPU-specific layers. Separation means:
#     - The base image works for CPU-only nodes
#     - The GPU image = base + this script
#     - Changes to GPU tooling don't require rebuilding all images
#   This is the same layering principle behind Docker multi-stage builds
#   and Kustomize overlays — share the common base, vary the specifics.
#
# LEARNING NOTE — WHY KUBEADM JOIN (NOT STANDALONE K3s):
#   Previously the GPU node ran a standalone K3s cluster. This meant:
#     - Separate Flux instance, separate 1Password operator, separate monitoring
#     - GPU only accessible to pods on that single node
#     - Two clusters to manage with different distributions
#
#   By joining the main kubeadm cluster as a worker:
#     - Any pod in the cluster can request nvidia.com/gpu resources
#     - Single Flux, single Alloy, single Kyverno, single 1Password operator
#     - GPU node gets all cluster security policies automatically
#     - Simpler operations — one cluster to manage
#
# LEARNING NOTE — GPU DURING PACKER BUILD:
#   The GPU is NOT present during the Packer build. Packer creates a
#   regular VM, installs packages, then converts to a template. PCI
#   passthrough happens AFTER you clone the template and configure the
#   new VM in Proxmox with the GPU device attached.
#
#   This means:
#     - NVIDIA driver installs but doesn't LOAD (no GPU hardware to bind to)
#     - nvidia-smi will fail during the build — that's expected
#     - On first boot of a cloned VM WITH the GPU passed through, the
#       driver loads automatically and nvidia-smi works
#
# USAGE (called by Packer, not manually):
#   sudo bash provision-gpu-node.sh
#
# =============================================================================

set -euo pipefail

echo "═══════════════════════════════════════════════════"
echo "  GPU Node Provisioning — NVIDIA + kubeadm Worker"
echo "═══════════════════════════════════════════════════"

# ── Helper Functions ────────────────────────────────────────────────
log() { echo "▸ $*"; }
ok()  { echo "  ✅ $*"; }
warn(){ echo "  ⚠️  $*"; }

export DEBIAN_FRONTEND=noninteractive

# ── 1. NVIDIA Driver ───────────────────────────────────────────────
# LEARNING NOTE — DRIVER INSTALLATION APPROACHES:
#   There are three ways to install NVIDIA drivers on Linux:
#
#   1. Distribution packages (apt install nvidia-driver-570)
#      Pros: Managed by apt, auto-updates with system, DKMS rebuilds
#        kernel module on kernel upgrades automatically.
#      Cons: May lag behind latest driver version.
#
#   2. NVIDIA .run installer (downloaded from nvidia.com)
#      Pros: Always latest version, NVIDIA's official binary.
#      Cons: Bypasses package manager, manual updates, breaks on kernel
#        upgrades (must reinstall), no automatic DKMS integration.
#
#   3. NVIDIA GPU Operator (Kubernetes DaemonSet)
#      Pros: Fully declarative, manages driver lifecycle in K8s.
#      Cons: Only works inside Kubernetes, can't use it for bare driver.
#
#   We use approach 1 (distribution packages) because:
#     - It integrates with apt (our existing update mechanism)
#     - DKMS automatically rebuilds the kernel module when the kernel
#       is upgraded (critical for unattended updates)
#     - The GPU Operator can OPTIONALLY manage drivers too, but having
#       the driver pre-installed in the image is more reliable
#
# LEARNING NOTE — DKMS (Dynamic Kernel Module Support):
#   The NVIDIA driver includes a kernel module (nvidia.ko) that must
#   match the running kernel version exactly. DKMS is a framework that
#   automatically recompiles out-of-tree kernel modules whenever a new
#   kernel is installed. Without DKMS, every `apt upgrade` that includes
#   a new kernel would break the NVIDIA driver until you manually rebuild.
#   With DKMS, it's automatic and transparent.
log "Installing NVIDIA driver..."

# Add the Ubuntu graphics drivers PPA for latest stable drivers
# LEARNING NOTE — WHY A PPA:
#   Ubuntu's default repositories often have older NVIDIA driver versions.
#   The graphics-drivers PPA is maintained by the Ubuntu desktop team and
#   tracks the latest stable NVIDIA drivers. For server/headless use,
#   we install the "-server" variant which omits X11/desktop components.
apt-get install -y -qq software-properties-common
add-apt-repository -y ppa:graphics-drivers/ppa
apt-get update -qq

# Install driver 570 (Blackwell architecture support — RTX 5070 Ti)
# LEARNING NOTE — DRIVER VERSIONS AND GPU ARCHITECTURES:
#   NVIDIA assigns driver version ranges to GPU architectures:
#     - Driver 525+: Ada Lovelace (RTX 4000 series)
#     - Driver 550+: Improved Ada support
#     - Driver 570+: Blackwell (RTX 5000 series) — REQUIRED for 5070 Ti
#   Installing an older driver on a newer GPU = the driver doesn't
#   recognise the PCI device ID and the GPU appears as "unknown device."
#
#   The -server variant skips X11, OpenGL desktop libs, and nvidia-settings
#   GUI. For a headless K8s node doing inference/training, you don't need
#   any of that — it's wasted disk space and attack surface.
apt-get install -y -qq \
    nvidia-driver-570-server \
    nvidia-utils-570-server \
    nvidia-dkms-570-server

ok "NVIDIA driver 570 installed (will activate on first boot with GPU)"

# ── 2. NVIDIA Container Toolkit ────────────────────────────────────
# LEARNING NOTE — WHAT THE CONTAINER TOOLKIT DOES:
#   The NVIDIA Container Toolkit (NCT) is the bridge between the GPU
#   driver and container runtimes (containerd, Docker, CRI-O). Without
#   it, containers can't see the GPU even if the host has a working driver.
#
#   How it works:
#   1. NCT installs a runtime hook (nvidia-container-runtime-hook)
#   2. When containerd starts a container requesting GPU access, it
#      calls the hook before the container process starts
#   3. The hook injects the necessary device files (/dev/nvidia0, etc.)
#      and driver libraries into the container's filesystem namespace
#   4. The container process sees the GPU as if it were on bare metal
#
#   This is why you can run `nvidia-smi` inside a container — the hook
#   mounted the GPU device and driver into the container's view.
#
#   Without NCT, you'd have to manually bind-mount /dev/nvidia0 and
#   all the driver .so files into every container — fragile and version-
#   dependent. NCT automates this completely.
log "Installing NVIDIA Container Toolkit..."

# Add NVIDIA container toolkit repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor --output /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

apt-get update -qq
apt-get install -y -qq nvidia-container-toolkit

ok "NVIDIA Container Toolkit installed"

# ── 3. Configure Container Toolkit for containerd ──────────────────
# LEARNING NOTE — RUNTIME CONFIGURATION:
#   The Container Toolkit needs to be registered with the container runtime.
#   `nvidia-ctk runtime configure` modifies containerd's config.toml to:
#     1. Register nvidia-container-runtime as an available runtime
#     2. Set it as the default runtime (so ALL containers get GPU access)
#   
#   Setting it as default means you don't need to specify the runtime
#   per-pod. Any container on this node automatically gets GPU access.
#   This is fine because this node is DEDICATED to GPU workloads (the
#   Kubernetes taint ensures only GPU-requesting pods are scheduled here).
#
#   We write the config but don't restart containerd (not running during
#   Packer build). It takes effect on first boot.
log "Configuring Container Toolkit for containerd..."

# Create containerd config directory
mkdir -p /etc/containerd

# Generate default config if it doesn't exist
if [ ! -f /etc/containerd/config.toml ]; then
    containerd config default > /etc/containerd/config.toml 2>/dev/null || true
fi

# Configure nvidia runtime as default
nvidia-ctk runtime configure --runtime=containerd --set-as-default 2>/dev/null || \
    warn "nvidia-ctk configure skipped (containerd not running during build — OK)"

ok "Container Toolkit configured for containerd"

# ── 4. Create First-Boot Script ────────────────────────────────────
# LEARNING NOTE — FIRST-BOOT PATTERN:
#   Some configuration can't happen in the Packer build because it
#   depends on runtime state (GPU present, network configured, etc.).
#   A first-boot script runs once after cloning and handles:
#     - Verify GPU is visible (nvidia-smi)
#     - Read kubeadm join credentials from 1Password
#     - Join the main cluster as a worker node
#     - Apply GPU-specific taints and labels
#
#   This script is idempotent — safe to run multiple times. It checks
#   whether each step has already been done before doing it.
log "Creating first-boot helper script..."

cat > /usr/local/bin/gpu-node-init.sh << 'FIRST_BOOT'
#!/usr/bin/env bash
# =============================================================================
# GPU Node First-Boot Initialisation — kubeadm join
# =============================================================================
# Run this once after cloning the template and attaching the GPU via passthrough.
# Verifies the GPU, reads kubeadm join credentials from 1Password, joins the
# main cluster, and applies GPU-specific node labels and taints.
#
# Prerequisites:
#   - GPU passed through via Proxmox PCI passthrough
#   - 1Password item "kubeadm-join-credentials" in the Homelab vault with:
#       token            kubeadm bootstrap token (abcdef.0123456789abcdef)
#       ca-cert-hash     sha256:<64-hex-chars>
#       api-server       control plane address (10.2.0.X:6443)
#       kubeconfig       admin kubeconfig for applying labels/taints
#   - OP_SERVICE_ACCOUNT_TOKEN exported in the environment
#
# Usage: sudo -E gpu-node-init.sh

set -euo pipefail

log() { echo "▸ $*"; }
ok()  { echo "  ✅ $*"; }
err() { echo "  ❌ $*"; exit 1; }
warn(){ echo "  ⚠️  $*"; }

# Ensure sensitive files and variables are cleaned up on any exit
cleanup() {
    rm -f "/tmp/gpu-init-kubeconfig"
    unset JOIN_TOKEN CA_CERT_HASH API_SERVER KUBECONFIG_CONTENT 2>/dev/null || true
}
trap cleanup EXIT

echo "═══════════════════════════════════════════════════"
echo "  GPU Node First-Boot Initialisation (kubeadm)"
echo "═══════════════════════════════════════════════════"

# ── 1. Verify GPU ──────────────────────────────────────────────────
log "Checking NVIDIA GPU..."
if nvidia-smi &>/dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
    GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -1)
    ok "GPU detected: ${GPU_NAME} (${GPU_VRAM})"
else
    err "No NVIDIA GPU detected. Check PCI passthrough configuration in Proxmox."
fi

# ── 2. Read join credentials from 1Password ────────────────────────
# LEARNING NOTE — WHY 1PASSWORD FOR JOIN CREDENTIALS:
#   kubeadm join tokens contain enough material to join a node to the
#   cluster as a trusted worker. Passing them via cloud-init user-data
#   is insecure (visible in Proxmox VM config). 1Password keeps them
#   out of the image, out of Git, and out of Proxmox.
#
#   To refresh the token before booting a new node:
#     kubeadm token create --print-join-command
#     op item edit kubeadm-join-credentials --vault Homelab token=<new>
log "Reading kubeadm join credentials from 1Password..."

if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    err "OP_SERVICE_ACCOUNT_TOKEN not set. Export it before running this script."
fi

JOIN_TOKEN=$(op read "op://Homelab/kubeadm-join-credentials/token" 2>/dev/null) \
    || err "Failed to read join token from 1Password."
CA_CERT_HASH=$(op read "op://Homelab/kubeadm-join-credentials/ca-cert-hash" 2>/dev/null) \
    || err "Failed to read CA cert hash from 1Password."
API_SERVER=$(op read "op://Homelab/kubeadm-join-credentials/api-server" 2>/dev/null) \
    || err "Failed to read API server endpoint from 1Password."

ok "Join credentials retrieved from 1Password"

# ── 3. kubeadm join ────────────────────────────────────────────────
if [ -f /etc/kubernetes/kubelet.conf ]; then
    ok "Node already joined (kubelet.conf exists). Skipping kubeadm join."
else
    log "Joining cluster at ${API_SERVER}..."
    kubeadm join "${API_SERVER}" \
        --token "${JOIN_TOKEN}" \
        --discovery-token-ca-cert-hash "${CA_CERT_HASH}" \
        --node-name "$(hostname)"
    ok "kubeadm join completed"
fi

# ── 4. Wait for kubelet ────────────────────────────────────────────
log "Waiting for kubelet to become active..."
TIMEOUT=120
ELAPSED=0
while ! systemctl is-active --quiet kubelet; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
        err "kubelet failed to start within ${TIMEOUT}s. Check: journalctl -u kubelet"
    fi
done
ok "kubelet is active"

# ── 5. Set up kubeconfig for label/taint operations ────────────────
# LEARNING NOTE — WHY A SEPARATE KUBECONFIG:
#   After kubeadm join, the node's kubelet has only bootstrap-level
#   permissions. It can register the node but can't set labels or taints.
#   We need an admin kubeconfig to apply those. The kubeconfig is stored
#   in 1Password alongside the join credentials.
log "Fetching admin kubeconfig from 1Password..."
KUBECONFIG_CONTENT=$(op read "op://Homelab/kubeadm-join-credentials/kubeconfig" 2>/dev/null) \
    || err "Failed to read kubeconfig from 1Password."

export KUBECONFIG="/tmp/gpu-init-kubeconfig"
echo "${KUBECONFIG_CONTENT}" > "${KUBECONFIG}"
chmod 600 "${KUBECONFIG}"

NODE_NAME=$(hostname)

# Wait for node to appear in the cluster
log "Waiting for node ${NODE_NAME} to be registered..."
TIMEOUT=180
ELAPSED=0
while ! kubectl get node "${NODE_NAME}" &>/dev/null; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
        err "Node ${NODE_NAME} not registered after ${TIMEOUT}s."
    fi
done
ok "Node ${NODE_NAME} is registered"

# ── 6. Apply Node Taint ───────────────────────────────────────────
log "Applying GPU node taint..."
TAINT_EXISTS=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.spec.taints}' 2>/dev/null | grep -c "nvidia.com/gpu" || true)
if [ "${TAINT_EXISTS}" -gt 0 ]; then
    ok "GPU taint already applied"
else
    kubectl taint nodes "${NODE_NAME}" nvidia.com/gpu=present:NoSchedule
    ok "Taint applied: nvidia.com/gpu=present:NoSchedule"
fi

# ── 7. Apply Node Labels ──────────────────────────────────────────
log "Applying node labels..."
kubectl label nodes "${NODE_NAME}" \
    node.kubernetes.io/gpu=true \
    "nvidia.com/gpu.product=${GPU_NAME// /-}" \
    --overwrite
ok "Node labels applied"

echo ""
echo "═══════════════════════════════════════════════════"
echo "  ✅ GPU node joined to main cluster"
echo "  GPU:      ${GPU_NAME} (${GPU_VRAM})"
echo "  Cluster:  ${API_SERVER}"
echo ""
echo "  Next steps:"
echo "    1. Verify node joined:  kubectl get nodes"
echo "    2. Flux will deploy nvidia-device-plugin automatically."
echo "    3. Verify GPU resource (~2 min after device plugin starts):"
echo "       kubectl get node ${NODE_NAME} -o jsonpath='{.status.allocatable}'"
echo "═══════════════════════════════════════════════════"
FIRST_BOOT

chmod +x /usr/local/bin/gpu-node-init.sh
ok "First-boot script created at /usr/local/bin/gpu-node-init.sh"

# ── 5. Blacklist Nouveau Driver ────────────────────────────────────
# LEARNING NOTE — NOUVEAU vs NVIDIA PROPRIETARY:
#   Linux ships with an open-source NVIDIA driver called "nouveau."
#   It provides basic display output but has zero compute/CUDA support —
#   useless for ML workloads. Worse, if nouveau loads first, it claims
#   the GPU and the proprietary NVIDIA driver can't bind to it.
#
#   Blacklisting nouveau ensures the NVIDIA proprietary driver always
#   wins the race to claim the GPU on boot. This is one of the most
#   common causes of "nvidia-smi: command not found" or "no devices
#   were found" errors — nouveau grabbed the GPU first.
log "Blacklisting nouveau driver..."

cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
# Prevent the open-source nouveau driver from loading.
# The proprietary NVIDIA driver is required for CUDA/compute workloads.
blacklist nouveau
options nouveau modeset=0
EOF

# Rebuild initramfs so the blacklist takes effect during early boot
update-initramfs -u 2>/dev/null || warn "initramfs update skipped (OK during Packer build)"
ok "Nouveau driver blacklisted"

# ── 6. Cleanup ──────────────────────────────────────────────────────
log "Cleaning up..."
apt-get autoremove -y -qq
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*

echo ""
echo "═══════════════════════════════════════════════════"
echo "  ✅ GPU provisioning complete"
echo "  NVIDIA driver:     570 (Blackwell support)"
echo "  Container Toolkit: installed"
echo "  K8s:               kubeadm/kubelet (from base image)"
echo "  First-boot:        /usr/local/bin/gpu-node-init.sh"
echo ""
echo "  After cloning this template in Proxmox:"
echo "    1. Attach GPU via PCI passthrough"
echo "    2. Ensure 1Password item 'kubeadm-join-credentials' is current"
echo "    3. Boot the VM, set OP_SERVICE_ACCOUNT_TOKEN"
echo "    4. Run: sudo -E gpu-node-init.sh"
echo "═══════════════════════════════════════════════════"
