# GPU PCI Passthrough — Proxmox Host Crash & "No NVIDIA GPU Found"

**Date**: 2026-02-26
**Status**: Resolved
**Impact**: GPU VM could not detect the NVIDIA RTX 5070 Ti. Multiple Proxmox host crashes during troubleshooting.

## Environment

- **Proxmox host**: AMD 16-core CPU (no integrated graphics), single GPU (RTX 5070 Ti)
- **GPU**: NVIDIA GeForce RTX 5070 Ti (GB203) — PCI `0000:04:00.0` (VGA) + `0000:04:00.1` (Audio)
- **PCI IDs**: `10de:2c05` (VGA), `10de:22e9` (Audio)
- **GPU VM**: Built from Packer template `k8s-gpu-ubuntu-2510` (Ubuntu 25.10 + NVIDIA driver 570 + kubeadm)
- **Kernel**: `6.17.9-1-pve`

## Symptoms

1. GPU VM boots but `nvidia-smi` reports "No NVIDIA GPU found"
2. VM config appeared correct: `hostpci0: 0000:04:00,pcie=1,x-vga=1`

## Root Cause (multi-layered)

### Problem 1: GPU not bound to vfio-pci on the host

The Proxmox host had no VFIO configuration. The GPU's VGA function had no driver loaded (but `nouveau` and `nvidiafb` kernel modules were available), and the audio function was claimed by `snd_hda_intel`. Without `vfio-pci` owning both devices, Proxmox cannot pass them to a VM.

**Before fix:**
```
04:00.0 VGA compatible controller — Kernel modules: nvidiafb, nouveau (no driver in use)
04:00.1 Audio device — Kernel driver in use: snd_hda_intel
```

### Problem 2: Host crashes when vfio-pci binds at boot (single-GPU system)

Initial fix attempt: bind `vfio-pci` to both devices at boot via `/etc/modprobe.d/vfio.conf` + `/etc/modules-load.d/vfio.conf`. This caused the Proxmox host to crash immediately when the VM started.

**Why:** With only one GPU in the system, the host's framebuffer/console depends on it. When `vfio-pci` claims the GPU at boot, the kernel framebuffer loses its display device. Starting the VM then triggers a kernel panic.

The `x-vga=1` flag made it worse — it tells QEMU to use the passthrough GPU as the VM's primary display, which requires exclusive access and conflicts with any host framebuffer usage.

### Problem 3: x-vga=1 unnecessary for headless compute

The GPU VM is a headless Kubernetes worker node for ML inference. It doesn't need the GPU as a display device — only as a compute device. `x-vga=1` was unnecessary and contributed to the crashes.

## Resolution

The fix required three changes applied together:

### 1. Remove x-vga=1 from VM config

```bash
qm set <VMID> -hostpci0 0000:04:00,pcie=1
```

### 2. Blacklist competing drivers (persistent)

```bash
# /etc/modprobe.d/blacklist-gpu.conf on Proxmox host
blacklist nouveau
blacklist nvidiafb
blacklist snd_hda_intel
```

This prevents any host driver from claiming the GPU, leaving it unclaimed and available for passthrough.

### 3. Do NOT auto-bind vfio-pci at boot

On a single-GPU system, do **not** create `/etc/modprobe.d/vfio.conf` with device IDs or `/etc/modules-load.d/vfio.conf`. These files were removed:

```bash
rm -f /etc/modprobe.d/vfio.conf
rm -f /etc/modules-load.d/vfio.conf
```

Proxmox automatically binds `vfio-pci` on demand when a VM with `hostpci` config starts. This avoids the boot-time conflict.

### 4. Add nomodeset to kernel parameters

```bash
# /etc/default/grub on Proxmox host
GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt pcie_acs_override=downstream,multifunction nomodeset"
```

`nomodeset` prevents the kernel from initialising a framebuffer driver for the GPU during boot. On a headless server with no integrated graphics, this is essential to prevent the kernel from panicking when the GPU is handed to a VM.

Applied with:
```bash
update-grub
update-initramfs -u -k all
reboot
```

### Final host state (working)

```
04:00.0 VGA compatible controller — Kernel modules: nvidiafb, nouveau (no driver in use)
04:00.1 Audio device — Kernel modules: snd_hda_intel (no driver in use)
```

No driver claims the GPU at boot. Proxmox binds `vfio-pci` on demand when the VM starts.

## Key Lessons

| Lesson | Detail |
|--------|--------|
| **Single-GPU passthrough is different** | Most guides assume multi-GPU (host keeps one, passes one). With a single GPU, you must avoid any host driver or framebuffer touching it. |
| **Don't auto-bind vfio-pci on single-GPU** | Let Proxmox bind on demand. Auto-binding at boot causes framebuffer panics. |
| **nomodeset is essential for headless single-GPU** | Without it, the kernel tries to set up a framebuffer on the only GPU, then panics when it's taken away. |
| **x-vga=1 is for display passthrough only** | For headless compute VMs (K8s GPU workers), omit it. The VM accesses the GPU via NVIDIA driver + CUDA, not as a display. |
| **Blacklist drivers on the host, not just the VM** | The Packer image already blacklists nouveau inside the VM. But the Proxmox host also needs `nouveau`, `nvidiafb`, and `snd_hda_intel` blacklisted to prevent them from claiming the GPU before passthrough. |
| **heredocs can fail over SSH** | When creating config files remotely, `echo` with `>>` append is more reliable than `cat << EOF` heredocs which can break in nested SSH sessions. |

## Files Modified (Proxmox Host)

| File | Purpose |
|------|---------|
| `/etc/modprobe.d/blacklist-gpu.conf` | Blacklists nouveau, nvidiafb, snd_hda_intel |
| `/etc/default/grub` | Kernel params: iommu, pcie_acs_override, nomodeset |

## Files Removed (Proxmox Host)

| File | Why |
|------|-----|
| `/etc/modprobe.d/vfio.conf` | Auto-binding vfio-pci at boot crashes single-GPU hosts |
| `/etc/modules-load.d/vfio.conf` | Same reason — don't load vfio modules at boot |

## Verification

After reboot, confirm GPU is unclaimed on the host:
```bash
lspci -nnk -s 04:00
# Both devices should show no "Kernel driver in use"
```

Start the VM and verify inside it:
```bash
nvidia-smi
# Should detect RTX 5070 Ti
```

Then proceed with the first-boot script:
```bash
sudo -E gpu-node-init.sh
```
