targetScope = 'resourceGroup'

type ImageTemplateSpec = {
  key: string
  name: string
  image_definition_id: string
  distribute_vhd: bool
  run_output_name: string
  gallery_run_output: string
}

@description('Naming component retained for manifest parity.')
param org string

@description('Lab naming component retained for manifest parity.')
param lab_token string

param location string

@description('Naming component retained for manifest parity.')
param location_short string

@description('Deployment tenant retained for manifest parity.')
param tenant_id string

@description('AVD subscription retained for manifest parity.')
param subscription_id_avd string

param tags object

@description('Generated names catalog retained for manifest parity.')
param names object

param templates ImageTemplateSpec[]
param aib_identity_id string
param subnet_imgbuild_id string
param source_publisher string
param source_offer string
param source_sku string

@description('Exact platform image version from Get-PlatformImageVersion.ps1; the moving alias is refused by the script.')
param source_version string

param build_vm_size string
param os_disk_size_gb int
param build_timeout_minutes int = 120
param replication_regions string[]

@minValue(1024)
@maxValue(65535)
param shortpath_port int

param defender_paths string = ''
param defender_processes string = ''
param vdot_archive_uri string = ''
param vdot_archive_sha256 string = ''
param install_teams_app string = 'false'
param disable_teams_autoupdate string = 'false'

// Customizer scripts are embedded inline (no staging storage); CRLF is normalised so each array entry is one line.
func scriptLines(text string) string[] => split(replace(text, '\r\n', '\n'), '\n')

var fslogixLines = scriptLines(loadTextContent('../../shared/customizers/01-Install-Fslogix.ps1'))
var teamsLines = scriptLines(replace(replace(loadTextContent('../../shared/customizers/02-Install-TeamsWebRtc.ps1'), '{{install_teams_app}}', install_teams_app), '{{disable_teams_autoupdate}}', disable_teams_autoupdate))
var shortpathLines = scriptLines(replace(loadTextContent('../../shared/customizers/03-Set-ShortpathListener.ps1'), '{{shortpath_port}}', string(shortpath_port)))
var defenderLines = scriptLines(replace(replace(loadTextContent('../../shared/customizers/04-Set-DefenderExclusions.ps1'), '{{defender_paths}}', defender_paths), '{{defender_processes}}', defender_processes))
var vdotLines = scriptLines(replace(replace(loadTextContent('../../shared/customizers/05-Invoke-Vdot.ps1'), '{{vdot_archive_uri}}', vdot_archive_uri), '{{vdot_archive_sha256}}', vdot_archive_sha256))

resource imageTemplates 'Microsoft.VirtualMachineImages/imageTemplates@2025-10-01' = [for template in templates: {
  name: template.name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aib_identity_id}': {}
    }
  }
  properties: {
    buildTimeoutInMinutes: build_timeout_minutes
    vmProfile: {
      vmSize: build_vm_size
      osDiskSizeGB: os_disk_size_gb
      vnetConfig: {
        subnetId: subnet_imgbuild_id
      }
      userAssignedIdentities: [
        aib_identity_id
      ]
    }
    source: {
      type: 'PlatformImage'
      publisher: source_publisher
      offer: source_offer
      sku: source_sku
      version: source_version
    }
    customize: [
      {
        type: 'PowerShell'
        name: 'InstallFslogix'
        runElevated: true
        runAsSystem: true
        inline: fslogixLines
      }
      {
        type: 'WindowsRestart'
        restartTimeout: '10m'
      }
      {
        type: 'PowerShell'
        name: 'InstallTeamsWebRtc'
        runElevated: true
        runAsSystem: true
        inline: teamsLines
      }
      {
        type: 'PowerShell'
        name: 'SetShortpathListener'
        runElevated: true
        runAsSystem: true
        inline: shortpathLines
      }
      {
        type: 'PowerShell'
        name: 'SetDefenderExclusions'
        runElevated: true
        runAsSystem: true
        inline: defenderLines
      }
      {
        type: 'PowerShell'
        name: 'InvokeVdot'
        runElevated: true
        runAsSystem: true
        inline: vdotLines
      }
      {
        type: 'WindowsRestart'
        restartTimeout: '10m'
      }
      {
        type: 'WindowsUpdate'
        searchCriteria: 'IsInstalled=0'
        filters: [
          'exclude:$_.Title -like \'*Preview*\''
          'include:$true'
        ]
        updateLimit: 40
      }
      {
        type: 'WindowsRestart'
        restartTimeout: '10m'
      }
    ]
    distribute: concat([
        {
          type: 'SharedImage'
          galleryImageId: template.image_definition_id
          runOutputName: template.gallery_run_output
          replicationRegions: replication_regions
          storageAccountType: 'Premium_LRS'
          excludeFromLatest: false
        }
      ], template.distribute_vhd ? [
        {
          type: 'VHD'
          runOutputName: template.run_output_name
        }
      ] : [])
  }
}]

output template_ids string[] = [for (template, index) in templates: imageTemplates[index].id]
output template_names string[] = [for template in templates: template.name]
