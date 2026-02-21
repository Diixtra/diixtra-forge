# =============================================================================
# Packer Template — GPU K8s Node (Ubuntu 25.10 + NVIDIA + K3s)
# =============================================================================
#
# LEARNING NOTE — TWO-STAGE PROVISIONING:
#   This template runs TWO provisioning scripts in order:
#     1. provision-k8s-node.sh  — Base packages (open-iscsi, nfs-common, etc.)
#     2. provision-gpu-node.sh  — GPU layer (NVIDIA driver, Container Toolkit, K3s)
#
#   This is the same layering principle as Kustomize base + overlay:
#     base = provision-k8s-node.sh (every K8s node needs this)
#     overlay = provision-gpu-node.sh (only GPU nodes need this)
#
#   The Ubuntu non-GPU template (proxmox-ubuntu/) runs ONLY script 1.
#   This GPU template runs both. Same base, different top layer.
#
# LEARNING NOTE — VM SIZING FOR GPU NODES:
#   GPU VMs need more resources than regular K8s nodes:
#     - 8+ CPU cores: GPU workloads (Ollama, training) are CPU-bound too
#       for data preprocessing, tokenisation, and batch assembly
#     - 32GB+ RAM: LLM inference loads model weights into system RAM first,
#       then transfers to VRAM. With a 16GB VRAM GPU, you need at least
#       16GB system RAM just for the model transfer, plus OS and K3s overhead
#     - 100GB+ disk: Model files are large. Llama 3 8B = ~5GB,
#       Llama 3 70B = ~40GB. Multiple models plus container images add up.
#
# USAGE:
#   packer validate -var-file="variables.auto.pkrvars.hcl" proxmox-gpu/
#   packer build -var-file="variables.auto.pkrvars.hcl" proxmox-gpu/

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

variable "ubuntu_iso_file" {
  type        = string
  description = "Ubuntu ISO filename as it appears in Proxmox"
}

variable "vm_id" {
  type        = number
  description = "Proxmox VM ID for the build VM (temporary)"
  default     = 9002
}

variable "template_name" {
  type        = string
  description = "Name for the resulting Proxmox template"
  default     = "k8s-gpu-ubuntu-2510"
}

variable "template_description" {
  type        = string
  description = "Description for the Proxmox template"
  default     = "K8s GPU node golden image — Ubuntu 25.10 + NVIDIA 570 + K3s — built by Packer"
}

variable "ssh_username" {
  type        = string
  default     = "packer"
}

variable "ssh_password" {
  type        = string
  default     = "packer"
  sensitive   = true
}

# GPU VMs need significantly more resources than regular nodes
variable "vm_cores" {
  type        = number
  default     = 4
  description = "CPU cores — GPU builds install more packages, need more cores"
}

variable "vm_memory" {
  type        = number
  default     = 4096
  description = "Memory in MB — NVIDIA driver compilation (DKMS) needs RAM"
}

variable "vm_disk_size" {
  type        = string
  default     = "64G"
  description = "Disk size — must fit NVIDIA driver, K3s, and model storage"
}

variable "network_bridge" {
  type        = string
  default     = "vmbr0"
}

# ── Source ───────────────────────────────────────────────────────────
# LEARNING NOTE — BUILD VM vs CLONED VM:
#   The build VM (this Packer config) is a TEMPORARY VM used only to
#   create the template. Its resources (4 cores, 4GB RAM, 64GB disk)
#   are sized for the BUILD PROCESS (compiling DKMS modules, installing
#   packages).
#
#   When you CLONE the template to create the actual GPU VM, you'll
#   resize it in Proxmox/Terraform to production specs:
#     - 8-16 cores, 32-64GB RAM, 200GB+ disk
#     - PCI passthrough of the RTX 5070 Ti
#   The template is just a starting point.
source "proxmox-iso" "gpu-k8s" {
  # Proxmox connection
  proxmox_url              = var.proxmox_api_url
  username                 = var.proxmox_api_token_id
  token                    = var.proxmox_api_token_secret
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  # VM settings
  vm_id                = var.vm_id
  vm_name              = "packer-gpu-build"
  template_name        = var.template_name
  template_description = var.template_description

  # ISO — same Ubuntu ISO as the non-GPU template
  boot_iso {
    iso_file = "${var.proxmox_iso_storage}:iso/${var.ubuntu_iso_file}"
    unmount  = true
  }

  # Hardware — larger than regular nodes for build process
  cores    = var.vm_cores
  memory   = var.vm_memory
  cpu_type = "host"
  os       = "l26"

  # LEARNING NOTE — MACHINE TYPE q35:
  #   The q35 machine type emulates a modern Intel Q35 chipset which
  #   supports PCIe natively. The older i440fx machine type only supports
  #   PCI (not PCIe). While this doesn't matter during the Packer BUILD
  #   (no GPU attached), setting q35 now means the template is pre-
  #   configured for PCI passthrough when you clone it and attach the GPU.
  machine = "q35"

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

  # Boot command — identical to the non-GPU Ubuntu template
  # Same autoinstall process, different provisioning scripts after
  boot_wait = "5s"
  boot_command = [
    "<esc><wait>",
    "e<wait>",
    "<down><down><down><end>",
    " autoinstall ds='nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/autoinstall/'",
    "<wait><F10>"
  ]

  # Reuse the same autoinstall config as the Ubuntu template
  http_directory = "${path.root}/http"

  # SSH — longer timeout because GPU driver compilation takes time
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = "45m"
  ssh_handshake_attempts = 30
}

# ── Build ───────────────────────────────────────────────────────────
build {
  sources = ["source.proxmox-iso.gpu-k8s"]

  # ── Stage 1: Base K8s node packages ───────────────────────────────
  provisioner "file" {
    source      = "${path.root}/../scripts/provision-k8s-node.sh"
    destination = "/tmp/provision-k8s-node.sh"
  }

  provisioner "shell" {
    inline = [
      "chmod +x /tmp/provision-k8s-node.sh",
      "sudo bash /tmp/provision-k8s-node.sh control-plane amd64",
      "rm -f /tmp/provision-k8s-node.sh",
    ]
  }

  # ── Stage 2: GPU-specific packages ────────────────────────────────
  provisioner "file" {
    source      = "${path.root}/../scripts/provision-gpu-node.sh"
    destination = "/tmp/provision-gpu-node.sh"
  }

  provisioner "shell" {
    inline = [
      "chmod +x /tmp/provision-gpu-node.sh",
      "sudo bash /tmp/provision-gpu-node.sh",
      "rm -f /tmp/provision-gpu-node.sh",
    ]
  }
}
