# =============================================================================
# Packer Template — Ubuntu 25.10 K8s Node (Proxmox)
# =============================================================================
#
# LEARNING NOTE — HCL2 FORMAT:
#   Packer originally used JSON templates, but migrated to HCL2 (the same
#   language Terraform uses) for better readability, variable support, and
#   conditional logic. HCL2 templates use the `.pkr.hcl` extension.
#   The structure is:
#     packer {}         — plugin requirements (like Terraform providers)
#     variable {}       — input parameters
#     source {}         — builder configuration (WHERE to build)
#     build {}          — provisioners and post-processors (WHAT to install)
#
# LEARNING NOTE — WHY proxmox-iso AND NOT proxmox-clone:
#   proxmox-iso: Boots from an ISO, runs the full installer, captures result.
#     Use when: Building the FIRST template from scratch.
#   proxmox-clone: Clones an existing template, runs provisioners on it.
#     Use when: Layering changes on TOP of an existing template.
#
#   We use proxmox-iso because we're building the golden image from scratch.
#   Once this template exists, Terraform uses proxmox-clone to stamp out
#   identical VMs from it.
#
# USAGE:
#   # Validate the template:
#   packer validate -var-file="variables.auto.pkrvars.hcl" proxmox-ubuntu/
#
#   # Build the image:
#   packer build -var-file="variables.auto.pkrvars.hcl" proxmox-ubuntu/
#

# ── Plugin Requirements ─────────────────────────────────────────────
# LEARNING NOTE — PACKER PLUGINS:
#   Like Terraform providers, Packer plugins are separate binaries that
#   implement builder/provisioner logic. The `packer init` command downloads
#   them. The Proxmox plugin talks to the Proxmox API to create VMs,
#   attach ISOs, and convert to templates.
packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# ── Variables ───────────────────────────────────────────────────────
# LEARNING NOTE — VARIABLE TYPES IN PACKER:
#   Variables can have defaults, be overridden via -var flags, .pkrvars.hcl
#   files, or environment variables (PKR_VAR_name). Sensitive variables
#   (passwords, tokens) are marked `sensitive = true` which prevents them
#   from appearing in logs.

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

variable "ubuntu_iso_file" {
  type        = string
  description = "Ubuntu ISO filename as it appears in Proxmox"
}

variable "vm_id" {
  type        = number
  description = "Proxmox VM ID for the build VM (temporary)"
  default     = 9000
}

variable "template_name" {
  type        = string
  description = "Name for the resulting Proxmox template"
  default     = "k8s-ubuntu-2510"
}

variable "template_description" {
  type        = string
  description = "Description for the Proxmox template"
  default     = "K8s node golden image — Ubuntu 25.10 — built by Packer"
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
  description = "CPU cores for the build VM"
  default     = 2
}

variable "vm_memory" {
  type        = number
  description = "Memory in MB for the build VM"
  default     = 2048
}

variable "vm_disk_size" {
  type        = string
  description = "Disk size for the build VM"
  default     = "32G"
}

variable "network_bridge" {
  type        = string
  description = "Proxmox network bridge"
  default     = "vmbr0"
}

