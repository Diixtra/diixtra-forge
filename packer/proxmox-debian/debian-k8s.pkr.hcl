# =============================================================================
# Packer Template — Debian 13 (Trixie) K8s Node (Proxmox)
# =============================================================================
#
# LEARNING NOTE — DEBIAN INSTALLER vs UBUNTU SUBIQUITY:
#   Debian uses the traditional Debian Installer (d-i), automated via
#   preseed files. Ubuntu Server 20.04+ uses Subiquity with autoinstall.
#   The key differences for Packer:
#     - Boot command: Debian uses `auto url=...` at the boot: prompt
#       Ubuntu uses kernel parameters in GRUB
#     - Config format: Debian uses flat key=value preseed
#       Ubuntu uses YAML autoinstall
#     - Both result in the same thing: an unattended OS installation
#
# USAGE:
#   packer validate -var-file="variables.auto.pkrvars.hcl" proxmox-debian/
#   packer build -var-file="variables.auto.pkrvars.hcl" proxmox-debian/

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# ── Variables ───────────────────────────────────────────────────────
variable "proxmox_api_url" {
  type        = string
  description = "Proxmox API endpoint URL"
}

variable "proxmox_api_token_id" {
  type        = string
  description = "Proxmox API token ID (format: user@realm!tokenname)"
}

variable "proxmox_api_token_secret" {
  type        = string
  description = "Proxmox API token secret"
  sensitive   = true
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name to build on"
}

variable "proxmox_iso_storage" {
  type        = string
  description = "Storage pool where ISOs are stored"
}

variable "proxmox_disk_storage" {
  type        = string
  description = "Storage pool for VM disks"
}

variable "debian_iso_file" {
  type        = string
  description = "Debian ISO filename as it appears in Proxmox"
}

variable "vm_id" {
  type        = number
  description = "Proxmox VM ID for the build VM (temporary)"
  default     = 9001
}

variable "template_name" {
  type        = string
  description = "Name for the resulting Proxmox template"
  default     = "k8s-debian-13"
}

variable "template_description" {
  type        = string
  description = "Description for the Proxmox template"
  default     = "K8s node golden image — Debian 13 (Trixie) — built by Packer"
}

variable "ssh_username" {
  type        = string
  description = "SSH user for Packer to connect during provisioning"
  default     = "packer"
}

variable "ssh_password" {
  type        = string
  description = "SSH password for the build user"
  default     = "packer"
  sensitive   = true
}

variable "vm_cores" {
  type        = number
  default     = 2
}

variable "vm_memory" {
  type        = number
  default     = 2048
}

variable "vm_disk_size" {
  type        = string
  default     = "32G"
}

variable "network_bridge" {
  type        = string
  default     = "vmbr0"
}

# ── Source ───────────────────────────────────────────────────────────
source "proxmox-iso" "debian-k8s" {
  # Proxmox connection
  proxmox_url              = var.proxmox_api_url
  username                 = var.proxmox_api_token_id
  token                    = var.proxmox_api_token_secret
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  # VM settings
  vm_id                = var.vm_id
  vm_name              = "packer-debian-build"
  template_name        = var.template_name
  template_description = var.template_description

  # ISO
  iso_file = "${var.proxmox_iso_storage}:iso/${var.debian_iso_file}"

  # Hardware
  cores    = var.vm_cores
  memory   = var.vm_memory
  cpu_type = "host"
  os       = "l26"
  bios     = "seabios"  # BIOS mode — Debian ISO uses isolinux

  scsi_controller = "virtio-scsi-single"

  disks {
    storage_pool = var.proxmox_disk_storage
    disk_size    = var.vm_disk_size
    type         = "scsi"
    discard      = true
    ssd          = true
  }

  network_adapters {
    bridge = var.network_bridge
    model  = "virtio"
  }

  qemu_agent = true

  cloud_init              = true
  cloud_init_storage_pool = var.proxmox_disk_storage

  # ── Boot Command ──────────────────────────────────────────────────
  # LEARNING NOTE — DEBIAN BOOT SEQUENCE:
  #   The Debian ISO (BIOS mode) uses isolinux as the bootloader. It
  #   shows a menu with "Install", "Graphical install", etc. Pressing
  #   <esc> drops to the boot: prompt where we can type the boot command.
  #
  #   `auto url=...` tells the installer to:
  #     1. Fetch the preseed file from our HTTP server
  #     2. Run in automated mode (skip confirmations)
  #
  #   `priority=critical` suppresses all questions except critical ones
  #   that the preseed doesn't answer — this prevents the installer from
  #   stopping to ask questions we forgot to preseed.
  #
  #   `interface=auto` tells the installer to pick the first network
  #   interface automatically (avoids a "which NIC?" prompt on multi-NIC VMs).
  boot_wait = "10s"
  boot_command = [
    "<esc><wait3>",
    "auto",
    " url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg",
    " priority=critical",
    " interface=auto",
    " hostname=k8s-debian-template",
    " domain=local",
    "<enter>"
  ]

  # HTTP server serves the preseed.cfg
  http_directory = "${path.root}/http"

  # SSH
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = "30m"
  ssh_handshake_attempts = 30
}

# ── Build ───────────────────────────────────────────────────────────
build {
  sources = ["source.proxmox-iso.debian-k8s"]

  provisioner "file" {
    source      = "${path.root}/../scripts/provision-k8s-node.sh"
    destination = "/tmp/provision-k8s-node.sh"
  }

  provisioner "shell" {
    inline = [
      "chmod +x /tmp/provision-k8s-node.sh",
      "sudo bash /tmp/provision-k8s-node.sh worker amd64",
      "rm -f /tmp/provision-k8s-node.sh",
    ]
  }
}
