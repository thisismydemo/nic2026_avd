data "azurerm_resource_group" "images" {
  name = var.resource_group_name
}

locals {
  # CRLF is normalised so each array entry is one line.
  fslogix_lines = split("\n", replace(file("${path.module}/../../shared/customizers/01-Install-Fslogix.ps1"), "\r\n", "\n"))
  teams_lines = split("\n", replace(replace(
    replace(file("${path.module}/../../shared/customizers/02-Install-TeamsWebRtc.ps1"), "{{install_teams_app}}", var.install_teams_app),
    "{{disable_teams_autoupdate}}", var.disable_teams_autoupdate
  ), "\r\n", "\n"))
  shortpath_lines = split("\n", replace(replace(
    file("${path.module}/../../shared/customizers/03-Set-ShortpathListener.ps1"),
    "{{shortpath_port}}", tostring(var.shortpath_port)
  ), "\r\n", "\n"))
  defender_lines = split("\n", replace(replace(replace(
    file("${path.module}/../../shared/customizers/04-Set-DefenderExclusions.ps1"), "{{defender_paths}}", var.defender_paths),
    "{{defender_processes}}", var.defender_processes
  ), "\r\n", "\n"))
  vdot_lines = split("\n", replace(replace(replace(
    file("${path.module}/../../shared/customizers/05-Invoke-Vdot.ps1"), "{{vdot_archive_uri}}", var.vdot_archive_uri),
    "{{vdot_archive_sha256}}", var.vdot_archive_sha256
  ), "\r\n", "\n"))
}

resource "azapi_resource" "image_template" {
  for_each  = { for template in var.templates : template.key => template }
  type      = "Microsoft.VirtualMachineImages/imageTemplates@2025-10-01"
  name      = each.value.name
  location  = var.location
  parent_id = data.azurerm_resource_group.images.id
  tags      = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.aib_identity_id]
  }

  body = {
    properties = {
      buildTimeoutInMinutes = var.build_timeout_minutes
      vmProfile = {
        vmSize                 = var.build_vm_size
        osDiskSizeGB           = var.os_disk_size_gb
        vnetConfig             = { subnetId = var.subnet_imgbuild_id }
        userAssignedIdentities = [var.aib_identity_id]
      }
      source = {
        type      = "PlatformImage"
        publisher = var.source_publisher
        offer     = var.source_offer
        sku       = var.source_sku
        version   = var.source_version
      }
      customize = [
        { type = "PowerShell", name = "InstallFslogix", runElevated = true, runAsSystem = true, inline = local.fslogix_lines },
        { type = "WindowsRestart", restartTimeout = "10m" },
        { type = "PowerShell", name = "InstallTeamsWebRtc", runElevated = true, runAsSystem = true, inline = local.teams_lines },
        { type = "PowerShell", name = "SetShortpathListener", runElevated = true, runAsSystem = true, inline = local.shortpath_lines },
        { type = "PowerShell", name = "SetDefenderExclusions", runElevated = true, runAsSystem = true, inline = local.defender_lines },
        { type = "PowerShell", name = "InvokeVdot", runElevated = true, runAsSystem = true, inline = local.vdot_lines },
        { type = "WindowsRestart", restartTimeout = "10m" },
        {
          type           = "WindowsUpdate"
          searchCriteria = "IsInstalled=0"
          filters        = ["exclude:$_.Title -like '*Preview*'", "include:$true"]
          updateLimit    = 40
        },
        { type = "WindowsRestart", restartTimeout = "10m" }
      ]
      distribute = concat(
        [{
          type               = "SharedImage"
          galleryImageId     = each.value.image_definition_id
          runOutputName      = each.value.gallery_run_output
          replicationRegions = var.replication_regions
          storageAccountType = "Premium_LRS"
          excludeFromLatest  = false
        }],
        each.value.distribute_vhd ? [{ type = "VHD", runOutputName = each.value.run_output_name }] : []
      )
    }
  }
}
