targetScope = 'resourceGroup'

@description('Organization identifier; retained for manifest parity.')
param org string

@description('Lab token; retained for manifest parity.')
param lab_token string

param location string

@description('Short location code; retained for manifest parity.')
param location_short string

@description('Tenant ID; retained for manifest parity.')
param tenant_id string

@description('AVD subscription ID; retained for manifest parity. The deployment subscription is authoritative.')
param subscription_id_avd string

@description('Deployment tags; retained for manifest parity.')
param tags object

@description('Catalog names, including dcr_assoc for the DCR association.')
param names object

@description('Script-only configuration retained for manifest parity.')
param cluster_name string
param hybrid_csv_path string
param compute_switch_name string
param hybrid_vlan_id int
param hybrid_vcpu int
param hybrid_memory_gb int
param hybrid_disk_gb int
param hybrid_vms array
param arc_tags object
param dhcp_reservations array
param hybrid_image_vhdx string
param dns_resolver_inbound_ip string
param secondary_dns_ip string
param registration_token_ttl_hours int
param share_names object
param shortpath_managed_port int
param patch_channel string

param dcr_avd_insights_id string = ''
param hostpool_identity_principal_id string = ''
param enable_arc_extensions bool = false
param manage_arc_rg_rbac bool = false
param assign_vm_login_roles bool = true
param group_object_ids object
param arc_onboard_sp_object_id string = ''
@minLength(3)
#disable-next-line secure-secrets-in-params // a Key Vault secret-name prefix, not a secret; kept for manifest parity
param secret_name_prefix string

// Built-in Azure role definition IDs. Keep all literal role GUIDs here.
var roles = {
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
  vmUserLogin: 'fb879df8-f326-4884-b1cf-06f3ad86be52' // Virtual Machine User Login
  vmAdministratorLogin: '1c0163c0-47e6-4577-8991-ea5c82e286e4' // Virtual Machine Administrator Login
  connectedMachineOnboarding: 'b64e21ea-ac4e-4cdf-9dc9-5b892992bee7' // Azure Connected Machine Onboarding
}

var expectedHostNames = [
  names.sessionhost_hv01
  names.sessionhost_hv02
]

var dcrId = !empty(dcr_avd_insights_id)
  ? dcr_avd_insights_id
  : resourceId(subscription().subscriptionId, names.rg_mon, 'Microsoft.Insights/dataCollectionRules', names.dcr_avd_insights)

resource hostpoolIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = if (manage_arc_rg_rbac && empty(hostpool_identity_principal_id)) {
  name: names.hostpool_identity
  scope: resourceGroup(names.rg_control)
}

// Role-assignment names must be known at the start of the deployment, so they key on the identity name, not its looked-up principal id.
var hostpoolAssignmentKey = !empty(hostpool_identity_principal_id) ? hostpool_identity_principal_id : names.hostpool_identity

var hostpoolPrincipalId = !empty(hostpool_identity_principal_id)
  ? hostpool_identity_principal_id
  : (manage_arc_rg_rbac ? hostpoolIdentity!.properties.principalId : '')

resource arcMachines 'Microsoft.HybridCompute/machines@2025-06-01' existing = [for hostName in expectedHostNames: {
  name: hostName
}]

resource amaExtensions 'Microsoft.HybridCompute/machines/extensions@2025-06-01' = [for (hostName, index) in expectedHostNames: if (enable_arc_extensions) {
  parent: arcMachines[index]
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}]

resource dcrAssociations 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = [for (hostName, index) in expectedHostNames: if (enable_arc_extensions) {
  scope: arcMachines[index]
  name: names.dcr_assoc
  properties: {
    dataCollectionRuleId: dcrId
  }
  dependsOn: [
    amaExtensions[index]
  ]
}]

resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (manage_arc_rg_rbac) {
  name: guid(resourceGroup().id, hostpoolAssignmentKey, roles.reader)
  properties: {
    principalId: hostpoolPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.reader)
  }
}

resource vmUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (manage_arc_rg_rbac && assign_vm_login_roles) {
  name: guid(resourceGroup().id, group_object_ids.avd_users, roles.vmUserLogin)
  properties: {
    principalId: group_object_ids.avd_users
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.vmUserLogin)
  }
}

resource vmAdministratorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (manage_arc_rg_rbac && assign_vm_login_roles) {
  name: guid(resourceGroup().id, group_object_ids.avd_admins, roles.vmAdministratorLogin)
  properties: {
    principalId: group_object_ids.avd_admins
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.vmAdministratorLogin)
  }
}

resource onboardingAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (manage_arc_rg_rbac && !empty(arc_onboard_sp_object_id)) {
  name: guid(resourceGroup().id, arc_onboard_sp_object_id, roles.connectedMachineOnboarding)
  properties: {
    principalId: arc_onboard_sp_object_id
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.connectedMachineOnboarding)
  }
}

output arc_rg_name string = resourceGroup().name
output arc_rg_id string = resourceGroup().id
output hostpool_hybrid_name string = names.hostpool_hybrid
output hostpool_rg string = names.rg_control
output expected_host_names array = expectedHostNames
output arc_machine_ids array = [for (hostName, index) in (enable_arc_extensions ? expectedHostNames : []): arcMachines[index].id]
output ama_extension_ids array = [for (hostName, index) in (enable_arc_extensions ? expectedHostNames : []): amaExtensions[index].id]
output dcr_association_ids array = [for (hostName, index) in (enable_arc_extensions ? expectedHostNames : []): dcrAssociations[index].id]
output role_assignment_count int = manage_arc_rg_rbac
  ? 1 + (assign_vm_login_roles ? 2 : 0) + (!empty(arc_onboard_sp_object_id) ? 1 : 0)
  : 0
