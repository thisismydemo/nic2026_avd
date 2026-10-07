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
param subscription_id_avd string

param tags object
param names object

@minValue(1)
@maxValue(2)
param host_count int

param session_host_sku_azure string
@description('OS disk storage SKU.')
param os_disk_sku string = 'Premium_LRS'
@description('OS disk size in GB.')
param os_disk_size_gb int = 128
param session_host_zones int[]
param hosts_subnet_id string
param image_version_id string
param dcr_id string
param encryption_at_host bool = true

@description('Used by the post-deployment registration script, not by IaC.')
param hostpool_name string

@description('Used by the post-deployment registration script, not by IaC.')
param hostpool_rg string



@secure()
param adminUsername string

@secure()
param adminPassword string

module hosts 'br/public:avm/res/compute/virtual-machine:0.22.3' = [for i in range(0, host_count): {
  name: '${names.deployment_name}-${i + 1}'
  params: {
    name: names['vm_azure_${i + 1}']
    computerName: names['cn_azure_${i + 1}']
    location: location
    tags: tags
    osType: 'Windows'
    vmSize: session_host_sku_azure
    availabilityZone: session_host_zones[i % length(session_host_zones)]
    adminUsername: adminUsername
    adminPassword: adminPassword
    imageReference: {
      id: image_version_id
    }
    osDisk: {
      name: names['osdisk_azure_${i + 1}']
      createOption: 'FromImage'
      deleteOption: 'Delete'
      caching: 'ReadWrite'
      diskSizeGB: os_disk_size_gb
      managedDisk: {
        storageAccountType: os_disk_sku
      }
    }
    nicConfigurations: [
      {
        name: names['nic_azure_${i + 1}']
        deleteOption: 'Delete'
        enableAcceleratedNetworking: true
        ipConfigurations: [
          {
            name: 'ipconfig01'
            subnetResourceId: hosts_subnet_id
            privateIPAllocationMethod: 'Dynamic'
          }
        ]
      }
    ]
    managedIdentities: {
      systemAssigned: true
    }
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    vTpmEnabled: true
    encryptionAtHost: encryption_at_host
    bootDiagnostics: true
    patchMode: 'Manual'
    enableAutomaticUpdates: false
    licenseType: 'Windows_Client'
    extensionAadJoinConfig: {
      enabled: true
    }
    extensionMonitoringAgentConfig: {
      enabled: true
      dataCollectionRuleAssociations: [
        {
          name: names.dcr_assoc
          dataCollectionRuleResourceId: dcr_id
        }
      ]
    }
  }
}]

output session_host_ids string[] = [for i in range(0, host_count): hosts[i].outputs.resourceId]
output session_host_names string[] = [for i in range(0, host_count): names['cn_azure_${i + 1}']]
output vm_principal_ids string[] = [for i in range(0, host_count): hosts[i].outputs.?systemAssignedMIPrincipalId ?? '']
