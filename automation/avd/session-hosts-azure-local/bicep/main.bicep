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

@description('Number of Azure Local session hosts (names vm_azl_<n>, cn_azl_<n>, nic_azl_<n> in the names catalog).')
@minValue(1)
@maxValue(3)
param host_count int

@minValue(1)
param vcpu int

@minValue(1)
param memory_mb int

param custom_location_id string
param logical_network_id string

@description('DNS servers of the logical network (repeated on each NIC so a re-run does not change them).')
param dns_servers string[] = []

param image_id string

@description('Storage path resource IDs, one per host in host order (D-049: vmstore-01 for host 1, vmstore-02 for host 2).')
param storage_path_ids string[]

param dcr_id string

@description('AD (JsonADDomainExtension, D-050), Entra (AADLoginForWindows) or None.')
@allowed([
  'AD'
  'Entra'
  'None'
])
param join_type string = 'AD'

@description('AD DNS domain the hosts join (join_type AD).')
param domain_fqdn string = ''

@description('Distinguished name of the OU for the computer accounts (join_type AD).')
param domain_ou_path string = ''

@description('Per-host vCPU overrides in host order (0 or missing = vcpu).')
param vcpu_per_host int[] = []

@description('Per-host memory overrides in MB in host order (0 or missing = memory_mb).')
param memory_mb_per_host int[] = []

@description('GPU DDA devices per host in host order; missing entries mean 0.')
param gpu_dda_counts int[] = []

param enable_monitoring bool = true

@description('Used by the post-deployment registration script, not by IaC.')
param hostpool_name string

@description('Used by the post-deployment registration script, not by IaC.')
param hostpool_rg string

@secure()
param adminUsername string

@secure()
param adminPassword string

@secure()
param domainJoinUsername string = ''

@secure()
param domainJoinPassword string = ''

module hosts 'modules/host.bicep' = [for i in range(0, host_count): {
  name: '${names.deployment_name}-${i + 1}'
  params: {
    location: location
    tags: tags
    vmName: names['vm_azl_${i + 1}']
    computerName: names['cn_azl_${i + 1}']
    nicName: names['nic_azl_${i + 1}']
    dcrAssocName: names.dcr_assoc
    vcpu: (length(vcpu_per_host) > i && vcpu_per_host[i] > 0) ? vcpu_per_host[i] : vcpu
    memoryMB: (length(memory_mb_per_host) > i && memory_mb_per_host[i] > 0) ? memory_mb_per_host[i] : memory_mb
    customLocationId: custom_location_id
    logicalNetworkId: logical_network_id
    dnsServers: dns_servers
    imageId: image_id
    storagePathId: storage_path_ids[i]
    dcrId: dcr_id
    joinType: join_type
    domainFqdn: domain_fqdn
    domainOuPath: domain_ou_path
    gpuDdaCount: length(gpu_dda_counts) > i ? gpu_dda_counts[i] : 0
    enableMonitoring: enable_monitoring
    adminUsername: adminUsername
    adminPassword: adminPassword
    domainJoinUsername: domainJoinUsername
    domainJoinPassword: domainJoinPassword
  }
}]

output machine_ids string[] = [for i in range(0, host_count): hosts[i].outputs.machineId]
output computer_names string[] = [for i in range(0, host_count): hosts[i].outputs.computerName]
output machine_principal_ids string[] = [for i in range(0, host_count): hosts[i].outputs.principalId]
