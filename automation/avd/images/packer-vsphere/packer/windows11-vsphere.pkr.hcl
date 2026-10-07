# Reference template, not run in the lab. Windows 11 Enterprise single-session image for AVD Hybrid hosts on vSphere.
packer {
  required_version = ">= 1.11.0"

  required_plugins {
    vsphere = {
      source  = "github.com/hashicorp/vsphere"
      version = "~> 2"
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

source "vsphere-iso" "image" {
  vcenter_server      = var.vcenter_server
  username            = var.vcenter_username
  password            = var.vcenter_password
  insecure_connection = var.vcenter_insecure_connection

  datacenter = var.datacenter
  cluster    = var.cluster
  datastore  = var.datastore
  folder     = var.folder
  vm_name    = var.vm_name
  vm_version = var.vm_version

  # Windows 11 needs UEFI Secure Boot and a vTPM; vTPM needs a key provider (or native key provider) configured on the vCenter.
  guest_os_type = "windows11_64Guest"
  firmware      = "efi-secure"
  vTPM          = true

  CPUs = var.cpus
  RAM  = var.memory_mb

  # Inbox-driver devices for the build so Setup needs no driver injection.
  disk_controller_type = ["lsilogic-sas"]

  storage {
    disk_size             = var.disk_size_mb
    disk_thin_provisioned = true
  }

  network_adapters {
    network      = var.network
    network_card = "e1000e"
  }

  # Windows ISO plus the VMware Tools ISO; the answer file installs Tools at first logon so vSphere can report the guest IP to Packer.
  iso_paths = [var.iso_datastore_path, var.vmtools_iso_path]

  # Windows UEFI media asks to press a key to boot from the CD.
  boot_wait    = "3s"
  boot_command = ["<spacebar><wait2><spacebar><wait2><spacebar>"]

  cd_content = {
    "autounattend.xml" = templatefile("${path.root}/templates/autounattend.xml.tpl", {
      build_username = var.build_username
      build_password = var.build_password
      product_key    = var.product_key
    })
  }
  cd_label = "IICANSWER"

  communicator     = "winrm"
  winrm_username   = var.build_username
  winrm_password   = var.build_password
  winrm_use_ssl    = false
  winrm_timeout    = var.winrm_timeout
  shutdown_command = var.shutdown_command
  shutdown_timeout = "45m"

  remove_cdrom        = true
  convert_to_template = true
}

build {
  sources = ["source.vsphere-iso.image"]

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

  # Known gaps: (1) VMware Tools is installed by the answer file at first logon with the default silent switches; verify the
  # result on your ESXi and Tools version. (2) Windows updates are not installed; install and verify them, including pending
  # reboots, before sysprep.

  post-processor "manifest" {
    output = "packer-manifest.json"
  }
}
