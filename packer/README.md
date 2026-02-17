# Packer Golden Images

Pre-configured VM templates and Pi images for Kubernetes nodes. Every node
cloned from these images has all required packages pre-installed — no manual
SSH configuration needed.

## What This Solves

Without golden images, provisioning a new K8s node requires:

```
Download ISO → Install OS → SSH in → apt install open-iscsi → apt install
1password-cli → configure kernel modules → configure sysctl → enable iscsid
→ kubeadm join → hope you didn't forget anything → repeat for next node
```

With golden images:

```
Clone template → Boot → kubeadm join → done
```

The image is **immutable** — once built, it never changes. Every VM or Pi
booted from it is identical.

## Image Variants

| Template | OS | Target | Builder | Includes |
|----------|----|--------|---------|----------|
| `proxmox-ubuntu` | Ubuntu 25.10 | Control plane VM | proxmox-iso | Base K8s packages |
| `proxmox-debian` | Debian 13 | Worker VM | proxmox-iso | Base K8s packages |
| `proxmox-gpu` | Ubuntu 25.10 | GPU VM (standalone K3s) | proxmox-iso | Base + NVIDIA 570 + K3s |
| `arm-debian` | Debian 12 | Raspberry Pi 4/5 | arm-image | Base K8s packages (ARM64) |

### Shared Base Packages (all variants)

Installed by `scripts/provision-k8s-node.sh`:

- `open-iscsi` — iSCSI initiator for democratic-csi TrueNAS storage
- `nfs-common` — NFS client for democratic-csi NFS volumes
- `1password-cli` — Bootstrap secret creation, ops runbooks
- `jq` — JSON processing in scripts
- Kernel modules: `br_netfilter`, `overlay`
- sysctl: IP forwarding, bridge traffic filtering
- iscsid service enabled

### GPU Additional Packages

Installed by `scripts/provision-gpu-node.sh` (GPU template only):

- NVIDIA driver 570 (Blackwell architecture — RTX 5070 Ti)
- NVIDIA Container Toolkit (containerd GPU integration)
- K3s (single-node Kubernetes, installed but not started)
- Nouveau driver blacklisted
- First-boot script at `/usr/local/bin/gpu-node-init.sh`

## Prerequisites

### Build Host

```bash
# Packer (latest)
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install packer

# For Pi image builds only:
sudo apt install qemu-user-static binfmt-support kpartx
```

### Proxmox API Token

Packer authenticates to Proxmox via API token (not username/password).

