# Reference template, not run in the lab. Windows 11 Enterprise single-session image for AVD Hybrid hosts on Nutanix AHV.
packer {
  required_version = ">= 1.11.0"

  required_plugins {
    nutanix = {
      source  = "github.com/nutanix-cloud-native/nutanix"
      version = "~> 1"
    }
  }
}

locals {
  # Same shared customizers and order as the Hyper-V template. {{token}} placeholders are rendered in memory (tokens are not secret).
  rendered_01 = replace(file("${var.customizer_directory}/01-Install-Fslogix.ps1"), "\r\n", "\n")
  rendered_02 = replace(replace(replace(file("${var.customizer_directory}/02-Install-TeamsWebRtc.ps1"),
    "{{install_teams_app}}", lookup(var.customizer_tokens, "install_teams_app", "true")),
  "{{disable_teams_autoupdate}}", lookup(var.customizer_tokens, "disable_teams_autoupdate", "false")), "\r\n", "\n")
  rendered_03 = replace(replace(file("${var.customizer_directory}/03-Set-ShortpathListener.ps1"),
  "{{shortpath_port}}", format("%d", var.shortpath_port)), "\r\n", "\n")
  rendered_04 = replace(replace(replace(file("${var.customizer_directory}/04-Set-DefenderExclusions.ps1"),
    "{{defender_paths}}", var.defender_paths),
  "{{defender_processes}}", var.defender_processes), "\r\n", "\n")
  rendered_05 = replace(replace(replace(file("${var.customizer_directory}/05-Invoke-Vdot.ps1"),
    "{{vdot_archive_uri}}", var.vdot_archive_uri),
  "{{vdot_archive_sha256}}", var.vdot_archive_sha256), "\r\n", "\n")
  rendered_06 = replace(replace(replace(file("${var.customizer_directory}/06-Copy-ArcAgent.ps1"),
    "{{arc_agent_uri}}", var.arc_agent_uri),
  "{{arc_agent_directory}}", var.arc_agent_directory), "\r\n", "\n")
}

source "nutanix" "image" {
  nutanix_endpoint = var.nutanix_endpoint
  nutanix_port     = var.nutanix_port
  nutanix_username = var.nutanix_username
  nutanix_password = var.nutanix_password
  nutanix_insecure = var.nutanix_insecure

  vm_name      = var.vm_name
  cluster_name = var.cluster_name
  os_type      = "Windows"
  # Windows 11 supports at most two CPU sockets: one socket, N cores.
  cpu       = 1
  core      = var.cpus
  memory_mb = var.memory_mb

  # Windows 11 needs UEFI Secure Boot and a vTPM.
  boot_type = "secure_boot"

  vtpm {
    enabled = true
  }

  # Install media, then the VirtIO driver ISO (the answer file loads storage and network drivers from it), then the system disk.
  vm_disks {
    image_type        = "ISO_IMAGE"
    source_image_name = var.iso_image_name
  }

  vm_disks {
    image_type        = "ISO_IMAGE"
    source_image_name = var.virtio_iso_image_name
  }

  vm_disks {
    image_type   = "DISK"
    disk_size_gb = ceil(var.disk_size_mb / 1024)
  }

  vm_nics {
    subnet_name = var.subnet_name
  }

  cd_content = {
    "autounattend.xml" = templatefile("${path.root}/templates/autounattend.xml.tpl", {
      build_username = var.build_username
      build_password = var.build_password
      product_key    = var.product_key
    })
  }
  cd_label = "IICANSWER"

  # Windows UEFI media asks to press a key to boot from the CD.
  boot_wait    = "3s"
  boot_command = ["<spacebar><wait2><spacebar><wait2><spacebar>"]

  communicator     = "winrm"
  winrm_username   = var.build_username
  winrm_password   = var.build_password
  winrm_use_ssl    = false
  winrm_timeout    = var.winrm_timeout
  ip_wait_timeout  = "30m"
  shutdown_command = var.shutdown_command
  shutdown_timeout = "45m"

  image_name = var.image_name
}

build {
  sources = ["source.nutanix.image"]

  # Packer runs every inline script through its own template engine, so a literal double brace in a customizer is escaped here.
  provisioner "powershell" {
    inline = split("\n", replace(local.rendered_01, "{{", "{{ \"{{\" }}"))
  }

  provisioner "windows-restart" {}

  provisioner "powershell" {
    inline = split("\n", replace(local.rendered_02, "{{", "{{ \"{{\" }}"))
  }

  provisioner "powershell" {
    inline = split("\n", replace(local.rendered_03, "{{", "{{ \"{{\" }}"))
  }

  provisioner "powershell" {
    inline = split("\n", replace(local.rendered_04, "{{", "{{ \"{{\" }}"))
  }

  provisioner "powershell" {
    inline = split("\n", replace(local.rendered_05, "{{", "{{ \"{{\" }}"))
  }

  provisioner "windows-restart" {}

  provisioner "powershell" {
    inline = split("\n", replace(local.rendered_06, "{{", "{{ \"{{\" }}"))
  }

  # Known gaps: (1) the Nutanix guest tools are not installed; add and verify an installer step before the sysprep
  # shutdown_command. (2) Windows updates are not installed; install and verify them, including pending reboots, before sysprep.

  post-processor "manifest" {
    output = "packer-manifest.json"
  }
}
