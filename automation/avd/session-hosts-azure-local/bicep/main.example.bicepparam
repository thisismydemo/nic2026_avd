using './main.bicep'

param org = 'iic'
param lab_token = 'nic26'
param location = 'eastus'
param location_short = 'eus'
param tenant_id = '00000000-0000-0000-0000-000000000000'
param subscription_id_azl = '00000000-0000-0000-0000-000000000000'
param tags = { environment: 'example' }
param names = {
  vm_azl_1: 'example-vm-1'
  cn_azl_1: 'examplecn1'
  nic_azl_1: 'example-nic-1'
  vm_azl_2: 'example-vm-2'
  cn_azl_2: 'examplecn2'
  nic_azl_2: 'example-nic-2'
  dcr_assoc: 'example-dcra'
  deployment_name: 'example-deployment'
}
param host_count = 2
param vcpu = 4
param memory_mb = 16384
param custom_location_id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.ExtendedLocation/customLocations/example-cl'
param logical_network_id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.AzureStackHCI/logicalNetworks/example-network'
param image_id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.AzureStackHCI/marketplaceGalleryImages/example-image'
param dcr_id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Insights/dataCollectionRules/example-dcr'
param entra_join_extension = true
param enable_monitoring = true
param hostpool_name = 'example-hostpool'
param hostpool_rg = 'example-control-rg'
// Illustration only. The deploy script supplies both secure parameters in memory.
param adminUsername = 'REPLACE-AT-DEPLOY'
param adminPassword = 'REPLACE-AT-DEPLOY'
