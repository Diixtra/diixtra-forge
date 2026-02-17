#!/usr/bin/env bash
# =============================================================================
# GPU Node Provisioning Script — NVIDIA + K3s Layer
# =============================================================================
#
# PURPOSE:
#   Installs GPU-specific packages on top of the base K8s node image.
#   Run AFTER provision-k8s-node.sh. This script adds:
#     - NVIDIA driver (570+ for Blackwell/RTX 5070 Ti)
#     - NVIDIA Container Toolkit (lets containerd expose GPU to containers)
#     - K3s (lightweight single-node Kubernetes)
#
# LEARNING NOTE — WHY A SEPARATE SCRIPT:
#   The shared provision-k8s-node.sh handles packages every K8s node needs
#   (open-iscsi, nfs-common, 1password-cli, kernel modules). This script
#   adds GPU-specific layers. Separation means:
#     - The base image works for CPU-only nodes
#     - The GPU image = base + this script
#     - Changes to GPU tooling don't require rebuilding all images
#   This is the same layering principle behind Docker multi-stage builds
#   and Kustomize overlays — share the common base, vary the specifics.
#
# LEARNING NOTE — WHY K3s AND NOT KUBEADM:
#   The main cluster uses kubeadm because it's multi-node with separate
#   control plane and workers. The GPU VM is a single-node standalone
#   cluster — K3s is purpose-built for this:
#     - Single binary (~70MB), runs control plane + worker in one process
#     - Embedded etcd (no external datastore needed)
#     - Bundled containerd, Flannel, CoreDNS, local-path-provisioner
#     - ~400MB RAM overhead vs ~1.5GB for full kubeadm control plane
#     - CNCF certified — same Kubernetes API, same kubectl, same Flux
#
#   From Flux's perspective, K3s and kubeadm are identical. The same
#   HelmReleases, Kustomizations, and GitOps workflows work on both.
#   The only difference is how the cluster was bootstrapped.
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
echo "  GPU Node Provisioning — NVIDIA + K3s"
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

# Create containerd config directory (K3s will use this)
mkdir -p /etc/containerd

# Generate default config if it doesn't exist
if [ ! -f /etc/containerd/config.toml ]; then
    containerd config default > /etc/containerd/config.toml 2>/dev/null || true
fi

# Configure nvidia runtime as default
nvidia-ctk runtime configure --runtime=containerd --set-as-default 2>/dev/null || \
    warn "nvidia-ctk configure skipped (containerd not running during build — OK)"

ok "Container Toolkit configured for containerd"

# ── 4. K3s Installation ────────────────────────────────────────────
# LEARNING NOTE — K3s INSTALL BUT DON'T START:
#   We install K3s during the Packer build but DON'T start it. Why?
#
#   K3s generates cluster-specific data on first start:
#     - TLS certificates (unique per cluster)
#     - Cluster CA (the certificate authority that signs all certs)
#     - Node token (for joining additional nodes)
#     - etcd database (the cluster state store)
#
#   If K3s starts during the Packer build, all that data gets baked
#   into the image. Every VM cloned from the template would share the
#   same CA, same certs, same cluster identity — a security disaster
#   and a functional failure (multiple clusters thinking they're the same).
#
#   Instead, we install the binary and systemd service, but disable
#   automatic start. On first boot of a cloned VM, you run:
#     systemctl enable k3s && systemctl start k3s
#   K3s generates fresh cluster identity and starts cleanly.
#
# LEARNING NOTE — K3s INSTALL SCRIPT:
#   K3s provides a curl-pipe-bash installer (https://get.k3s.io) that:
#     1. Detects architecture (amd64/arm64)
#     2. Downloads the correct binary
#     3. Creates systemd service files
#     4. Optionally starts the service
#
#   INSTALL_K3S_SKIP_START=true prevents it from starting.
#   INSTALL_K3S_SKIP_ENABLE=true prevents systemd from starting it on boot.
#   We want the binary and service files installed, but the service OFF
#   until the cloned VM is configured.
log "Installing K3s..."

curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true sh -s - \
    --write-kubeconfig-mode "0644"

# Verify K3s binary is installed
if command -v k3s &> /dev/null; then
    ok "K3s installed: $(k3s --version | head -1)"
else
    echo "  ❌ K3s installation failed"
    exit 1
fi

# ── 5. K3s NVIDIA Integration Config ───────────────────────────────
# LEARNING NOTE — K3s CONTAINERD CONFIG:
#   K3s bundles its own containerd (doesn't use the system containerd).
#   To tell K3s's containerd about the NVIDIA runtime, we create a
#   config template at /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl
#
#   The .tmpl extension is important — K3s treats this as a TEMPLATE
#   that it merges with its own generated config. A plain config.toml
#   would be overwritten by K3s on every start. The .tmpl is preserved.
log "Configuring K3s for NVIDIA runtime..."

K3S_CONTAINERD_DIR="/var/lib/rancher/k3s/agent/etc/containerd"
mkdir -p "${K3S_CONTAINERD_DIR}"

cat > "${K3S_CONTAINERD_DIR}/config.toml.tmpl" << 'CONTAINERD_CONFIG'
# K3s containerd configuration template
# This is merged with K3s's generated config on each start.

[plugins."io.containerd.grpc.v1.cri".containerd]
  default_runtime_name = "nvidia"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
  privileged_without_host_devices = false
  runtime_engine = ""
  runtime_root = ""
  runtime_type = "io.containerd.runc.v2"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
  BinaryName = "/usr/bin/nvidia-container-runtime"
CONTAINERD_CONFIG

ok "K3s NVIDIA containerd config template created"

