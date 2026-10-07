using './main.bicep'

param org = 'iic'
param lab_token = 'nic26'
param location = 'eastus'
param location_short = 'eus'
param tenant_id = '00000000-0000-0000-0000-000000000000'
param subscription_id_avd = '00000000-0000-0000-0000-000000000000'
param tags = { environment: 'example' }
param names = {
  vm_azure_1: 'example-vm-1'
  cn_azure_1: 'exampleaz1'
  nic_azure_1: 'example-nic-1'
  osdisk_azure_1: 'example-osdisk-1'
  vm_azure_2: 'example-vm-2'
  cn_azure_2: 'exampleaz2'
  nic_azure_2: 'example-nic-2'
  osdisk_azure_2: 'example-osdisk-2'
  dcr_assoc: 'example-dcr-assoc'
  deployment_name: 'example-deployment'
}
param host_count = 2
param session_host_sku_azure = 'Standard_D4ds_v4'
param os_disk_sku = 'Premium_LRS'
param os_disk_size_gb = 128
param session_host_zones = [1, 2]
param hosts_subnet_id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Network/virtualNetworks/example-vnet/subnets/example-subnet'
param image_version_id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Compute/galleries/example-gallery/images/example-image/versions/1.0.0'
param dcr_id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Insights/dataCollectionRules/example-dcr'
param encryption_at_host = true
param hostpool_name = 'example-hostpool'
param hostpool_rg = 'example-control-rg'
param adminUsername = 'REPLACE-AT-DEPLOY'
param adminPassword = 'REPLACE-AT-DEPLOY'
