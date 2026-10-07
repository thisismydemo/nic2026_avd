// avd-control-plane — AVD workspace, three host pools, desktop application groups, scaling plan, diagnostics.
// Resource-group scope (the resource group is created by lz-avd). Parameters mirror solution.yml.
// Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by deepseek-v4-pro and gpt-6-astra (see design/shared/verification-log.md).
// Registration tokens are never created, stored or output here (K-7).
targetScope = 'resourceGroup'

param org string
param lab_token string
param location string
param location_short string
param tenant_id string
param subscription_id_avd string
param subscription_id_azl string
param tags object
param names object
param host_pools object
param rdp_properties string
param scaling_plan object
param enable_scaling_plan bool = true
param workspace_friendly_name string
param group_object_ids object
param avd_service_principal_object_id string = ''
param log_analytics_workspace_id string

var resourceTags = union(tags, {
  workload: 'avd'
  'managed-by': 'bicep'
})

var desktopVirtualizationUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')

var hostPoolIds = {
  azure: azureHostPool.id
  azl: azlHostPool.id
  hybrid: hybridHostPool.id
}

// gap-fill: Use the existing managed identity without creating or modifying it.
resource hostPoolIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  name: names.hostpool_identity
}

// gap-fill: preview API on purpose — the stable 2024-04-03 type only allows SystemAssigned; user-assigned identity needs a preview version (Learn: hostPools 2025-11-01-preview).
resource azureHostPool 'Microsoft.DesktopVirtualization/hostPools@2025-11-01-preview' = {
  name: names.hostpool_azure
  location: location
  tags: resourceTags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${hostPoolIdentity.id}': {}
    }
  }
  properties: {
    hostPoolType: host_pools.azure.type
    loadBalancerType: host_pools.azure.load_balancer
    maxSessionLimit: host_pools.azure.max_session_limit
    startVMOnConnect: host_pools.azure.start_vm_on_connect
    validationEnvironment: host_pools.azure.validation_environment
    friendlyName: host_pools.azure.friendly_name
    preferredAppGroupType: host_pools.azure.preferred_app_group_type
    customRdpProperty: rdp_properties
  }
}

// gap-fill: preview API on purpose — the stable 2024-04-03 type only allows SystemAssigned; user-assigned identity needs a preview version (Learn: hostPools 2025-11-01-preview).
resource azlHostPool 'Microsoft.DesktopVirtualization/hostPools@2025-11-01-preview' = {
  name: names.hostpool_azl
  location: location
  tags: resourceTags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${hostPoolIdentity.id}': {}
    }
  }
  properties: {
    hostPoolType: host_pools.azl.type
    loadBalancerType: host_pools.azl.load_balancer
    maxSessionLimit: host_pools.azl.max_session_limit
    startVMOnConnect: host_pools.azl.start_vm_on_connect
    validationEnvironment: host_pools.azl.validation_environment
    friendlyName: host_pools.azl.friendly_name
    preferredAppGroupType: host_pools.azl.preferred_app_group_type
    customRdpProperty: rdp_properties
  }
}

// gap-fill: preview API on purpose — the stable 2024-04-03 type only allows SystemAssigned; user-assigned identity needs a preview version (Learn: hostPools 2025-11-01-preview).
resource hybridHostPool 'Microsoft.DesktopVirtualization/hostPools@2025-11-01-preview' = {
  name: names.hostpool_hybrid
  location: location
  tags: resourceTags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${hostPoolIdentity.id}': {}
    }
  }
  properties: {
    hostPoolType: host_pools.hybrid.type
    loadBalancerType: host_pools.hybrid.load_balancer
    maxSessionLimit: host_pools.hybrid.max_session_limit
    startVMOnConnect: host_pools.hybrid.start_vm_on_connect
    validationEnvironment: host_pools.hybrid.validation_environment
    friendlyName: host_pools.hybrid.friendly_name
    preferredAppGroupType: host_pools.hybrid.preferred_app_group_type
    customRdpProperty: rdp_properties
  }
}

// gap-fill: Define a Desktop application group for its specific host pool.
resource azureAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2025-10-10' = {
  name: names.appgroup_azure
  location: location
  tags: resourceTags
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: azureHostPool.id
  }
}

// gap-fill: Define a Desktop application group for its specific host pool.
resource azlAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2025-10-10' = {
  name: names.appgroup_azl
  location: location
  tags: resourceTags
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: azlHostPool.id
  }
}

// gap-fill: Define a Desktop application group for its specific host pool.
resource hybridAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2025-10-10' = {
  name: names.appgroup_hybrid
  location: location
  tags: resourceTags
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: hybridHostPool.id
  }
}

// gap-fill: Scope the built-in Desktop Virtualization User role to this application group.
resource azureUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(azureAppGroup.id, group_object_ids.avd_azure, desktopVirtualizationUserRoleId)
  scope: azureAppGroup
  properties: {
    roleDefinitionId: desktopVirtualizationUserRoleId
    principalId: group_object_ids.avd_azure
    principalType: 'Group'
  }
}

// gap-fill: Scope the built-in Desktop Virtualization User role to this application group.
resource azlUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(azlAppGroup.id, group_object_ids.avd_azl, desktopVirtualizationUserRoleId)
  scope: azlAppGroup
  properties: {
    roleDefinitionId: desktopVirtualizationUserRoleId
    principalId: group_object_ids.avd_azl
    principalType: 'Group'
  }
}