# ── Source: Proxmox ISO Builder ─────────────────────────────────────
# LEARNING NOTE — HOW THE BUILD WORKS:
#   1. Packer calls the Proxmox API to create a VM with the ISO attached
#   2. The boot_command types keystrokes into the VM console (like a human)
#      to start the automated installer
#   3. Packer starts an HTTP server serving the autoinstall config
#   4. The installer fetches the config and runs unattended
#   5. VM reboots after installation
#   6. Packer waits for SSH to become available
#   7. Provisioners run (our provision-k8s-node.sh script)
#   8. Packer shuts down the VM and converts it to a template
#
# LEARNING NOTE — BOOT COMMAND EXPLAINED:
#   The boot_command is a sequence of keystrokes. Special keys use angle
#   brackets: <wait5> pauses 5 seconds, <enter> presses Enter, <esc>
#   presses Escape. This simulates a human typing at the VM console to
#   navigate the bootloader and start the automated install.
#
#   For Ubuntu Server, we interrupt GRUB, edit the boot entry, and add
#   the autoinstall kernel parameters. The `ds=nocloud-net` tells
#   cloud-init to fetch config from our HTTP server.
source "proxmox-iso" "ubuntu-k8s" {
  # ── Proxmox Connection ──────────────────────────────────────────
  proxmox_url              = var.proxmox_api_url
  username                 = var.proxmox_api_token_id
  token                    = var.proxmox_api_token_secret
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true  # Self-signed cert on Proxmox

  # ── VM Configuration ────────────────────────────────────────────
  vm_id                = var.vm_id
  vm_name              = "packer-ubuntu-build"
  template_name        = var.template_name
  template_description = var.template_description

  # ISO
  iso_file = "${var.proxmox_iso_storage}:iso/${var.ubuntu_iso_file}"

  # Hardware
  cores    = var.vm_cores
  memory   = var.vm_memory
  cpu_type = "host"  # Pass-through host CPU features
  os       = "l26"   # Linux 2.6+ kernel

  # LEARNING NOTE — SCSI CONTROLLER:
  #   virtio-scsi-single gives each disk its own SCSI bus, enabling
  #   features like discard (TRIM) and IO thread offloading. It's the
  #   recommended controller for modern Linux VMs in Proxmox.
  scsi_controller = "virtio-scsi-single"

  disks {
    storage_pool = var.proxmox_disk_storage
    disk_size    = var.vm_disk_size
    type         = "scsi"
    discard      = true   # Enable TRIM for thin provisioning
    ssd          = true   # Hint to guest OS for SSD optimisation
  }

  network_adapters {
    bridge = var.network_bridge
    model  = "virtio"     # Best performance for Linux guests
  }

  # Enable QEMU guest agent (installed by autoinstall)
  qemu_agent = true

  # Cloud-init drive for post-template personalisation
  cloud_init              = true
  cloud_init_storage_pool = var.proxmox_disk_storage

  # ── Boot Command ────────────────────────────────────────────────
  # Navigates the GRUB menu and adds autoinstall parameters.
  # {{ .HTTPIP }} and {{ .HTTPPort }} are Packer template variables
  # that resolve to the IP and port of Packer's built-in HTTP server.
  boot_wait = "5s"
  boot_command = [
    "<esc><wait>",
    "e<wait>",
    "<down><down><down><end>",
    " autoinstall ds='nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/autoinstall/'",
    "<wait><F10>"
  ]

  # ── HTTP Server ─────────────────────────────────────────────────
  # Packer serves the autoinstall config from this directory.
  http_directory = "${path.root}/http"

  # ── SSH Connection ──────────────────────────────────────────────
  ssh_username         = var.ssh_username
  ssh_password         = var.ssh_password
  ssh_timeout          = "30m"  # Ubuntu install can take 15+ min on slow storage
  ssh_handshake_attempts = 30
}

# ── Build ───────────────────────────────────────────────────────────
build {
  sources = ["source.proxmox-iso.ubuntu-k8s"]

  # Copy the provisioning script to the VM
  provisioner "file" {
    source      = "${path.root}/../scripts/provision-k8s-node.sh"
    destination = "/tmp/provision-k8s-node.sh"
  }

  # Run the shared provisioning script
  # LEARNING NOTE — INLINE VS SCRIPT PROVISIONER:
  #   The "shell" provisioner with inline commands runs arbitrary bash.
  #   The "file" provisioner copies files first. We copy then execute
  #   rather than using the "script" provisioner because the script needs
  #   arguments (--role, --arch) that are easier to pass via inline.
  provisioner "shell" {
    inline = [
      "chmod +x /tmp/provision-k8s-node.sh",
      "sudo bash /tmp/provision-k8s-node.sh control-plane amd64",
      "rm /tmp/provision-k8s-node.sh",
    ]
  }
}
