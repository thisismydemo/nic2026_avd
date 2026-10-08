// lz-avd — AVD landing zone (design/avd/landing-zone.md, AVD-LZ-01..14)
// Subscription-scope entry point. Parameters mirror automation/landing-zones/avd/solution.yml exactly; values arrive from
// main.generated.bicepparam (ConvertTo-NIC26BicepParam). No literal name, address, id or region lives in this file.
metadata name = 'lz-avd'
metadata description = 'AVD application landing zone: resource groups, spoke network, private DNS, FSLogix storage, gallery, identities, monitoring, governance and RBAC.'

targetScope = 'subscription'

import { builtInRoles } from 'modules/builtin-ids.bicep'

// ---------------------------------------------------------------------------------------------------------------------
// Parameters (one per manifest input, same canonical snake_case name)
// ---------------------------------------------------------------------------------------------------------------------
@description('Organization token in every name (D-006).')
param org string

@description('Lab token in every name (D-005).')
param lab_token string

@description('Azure region for every regional resource (D-010).')
param location string

@description('Short region token used in names.')
param location_short string

@description('Entra tenant id (D-002).')
param tenant_id string

@description('AVD landing-zone subscription id (D-004). Must equal the deployment subscription.')
param subscription_id_avd string

@description('Azure Local landing-zone subscription id (D-004).')
param subscription_id_azl string

@description('Parent management group (informational; policy is assigned at subscription scope, P-06).')
param management_group_id string

@description('Required tags (naming standard §3a).')
param tags object

@description('Owner e-mail for budget notifications.')
param owner_email string

@description('Name catalog resolved from solution.yml names: (contract §10). IaC never builds a name.')
param names object

@description('Existing hub VNet resource id (connectivity subscription).')
param hub_vnet_id string

@description('Hub address space.')
param hub_address_space string

@description('Existing identity spoke VNet id (privatelink zone link, P-11).')
param identity_spoke_vnet_id string

@description('Point-to-site client pool.')
param p2s_pool string

@description('On-prem session-host prefixes allowed to the private endpoint (P-08 VLAN and the Azure Local AVD lnet).')
param onprem_compute_prefixes array

@description('Existing AzureBastionSubnet prefix (admin RDP source; the jump server is covered by azl_spoke_prefix).')
param bastion_subnet_prefix string

@description('Azure Local spoke VNet id (lz-azure-local output).')
param azl_spoke_vnet_id string

@description('Azure Local spoke prefix.')
param azl_spoke_prefix string

@description('Lab Log Analytics workspace id (lz-azure-local output).')
param log_analytics_workspace_id string

@description('Operations Key Vault id (lz-azure-local output). Not read by IaC; echoed for validation only.')
param key_vault_id string

@description('Ops action group id (lz-azure-local output).')
param action_group_id string

@description('AVD spoke address space (AVD-LZ-04).')
param avd_vnet_prefix string

@description('Subnet prefixes keyed hosts, pe, imgbuild, dnsin.')
param avd_subnets object

@description('Owner decision D-029: no private endpoints. false (default) = Azure Files is reached on its public endpoint, no privatelink zone, links or resolver are created. true restores the private-endpoint design.')
param enable_private_endpoints bool = false

@description('Deploy the DNS Private Resolver inbound endpoint (P-07 option B). Ignored unless enable_private_endpoints is true.')
param enable_dns_private_resolver bool

@description('Static inbound endpoint IP inside the dnsin subnet (required when the resolver is enabled).')
param dns_resolver_inbound_ip string = ''

@description('Existing privatelink.file zone id to reuse; empty creates the lab zone (P-11).')
param privatelink_file_zone_id string = ''

@description('Also link the zone to the hub VNet.')
param link_privatelink_zone_to_hub bool = false

@description('FSLogix share names keyed profiles and odfc.')
param share_names object

@description('Provisioned size per share in GiB.')
param share_quota_gib int = 256

@description('Deploy the Recovery Services vault and protect both shares.')
param enable_backup bool = true

@description('Backup policy: schedule_time_utc (HH:mm), retention_days (environment schema shape).')
param backup_policy object