// gap-fill: Scope the built-in Desktop Virtualization User role to this application group.
resource hybridUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(hybridAppGroup.id, group_object_ids.avd_hybrid, desktopVirtualizationUserRoleId)
  scope: hybridAppGroup
  properties: {
    roleDefinitionId: desktopVirtualizationUserRoleId
    principalId: group_object_ids.avd_hybrid
    principalType: 'Group'
  }
}

// gap-fill: Reference all three Desktop application groups from one workspace.
resource workspace 'Microsoft.DesktopVirtualization/workspaces@2025-10-10' = {
  name: names.workspace
  location: location
  tags: resourceTags
  properties: {
    friendlyName: workspace_friendly_name
    applicationGroupReferences: [
      azureAppGroup.id
      azlAppGroup.id
      hybridAppGroup.id
    ]
  }
}

// gap-fill: Map the supplied schedule fields and selected host pools into a pooled scaling plan.
resource pooledScalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2025-10-10' = if (enable_scaling_plan) {
  // The AVD service principal needs Desktop Virtualization Power On Off Contributor before autoscale can act on a pool.
  dependsOn: [servicePrincipalPowerRole]
  name: names.scaling_plan_azure
  location: location
  tags: resourceTags
  properties: {
    hostPoolType: 'Pooled'
    timeZone: scaling_plan.time_zone
    exclusionTag: scaling_plan.exclusion_tag
    hostPoolReferences: [for pool in scaling_plan.assigned_pools: {
      hostPoolArmPath: hostPoolIds[pool]
      scalingPlanEnabled: true
    }]
    schedules: [for schedule in scaling_plan.schedules: {
      name: schedule.name
      daysOfWeek: schedule.days_of_week
      rampUpStartTime: schedule.ramp_up_start_time
      rampUpLoadBalancingAlgorithm: schedule.ramp_up_load_balancing_algorithm
      rampUpMinimumHostsPct: schedule.ramp_up_minimum_hosts_percent
      rampUpCapacityThresholdPct: schedule.ramp_up_capacity_threshold_percent
      peakStartTime: schedule.peak_start_time
      peakLoadBalancingAlgorithm: schedule.peak_load_balancing_algorithm
      rampDownStartTime: schedule.ramp_down_start_time
      rampDownLoadBalancingAlgorithm: schedule.ramp_down_load_balancing_algorithm
      rampDownMinimumHostsPct: schedule.ramp_down_minimum_hosts_percent
      rampDownCapacityThresholdPct: schedule.ramp_down_capacity_threshold_percent
      rampDownForceLogoffUsers: schedule.ramp_down_force_logoff_users
      rampDownWaitTimeMinutes: schedule.ramp_down_wait_time_minutes
      rampDownNotificationMessage: schedule.ramp_down_notification_message
      rampDownStopHostsWhen: schedule.ramp_down_stop_hosts_when
      offPeakStartTime: schedule.off_peak_start_time
      offPeakLoadBalancingAlgorithm: schedule.off_peak_load_balancing_algorithm
    }]
  }
}

// gap-fill: allLogs category group (the AVM default) instead of hard-coded category names: includes Feed, Connection, Autoscale, SessionHostManagement and picks up new tables.
resource workspaceDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(log_analytics_workspace_id)) {
  name: guid(workspace.id, log_analytics_workspace_id)
  scope: workspace
  properties: {
    workspaceId: log_analytics_workspace_id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

// gap-fill: host-pool diagnostics (allLogs; includes the pooled Autoscale logs).
resource azureHostPoolDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(log_analytics_workspace_id)) {
  name: guid(azureHostPool.id, log_analytics_workspace_id)
  scope: azureHostPool
  properties: {
    workspaceId: log_analytics_workspace_id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

// gap-fill: host-pool diagnostics (allLogs; includes the pooled Autoscale logs).
resource azlHostPoolDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(log_analytics_workspace_id)) {
  name: guid(azlHostPool.id, log_analytics_workspace_id)
  scope: azlHostPool
  properties: {
    workspaceId: log_analytics_workspace_id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

// gap-fill: host-pool diagnostics (allLogs; includes the pooled Autoscale logs).
resource hybridHostPoolDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(log_analytics_workspace_id)) {
  name: guid(hybridHostPool.id, log_analytics_workspace_id)
  scope: hybridHostPool
  properties: {
    workspaceId: log_analytics_workspace_id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

// gap-fill: scaling-plan diagnostics (allLogs) when the scaling plan exists.
resource scalingPlanDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (enable_scaling_plan && !empty(log_analytics_workspace_id)) {
  name: guid(pooledScalingPlan.id, log_analytics_workspace_id)
  scope: pooledScalingPlan
  properties: {
    workspaceId: log_analytics_workspace_id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

module servicePrincipalPowerRole './modules/sub-role-assignment.bicep' = if (!empty(avd_service_principal_object_id)) {
  name: guid(subscription_id_avd, avd_service_principal_object_id)
  scope: subscription(subscription_id_avd)
  params: {
    avd_service_principal_object_id: avd_service_principal_object_id
  }
}

output workspace_id string = workspace.id
output workspace_name string = workspace.name
output hostpool_ids object = hostPoolIds
output hostpool_names object = {
  azure: azureHostPool.name
  azl: azlHostPool.name
  hybrid: hybridHostPool.name
}
output application_group_ids object = {
  azure: azureAppGroup.id
  azl: azlAppGroup.id
  hybrid: hybridAppGroup.id
}
output scaling_plan_id string = enable_scaling_plan ? pooledScalingPlan.id : ''
output hostpool_rg string = resourceGroup().name
