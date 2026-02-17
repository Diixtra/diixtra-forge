# =============================================================================
# Packer Template — Debian 12 K8s Node (Raspberry Pi ARM64)
# =============================================================================
#
# LEARNING NOTE — HOW ARM IMAGE BUILDING WORKS:
#   Raspberry Pis are bare metal — no hypervisor API to call. Instead of
#   booting a VM from an ISO, we:
#     1. Download the official Raspberry Pi OS (Debian 12) base image
#     2. Mount the .img file as a loop device on the build host
#     3. Use QEMU user-mode emulation to "chroot" into the ARM filesystem
#     4. Run commands inside (they execute via ARM → x86 translation)
#     5. Unmount and output the modified .img file
#
#   The result is a .img file you flash onto an SD card or USB drive
#   using Raspberry Pi Imager. Every Pi booted from this image has all
#   packages pre-installed.
#
# LEARNING NOTE — QEMU USER-MODE EMULATION:
#   Your build host is x86_64, but the Pi image contains ARM64 binaries.
#   Normally you can't run ARM binaries on x86. QEMU user-mode emulation
#   (qemu-user-static) registers itself with the Linux kernel's binfmt_misc
#   system to transparently translate ARM instructions to x86 at runtime.
#   When you `chroot` into the mounted image and run `apt install`, the
#   ARM64 `apt` binary runs on your x86 machine via QEMU translation.
#
#   This is slow (5-10x slower than native) but it works. The alternative
#   would be building ON a Pi, which is even slower due to limited CPU/RAM.
#
# BUILD HOST PREREQUISITES:
#   sudo apt install qemu-user-static binfmt-support kpartx
#   # These must be installed on the machine running `packer build`
#
# USAGE:
#   packer validate -var-file="variables.auto.pkrvars.hcl" arm-debian/
#   packer build -var-file="variables.auto.pkrvars.hcl" arm-debian/
#   # Then flash: sudo dd if=output/k8s-pi-debian12.img of=/dev/sdX bs=4M status=progress

packer {
  required_plugins {
    arm-image = {
      version = ">= 0.2.7"
      source  = "github.com/solo-io/arm-image"
    }
  }
}

# ── Variables ───────────────────────────────────────────────────────
variable "pi_base_image_url" {
  type        = string
  description = "URL to the base Raspberry Pi OS image (xz compressed)"
  # Raspberry Pi OS Lite (Debian 12, ARM64) — no desktop, minimal
  default     = "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-11-19/2024-11-19-raspios-bookworm-arm64-lite.img.xz"
}

variable "pi_base_image_checksum" {
  type        = string
  description = "SHA256 checksum of the base image"
  # Verify at: https://www.raspberrypi.com/software/operating-systems/
  default     = ""
}

variable "pi_output_image" {
  type        = string
  description = "Output path for the customised image"
  default     = "output/k8s-pi-debian12.img"
}

variable "pi_image_size" {
  type        = string
  description = "Expand the image to this size (must be larger than base)"
  # 4G gives room for packages; the filesystem auto-expands on first boot
  default     = "4G"
}

# ── Source ───────────────────────────────────────────────────────────
# LEARNING NOTE — ARM-IMAGE SOURCE:
#   Unlike proxmox-iso which creates a VM, arm-image works entirely with
#   files on disk. It downloads the .img, mounts it, chroots in, runs
#   provisioners, and unmounts. No network boot, no SSH, no VM. The
#   provisioners execute directly inside the chroot via QEMU emulation.
source "arm-image" "pi-k8s" {
  image_type      = "raspberrypi"
  iso_url         = var.pi_base_image_url
  iso_checksum    = var.pi_base_image_checksum != "" ? var.pi_base_image_checksum : "none"
  output_filename = var.pi_output_image
  target_image_size = parseint(replace(var.pi_image_size, "G", ""), 10) * 1024 * 1024 * 1024

  # LEARNING NOTE — QEMU BINARY:
  #   The plugin needs to know where the QEMU static binary is so it can
  #   copy it into the chroot. This binary stays in the image during the
  #   build and is removed at the end. Without it, ARM commands can't
  #   execute on the x86 build host.
  qemu_binary = "/usr/bin/qemu-aarch64-static"
}

# ── Build ───────────────────────────────────────────────────────────
build {
  sources = ["source.arm-image.pi-k8s"]

  # Enable SSH on first boot (Pi OS disables it by default since 2022)
  # LEARNING NOTE — PI SSH SECURITY CHANGE:
  #   Raspberry Pi OS disabled SSH by default in April 2022 for security.
  #   To re-enable, you either use Pi Imager's settings or create an
  #   empty file called "ssh" on the boot partition. In a Packer build,
  #   we enable the systemd service directly.
  provisioner "shell" {
    inline = [
      "systemctl enable ssh",
    ]
  }

  # Copy and run the shared provisioning script
  provisioner "file" {
    source      = "${path.root}/../scripts/provision-k8s-node.sh"
    destination = "/tmp/provision-k8s-node.sh"
  }

  provisioner "shell" {
    inline = [
      "chmod +x /tmp/provision-k8s-node.sh",
      "bash /tmp/provision-k8s-node.sh worker arm64",
      "rm /tmp/provision-k8s-node.sh",
    ]
  }
}