1. In Proxmox UI: Datacenter → Permissions → API Tokens → Add
2. User: `root@pam` (or a dedicated `packer@pve` user)
3. Token ID: `packer-token`
4. **Uncheck** "Privilege Separation" (token inherits user's permissions)
5. Copy the token secret (shown only once)

Store in 1Password as `proxmox-packer-token` in the Homelab vault.

### TrueNAS Must Be Running

ISOs are stored on `nas-1` (NFS from TrueNAS). TrueNAS VM must be running
before Packer can access the ISOs.

## Usage

### 1. Initialise Plugins

```bash
cd packer

# Download plugins for all templates
packer init proxmox-ubuntu/
packer init proxmox-debian/
packer init proxmox-gpu/
packer init arm-debian/
```

### 2. Configure Variables

```bash
cp variables.auto.pkrvars.hcl.example variables.auto.pkrvars.hcl
# Edit with your Proxmox API token
```

Or inject from 1Password (recommended):

```bash
export PKR_VAR_proxmox_api_token_secret=$(op read "op://Homelab/proxmox-packer-token/credential")
```

### 3. Validate

```bash
packer validate -var-file="variables.auto.pkrvars.hcl" proxmox-ubuntu/
packer validate -var-file="variables.auto.pkrvars.hcl" proxmox-debian/
packer validate -var-file="variables.auto.pkrvars.hcl" proxmox-gpu/
packer validate arm-debian/  # Pi build uses defaults, no Proxmox vars needed
```

### 4. Build

```bash
# Build one template at a time (they use different VM IDs so won't conflict)
packer build -var-file="variables.auto.pkrvars.hcl" proxmox-ubuntu/
packer build -var-file="variables.auto.pkrvars.hcl" proxmox-debian/
packer build -var-file="variables.auto.pkrvars.hcl" proxmox-gpu/

# Pi image (runs on build host, not Proxmox)
sudo packer build arm-debian/
```

Build times (approximate):

| Template | Time | Why |
|----------|------|-----|
| proxmox-ubuntu | 15-25 min | OS install + base packages |
| proxmox-debian | 15-25 min | OS install + base packages |
| proxmox-gpu | 30-45 min | OS install + base + NVIDIA DKMS compilation |
| arm-debian | 20-40 min | QEMU emulation is slow |

### 5. Using the Templates

**Proxmox VMs**: Templates appear in the Proxmox UI. Right-click → Clone →
Full Clone. Resize CPU/RAM/disk as needed for the role.

**Raspberry Pi**: Flash the output image:
```bash
sudo dd if=output/k8s-pi-debian12.img of=/dev/sdX bs=4M status=progress
# Or use Raspberry Pi Imager → "Use custom" → select the .img file
```

**GPU VM post-clone**:
1. In Proxmox: VM → Hardware → Add → PCI Device → select the NVIDIA GPU
2. Set CPU type to "host", enable IOMMU in VM settings
3. Resize to production specs (8+ cores, 32GB+ RAM, 200GB+ disk)
4. Boot and run: `sudo gpu-node-init.sh`

## Directory Structure

```
packer/
├── .gitignore                           # Excludes secrets and build artifacts
├── variables.auto.pkrvars.hcl.example   # Template for variables (committed)
├── variables.auto.pkrvars.hcl           # Actual variables (gitignored)
│
├── scripts/                             # Shared provisioning scripts
│   ├── provision-k8s-node.sh            # Base packages (all variants)
│   └── provision-gpu-node.sh            # NVIDIA + K3s layer (GPU only)
│
├── proxmox-ubuntu/                      # Ubuntu 25.10 control plane
│   ├── ubuntu-k8s.pkr.hcl              # Packer template
│   └── http/autoinstall/               # Autoinstall config
│       ├── user-data                    # Installation answers
│       └── meta-data                    # Required empty file
│
├── proxmox-debian/                      # Debian 13 worker node
│   ├── debian-k8s.pkr.hcl              # Packer template
│   └── http/                           # Preseed config
│       └── preseed.cfg                  # Installation answers
│
├── proxmox-gpu/                         # GPU node (Ubuntu + NVIDIA + K3s)
│   ├── gpu-k8s.pkr.hcl                 # Packer template
│   └── http/autoinstall/               # Autoinstall config
│       ├── user-data                    # Same as Ubuntu + build-essential
│       └── meta-data                    # Required empty file
│
└── arm-debian/                          # Raspberry Pi (Debian 12 ARM64)
    └── pi-k8s.pkr.hcl                  # Packer template
```

## Rebuilding Images

Golden images should be rebuilt when:

- Packages are added to the provisioning scripts
- A new kernel or driver version is needed
- Security patches warrant a fresh base (monthly recommended)
- OS version changes (e.g., migrating from Ubuntu 25.10 to 26.04 LTS)

Packer is idempotent — running the same build again produces an identical
template. Existing VMs cloned from the old template are unaffected; only
new clones use the updated template.

## Troubleshooting

### Packer can't connect to Proxmox API

- Check `proxmox_api_url` includes `/api2/json` suffix
- Verify API token hasn't expired
- Ensure TLS verification matches (we use `insecure_skip_tls_verify = true`)

### SSH timeout during build

- OS installation may be slow on NFS storage — increase `ssh_timeout`
- Check Proxmox console for installer errors (stuck on a prompt = preseed/autoinstall issue)

### NVIDIA DKMS compilation fails (GPU template)

- Ensure `build-essential` and `linux-headers-generic` are in autoinstall packages
- Check the build VM has enough RAM (DKMS compilation needs ~2GB)

### Pi image build fails

- Ensure `qemu-user-static` and `binfmt-support` are installed on build host
- Run `sudo systemctl restart binfmt-support` if ARM emulation isn't working
- Pi builds must run as root (`sudo packer build`)