@description('Gallery image definitions (name, publisher, offer, sku, os_type, hyper_v_generation, security_type, os_state).')
param image_definitions array

@description('Monthly budget amount.')
param avd_budget_monthly int

@description('Assign the built-in Deny/Audit/Modify policies of design §2.4.')
param enable_policy_assignments bool = true

@description('Platform-owned hub peering and policy assignments require explicit ownership approval. False uses existing platform delivery.')
param deploy_platform_scope_items bool = false

@description('Object ids keyed avd_users, avd_admins, lab_operators.')
param group_object_ids object

@description('Object id of the Arc onboarding service principal; empty skips its role assignment.')
param arc_onboard_sp_object_id string = ''

// ---------------------------------------------------------------------------------------------------------------------
// Derived values (no names are built here; only ids are split)
// ---------------------------------------------------------------------------------------------------------------------
var hubVnetSegments = split(hub_vnet_id, '/')
var hubSubscriptionId = hubVnetSegments[2]
var hubResourceGroupName = hubVnetSegments[4]
var hubVnetName = last(hubVnetSegments)

var azlVnetSegments = split(azl_spoke_vnet_id, '/')
var azlSubscriptionId = azlVnetSegments[2]
var azlResourceGroupName = azlVnetSegments[4]
var azlVnetName = last(azlVnetSegments)

var createFileZone = enable_private_endpoints && empty(privatelink_file_zone_id)

var resourceGroupKeys = ['control', 'net', 'hosts', 'img', 'stor', 'mon', 'arc']
var resourceGroupNames = {
  control: names.rg_control
  net: names.rg_net
  hosts: names.rg_hosts
  img: names.rg_img
  stor: names.rg_stor
  mon: names.rg_mon
  arc: names.rg_arc
}

// Inputs that only scripts or validation consume (tenant_id, subscription ids, key_vault_id, hub_address_space, ...)
// are declared so the manifest, Bicep and Terraform accept the same generated file (contract §6);
// bicepconfig.json turns the no-unused-params rule off for that reason.

// ---------------------------------------------------------------------------------------------------------------------
// 1. Resource groups (AVM resources/resource-group 0.4.4) — design §3
// ---------------------------------------------------------------------------------------------------------------------
module resourceGroups 'br/public:avm/res/resources/resource-group:0.4.4' = [
  for key in resourceGroupKeys: {
    name: 'dep-${deployment().name}-rg-${key}'
    params: {
      name: resourceGroupNames[key]
      location: location
      tags: tags
    }
  }
]

// ---------------------------------------------------------------------------------------------------------------------
// 2. Network — design §4 (VNet, subnets, NSGs, optional DNS Private Resolver)
// ---------------------------------------------------------------------------------------------------------------------
module network 'modules/network.bicep' = {
  name: 'dep-${deployment().name}-network'
  scope: resourceGroup(names.rg_net)
  dependsOn: [resourceGroups]
  params: {
    location: location
    tags: tags
    names: names
    avd_vnet_prefix: avd_vnet_prefix
    avd_subnets: avd_subnets
    p2s_pool: p2s_pool
    onprem_compute_prefixes: onprem_compute_prefixes
    admin_source_prefixes: [bastion_subnet_prefix, azl_spoke_prefix]
    azl_spoke_prefix: azl_spoke_prefix
    log_analytics_workspace_id: log_analytics_workspace_id
    enable_dns_private_resolver: enable_private_endpoints && enable_dns_private_resolver
    dns_resolver_inbound_ip: dns_resolver_inbound_ip
  }
}

// 2a. Peerings — hub side first (gateway transit must exist before useRemoteGateways is accepted), then spoke side.
module peerHubToSpoke 'br/public:avm/res/network/virtual-network/virtual-network-peering:0.2.0' = if (deploy_platform_scope_items) {
  name: 'dep-${deployment().name}-peer-hub'
  scope: resourceGroup(hubSubscriptionId, hubResourceGroupName)
  params: {
    name: names.peer_hub_to_spoke
    localVnetName: hubVnetName
    remoteVirtualNetworkResourceId: network.outputs.spoke_vnet_id
    allowGatewayTransit: true
    allowForwardedTraffic: true
    allowVirtualNetworkAccess: true
    useRemoteGateways: false
  }
}

