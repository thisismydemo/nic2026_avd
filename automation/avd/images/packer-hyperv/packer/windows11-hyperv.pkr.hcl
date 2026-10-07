packer {
  required_version = ">= 1.11.0"

  required_plugins {
    hyperv = {
      source  = "github.com/hashicorp/hyperv"
      version = "~> 1"
    }
  }
}

locals {
  # The shared customizers carry {{token}} placeholders; they are rendered in memory (tokens are not secret) and
  # CRLF is normalised so each array entry is one line. Nothing identity- or share-specific is rendered.
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

source "hyperv-iso" "image" {
  vm_name            = var.vm_name
  iso_url            = var.iso_path
  iso_checksum       = var.iso_checksum
  generation         = 2
  enable_secure_boot = true
  enable_tpm         = true
  switch_name        = var.switch_name
  vlan_id            = var.vlan_id
  cpus               = var.cpus
  memory             = var.memory_mb
  disk_size          = var.disk_size_mb
  communicator       = "winrm"
  winrm_username     = var.build_username
  winrm_password     = var.build_password
  winrm_timeout      = var.winrm_timeout
  winrm_use_ssl      = false
  headless           = true
  output_directory   = var.output_directory
  shutdown_command   = var.shutdown_command

  cd_content = {
    "autounattend.xml" = templatefile("${path.root}/templates/autounattend.xml.tpl", {
      build_username = var.build_username
      build_password = var.build_password
      product_key    = var.product_key
    })
  }
}

build {
  sources = ["source.hyperv-iso.image"]

  # Packer runs every inline script through its own template engine, so a literal double brace in a customizer (the unrendered-placeholder guards) is escaped here.
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

  # Known gap: this template does not install Windows updates (there is no Packer-native, reliable step without a
  # community plugin). Install and verify updates, including pending reboots, before the sysprep shutdown_command runs.

  post-processor "manifest" {
    output = "packer-manifest.json"
  }
}
