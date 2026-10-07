using './main.bicep'

param org = 'iic'
param lab_token = 'nic26'
param location = 'eastus'
param location_short = 'eus'
param tenant_id = '00000000-0000-0000-0000-000000000000'
param subscription_id_avd = '00000000-0000-0000-0000-000000000000'
param tags = { environment: 'example' }
param names = {
  it_azure: 'example-it-azure'
  it_azl: 'example-it-azl'
  runout_azure: 'example-runout-azure'
  runout_azl_gallery: 'example-runout-azl-gallery'
  runout_azl_vhd: 'example-runout-azl-vhd'
  deployment_name: 'example-deployment'
}
param templates = [
  {
    key: 'azure'
    name: 'example-it-azure'
    image_definition_id: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Compute/galleries/examplegallery/images/example-azure-definition'
    distribute_vhd: false
    run_output_name: ''
    gallery_run_output: 'example-runout-azure'
  }
  {
    key: 'azl'
    name: 'example-it-azl'
    image_definition_id: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Compute/galleries/examplegallery/images/example-azl-definition'
    distribute_vhd: true
    run_output_name: 'example-runout-azl-vhd'
    gallery_run_output: 'example-runout-azl-gallery'
  }
]
param aib_identity_id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/example-aib'
param subnet_imgbuild_id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Network/virtualNetworks/example-vnet/subnets/example-imgbuild'
param source_publisher = 'MicrosoftWindowsDesktop'
param source_offer = 'office-365'
param source_sku = 'win11-25h2-avd-m365'
// Resolve the exact version with scripts/Get-PlatformImageVersion.ps1 before deploying.
param source_version = '0.0.0'
param build_vm_size = 'Standard_D4ds_v4'
param os_disk_size_gb = 127
param build_timeout_minutes = 120
param replication_regions = ['eastus']
param shortpath_port = 3390
param defender_paths = ''
param defender_processes = ''
param vdot_archive_uri = ''
param vdot_archive_sha256 = ''
param install_teams_app = 'false'
param disable_teams_autoupdate = 'false'