module peerSpokeToHub 'br/public:avm/res/network/virtual-network/virtual-network-peering:0.2.0' = {
  name: 'dep-${deployment().name}-peer-spoke-hub'
  scope: resourceGroup(names.rg_net)
  dependsOn: [peerHubToSpoke]
  params: {
    name: names.peer_spoke_to_hub
    localVnetName: names.spoke_vnet
    remoteVirtualNetworkResourceId: hub_vnet_id
    allowGatewayTransit: false
    allowForwardedTraffic: true
    allowVirtualNetworkAccess: true
    useRemoteGateways: true
  }
}

module peerAzlToSpoke 'br/public:avm/res/network/virtual-network/virtual-network-peering:0.2.0' = {
  name: 'dep-${deployment().name}-peer-azl'
  scope: resourceGroup(azlSubscriptionId, azlResourceGroupName)
  params: {
    name: names.peer_azl_to_spoke
    localVnetName: azlVnetName
    remoteVirtualNetworkResourceId: network.outputs.spoke_vnet_id
    allowGatewayTransit: false
    allowForwardedTraffic: true
    allowVirtualNetworkAccess: true
    useRemoteGateways: false
  }
}

module peerSpokeToAzl 'br/public:avm/res/network/virtual-network/virtual-network-peering:0.2.0' = {
  name: 'dep-${deployment().name}-peer-spoke-azl'
  scope: resourceGroup(names.rg_net)
  dependsOn: [peerAzlToSpoke]
  params: {
    name: names.peer_spoke_to_azl
    localVnetName: names.spoke_vnet
    remoteVirtualNetworkResourceId: azl_spoke_vnet_id
    allowGatewayTransit: false
    allowForwardedTraffic: true
    allowVirtualNetworkAccess: true
    useRemoteGateways: false
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// 3. Private DNS zone privatelink.file.core.windows.net + links — design §4.5, P-11
// ---------------------------------------------------------------------------------------------------------------------
module dns 'modules/dns.bicep' = if (createFileZone) {
  name: 'dep-${deployment().name}-dns'
  scope: resourceGroup(names.rg_net)
  params: {
    tags: tags
    names: names
    zone_name: names.file_zone
    spoke_vnet_id: network.outputs.spoke_vnet_id
    azl_spoke_vnet_id: azl_spoke_vnet_id
    identity_spoke_vnet_id: identity_spoke_vnet_id
    hub_vnet_id: hub_vnet_id
    link_hub: link_privatelink_zone_to_hub
  }
}

var fileZoneId = createFileZone ? dns!.outputs.zone_id : (enable_private_endpoints ? privatelink_file_zone_id : '')

// ---------------------------------------------------------------------------------------------------------------------
// 4. Identities — design §5.2 (host-pool UAMI in the control-plane RG; AIB identity in the images RG)
// ---------------------------------------------------------------------------------------------------------------------
module hostpoolIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'dep-${deployment().name}-id-hostpool'
  scope: resourceGroup(names.rg_control)
  dependsOn: [resourceGroups]
  params: {
    name: names.hostpool_identity
    location: location
    tags: tags
  }
}

module aibIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'dep-${deployment().name}-id-aib'
  scope: resourceGroup(names.rg_img)
  dependsOn: [resourceGroups]
  params: {
    name: names.aib_identity
    location: location
    tags: tags
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// 5. Profile storage + backup — design §7
// ---------------------------------------------------------------------------------------------------------------------
module storage 'modules/storage.bicep' = {
  name: 'dep-${deployment().name}-storage'
  scope: resourceGroup(names.rg_stor)
  dependsOn: [resourceGroups]
  params: {
    location: location
    tags: tags
    names: names
    share_names: share_names
    share_quota_gib: share_quota_gib
    subnet_pe_id: network.outputs.subnet_pe_id
    privatelink_file_zone_id: fileZoneId
    enable_private_endpoints: enable_private_endpoints
    log_analytics_workspace_id: log_analytics_workspace_id
    group_object_ids: group_object_ids
    enable_backup: enable_backup
    backup_policy: backup_policy
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// 6. Images — design §8 (gallery + definitions; AIB templates belong to avd-images)
// ---------------------------------------------------------------------------------------------------------------------
module images 'modules/images.bicep' = {
  name: 'dep-${deployment().name}-images'
  scope: resourceGroup(names.rg_img)
  dependsOn: [resourceGroups]
  params: {
    location: location
    tags: tags
    names: names
    image_definitions: image_definitions
    lab_operators_object_id: group_object_ids.lab_operators
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// 7. Monitoring — design §9 (AVD Insights DCR + alert rules in the monitoring RG)
// ---------------------------------------------------------------------------------------------------------------------
module monitoring 'modules/monitoring.bicep' = {
  name: 'dep-${deployment().name}-monitoring'
  scope: resourceGroup(names.rg_mon)
  dependsOn: [resourceGroups]
  params: {
    location: location
    tags: tags
    names: names
    log_analytics_workspace_id: log_analytics_workspace_id
    action_group_id: action_group_id
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// 8. Governance — design §2.3/§2.4 (budget, policy). Gap-fill modules: AVM budget cannot mix Actual and Forecasted
// thresholds; AVM ptn policy-assignment is management-group scoped.
// ---------------------------------------------------------------------------------------------------------------------
module budget 'modules/budget.bicep' = if (avd_budget_monthly > 0) {
  name: 'dep-${deployment().name}-budget'
  params: {
    name: names.budget
    amount: avd_budget_monthly
    contact_emails: [owner_email]
    action_group_id: action_group_id
  }
}

module policy 'modules/policy-assignments.bicep' = if (deploy_platform_scope_items && enable_policy_assignments) {
  name: 'dep-${deployment().name}-policy'
  params: {
    location: location
    names: names
    tags: tags
  }
}

module policyHostsRg 'modules/policy-assignment-rg.bicep' = if (deploy_platform_scope_items && enable_policy_assignments) {
  name: 'dep-${deployment().name}-policy-hosts'
  scope: resourceGroup(names.rg_hosts)
  dependsOn: [resourceGroups]
  params: {
    name: names.asg_no_public_ip
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// 9. RBAC — design §5.3 (only assignments whose scope this landing zone owns)
// ---------------------------------------------------------------------------------------------------------------------
module roleDefinitions 'modules/role-definitions.bicep' = {
  name: 'dep-${deployment().name}-roledefs'
  dependsOn: [resourceGroups]
  params: {
    names: names
  }
}

// Host-pool identity → Reader on the Arc machines RG (Hybrid requirement, HYB-02)
module raHostpoolReaderArc 'br/public:avm/res/authorization/role-assignment/rg-scope:0.1.1' = {
  name: 'dep-${deployment().name}-ra-hp-arc'
  scope: resourceGroup(names.rg_arc)
  dependsOn: [resourceGroups]
  params: {
    principalId: hostpoolIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionIdOrName: 'Reader'
    description: 'AVD host-pool identity reads Arc machines (deploy-azure-virtual-desktop-hybrid).'
  }
}

var loginScopes = ['hosts', 'arc']

module raUsersVmLogin 'br/public:avm/res/authorization/role-assignment/rg-scope:0.1.1' = [
  for key in loginScopes: {
    name: 'dep-${deployment().name}-ra-users-${key}'
    scope: resourceGroup(resourceGroupNames[key])
    dependsOn: [resourceGroups]
    params: {
      principalId: group_object_ids.avd_users
      principalType: 'Group'
      roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles.virtualMachineUserLogin)
    }
  }
]

module raAdminsVmLogin 'br/public:avm/res/authorization/role-assignment/rg-scope:0.1.1' = [
  for key in loginScopes: {
    name: 'dep-${deployment().name}-ra-admins-${key}'
    scope: resourceGroup(resourceGroupNames[key])
    dependsOn: [resourceGroups]
    params: {
      principalId: group_object_ids.avd_admins
      principalType: 'Group'
      roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles.virtualMachineAdministratorLogin)
    }
  }
]

module raAdminsDvContributor 'br/public:avm/res/authorization/role-assignment/rg-scope:0.1.1' = {
  name: 'dep-${deployment().name}-ra-admins-dvc'
  scope: resourceGroup(names.rg_control)
  dependsOn: [resourceGroups]
  params: {
    principalId: group_object_ids.avd_admins
    principalType: 'Group'
    roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles.desktopVirtualizationContributor)
  }
}

module raAdminsDvReader 'br/public:avm/res/authorization/role-assignment/sub-scope:0.1.1' = {
  name: 'dep-${deployment().name}-ra-admins-dvr'
  params: {
    principalId: group_object_ids.avd_admins
    principalType: 'Group'
    roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles.desktopVirtualizationReader)
    location: location
  }
}

module raAibImage 'br/public:avm/res/authorization/role-assignment/rg-scope:0.1.1' = {
  name: 'dep-${deployment().name}-ra-aib-img'
  scope: resourceGroup(names.rg_img)
  params: {
    principalId: aibIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionIdOrName: roleDefinitions.outputs.role_aib_image_id
  }
}

module raAibNetwork 'br/public:avm/res/authorization/role-assignment/rg-scope:0.1.1' = {
  name: 'dep-${deployment().name}-ra-aib-net'
  scope: resourceGroup(names.rg_net)
  params: {
    principalId: aibIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionIdOrName: roleDefinitions.outputs.role_aib_network_id
  }
}

module raArcOnboarding 'br/public:avm/res/authorization/role-assignment/rg-scope:0.1.1' = if (!empty(arc_onboard_sp_object_id)) {
  name: 'dep-${deployment().name}-ra-arc-onboard'
  scope: resourceGroup(names.rg_arc)
  dependsOn: [resourceGroups]
  params: {
    principalId: arc_onboard_sp_object_id
    principalType: 'ServicePrincipal'
    roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles.azureConnectedMachineOnboarding)
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Outputs (identical set in solution.yml and terraform/outputs.tf)
// ---------------------------------------------------------------------------------------------------------------------
output rg_names object = resourceGroupNames
output arc_rg_name string = names.rg_arc
output hostpool_rg string = names.rg_control
output azl_spoke_vnet_name string = names.azl_spoke_vnet
output azl_spoke_vnet_name_matches bool = toLower(azlVnetName) == toLower(names.azl_spoke_vnet)
output spoke_vnet_id string = network.outputs.spoke_vnet_id
output subnet_hosts_id string = network.outputs.subnet_hosts_id
output subnet_pe_id string = network.outputs.subnet_pe_id
output subnet_imgbuild_id string = network.outputs.subnet_imgbuild_id
output subnet_dnsin_id string = network.outputs.subnet_dnsin_id
output dns_resolver_id string = network.outputs.dns_resolver_id
output dns_resolver_inbound_ip string = network.outputs.dns_resolver_inbound_ip
output privatelink_file_zone_id string = fileZoneId
output storage_account_id string = storage.outputs.storage_account_id
output storage_account_name string = storage.outputs.storage_account_name
output fslogix_profile_unc string = storage.outputs.fslogix_profile_unc
output fslogix_odfc_unc string = storage.outputs.fslogix_odfc_unc
output private_endpoint_id string = storage.outputs.private_endpoint_id
output recovery_vault_id string = storage.outputs.recovery_vault_id
output gallery_id string = images.outputs.gallery_id
output image_definition_ids array = images.outputs.image_definition_ids
output hostpool_identity_id string = hostpoolIdentity.outputs.resourceId
output hostpool_identity_principal_id string = hostpoolIdentity.outputs.principalId
output hostpool_identity_client_id string = hostpoolIdentity.outputs.clientId
output aib_identity_id string = aibIdentity.outputs.resourceId
output aib_identity_principal_id string = aibIdentity.outputs.principalId
output dcr_avd_insights_id string = monitoring.outputs.dcr_id
