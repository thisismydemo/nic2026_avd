targetScope = 'resourceGroup'

@description('Organization identifier; retained for manifest parity.')
param org string

@description('Lab token; retained for manifest parity.')
param lab_token string

param location string

@description('Short location identifier; retained for manifest parity.')
param location_short string

@description('Tenant ID; retained for manifest parity.')
param tenant_id string

@description('Subscription ID; retained for manifest parity.')
param subscription_id_azl string

param tags object
param names object

@minValue(1)
@maxValue(2)
param host_count int

@minValue(1)
param vcpu int

@minValue(1)
param memory_mb int

param custom_location_id string
param logical_network_id string
param image_id string
param dcr_id string
param entra_join_extension bool = true
param enable_monitoring bool = true

@description('Used by the post-deployment registration script, not by IaC.')
param hostpool_name string

@description('Used by the post-deployment registration script, not by IaC.')
param hostpool_rg string

@secure()
param adminUsername string

@secure()
param adminPassword string

module hosts 'modules/host.bicep' = [for i in range(0, host_count): {
  name: '${names.deployment_name}-${i + 1}'
  params: {
    location: location
    tags: tags
    vmName: names['vm_azl_${i + 1}']
    computerName: names['cn_azl_${i + 1}']
    nicName: names['nic_azl_${i + 1}']
    dcrAssocName: names.dcr_assoc
    vcpu: vcpu
    memoryMB: memory_mb
    customLocationId: custom_location_id
    logicalNetworkId: logical_network_id
    imageId: image_id
    dcrId: dcr_id
    entraJoinExtension: entra_join_extension
    enableMonitoring: enable_monitoring
    adminUsername: adminUsername
    adminPassword: adminPassword
  }
}]

output machine_ids string[] = [for i in range(0, host_count): hosts[i].outputs.machineId]
output computer_names string[] = [for i in range(0, host_count): hosts[i].outputs.computerName]
output machine_principal_ids string[] = [for i in range(0, host_count): hosts[i].outputs.principalId]