# ── 6. Create First-Boot Script ────────────────────────────────────
# LEARNING NOTE — FIRST-BOOT PATTERN:
#   Some configuration can't happen in the Packer build because it
#   depends on runtime state (GPU present, network configured, etc.).
#   A first-boot script runs once after cloning and handles:
#     - Verify GPU is visible (nvidia-smi)
#     - Enable and start K3s
#     - Wait for K3s to be ready
#     - Apply GPU-specific K8s resources (taint, labels)
#
#   This script is idempotent — safe to run multiple times. It checks
#   whether each step has already been done before doing it.
log "Creating first-boot helper script..."

cat > /usr/local/bin/gpu-node-init.sh << 'FIRST_BOOT'
#!/usr/bin/env bash
# =============================================================================
# GPU Node First-Boot Initialisation
# =============================================================================
# Run this once after cloning the template and attaching the GPU via passthrough.
# It verifies the GPU, starts K3s, and applies node configuration.
#
# Usage: sudo gpu-node-init.sh

set -euo pipefail

log() { echo "▸ $*"; }
ok()  { echo "  ✅ $*"; }
err() { echo "  ❌ $*"; exit 1; }

echo "═══════════════════════════════════════════════════"
echo "  GPU Node First-Boot Initialisation"
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

# ── 2. Start K3s ───────────────────────────────────────────────────
log "Enabling and starting K3s..."
if systemctl is-active --quiet k3s; then
    ok "K3s already running"
else
    systemctl enable k3s
    systemctl start k3s

    # Wait for K3s to be ready (API server accepting connections)
    log "Waiting for K3s API server..."
    TIMEOUT=120
    ELAPSED=0
    while ! k3s kubectl get nodes &>/dev/null; do
        sleep 5
        ELAPSED=$((ELAPSED + 5))
        if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
            err "K3s failed to start within ${TIMEOUT}s. Check: journalctl -u k3s"
        fi
    done
    ok "K3s is running"
fi

# ── 3. Verify GPU in K3s ──────────────────────────────────────────
# The NVIDIA device plugin needs time to register the GPU resource.
# K3s auto-detects the NVIDIA runtime and deploys the device plugin.
log "Waiting for GPU resource registration..."
TIMEOUT=120
ELAPSED=0
while true; do
    GPU_COUNT=$(k3s kubectl get node "$(hostname)" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
    if [ "${GPU_COUNT}" != "0" ] && [ -n "${GPU_COUNT}" ]; then
        ok "GPU registered in Kubernetes: nvidia.com/gpu=${GPU_COUNT}"
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
        warn "GPU not yet registered after ${TIMEOUT}s"
        warn "This may require the NVIDIA GPU Operator or device plugin"
        warn "Deploy via Flux: infrastructure/gpu-server/nvidia-device-plugin/"
        break
    fi
done

# ── 4. Apply Node Taint ───────────────────────────────────────────
log "Applying GPU node taint..."
NODE_NAME=$(hostname)
TAINT_EXISTS=$(k3s kubectl get node "${NODE_NAME}" -o jsonpath='{.spec.taints}' 2>/dev/null | grep -c "nvidia.com/gpu" || true)
if [ "${TAINT_EXISTS}" -gt 0 ]; then
    ok "GPU taint already applied"
else
    k3s kubectl taint nodes "${NODE_NAME}" nvidia.com/gpu=present:NoSchedule
    ok "Taint applied: nvidia.com/gpu=present:NoSchedule"
fi

# ── 5. Apply Node Labels ──────────────────────────────────────────
log "Applying node labels..."
k3s kubectl label nodes "${NODE_NAME}" \
    node.kubernetes.io/gpu=true \
    nvidia.com/gpu.product="${GPU_NAME// /-}" \
    --overwrite
ok "Node labels applied"

echo ""
echo "═══════════════════════════════════════════════════"
echo "  ✅ GPU node initialised"
echo "  GPU:  ${GPU_NAME} (${GPU_VRAM})"
echo "  K3s:  $(k3s --version | head -1)"
echo ""
echo "  Next steps:"
echo "    1. Bootstrap Flux on this cluster:"
echo "       flux bootstrap github --owner=Diixtra \\"
echo "         --repository=diixtra-forge --branch=main \\"
echo "         --path=clusters/gpu-server --personal=false --token-auth"
echo "    2. Create 1Password bootstrap secret:"
echo "       kubectl create secret generic onepassword-service-account-token \\"
echo "         --namespace onepassword-system \\"
echo "         --from-literal=token=\$(op read 'op://Homelab/<item>/credential')"
echo "═══════════════════════════════════════════════════"
FIRST_BOOT

chmod +x /usr/local/bin/gpu-node-init.sh
ok "First-boot script created at /usr/local/bin/gpu-node-init.sh"

# ── 7. Blacklist Nouveau Driver ────────────────────────────────────
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

# ── 8. Cleanup ──────────────────────────────────────────────────────
log "Cleaning up..."
apt-get autoremove -y -qq
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*

echo ""
echo "═══════════════════════════════════════════════════"
echo "  ✅ GPU provisioning complete"
echo "  NVIDIA driver:    570 (Blackwell support)"
echo "  Container Toolkit: installed"
echo "  K3s:              installed (not started)"
echo "  First-boot:       /usr/local/bin/gpu-node-init.sh"
echo ""
echo "  After cloning this template in Proxmox:"
echo "    1. Attach GPU via PCI passthrough"
echo "    2. Boot the VM"
echo "    3. Run: sudo gpu-node-init.sh"
echo "═══════════════════════════════════════════════════"
