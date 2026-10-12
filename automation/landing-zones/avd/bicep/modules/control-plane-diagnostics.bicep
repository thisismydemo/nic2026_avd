// AVD control-plane diagnostic settings to the lab workspace (design/avd/landing-zone.md §9.3, AVD-LZ-12, D-054).
// Resource-group scope (the control-plane resource group). Same setting names and content as avd/control-plane/bicep
// (name = guid(resource id, workspace id), allLogs category group), so a later control-plane run finds them unchanged.
// Exists so the monitoring can be moved to another workspace without re-deploying the host pools (their live settings
// belong to the AVD build). Diagnostic settings to the previous workspace are left in place (additive).
targetScope = 'resourceGroup'

param log_analytics_workspace_id string
param workspace_name string
param host_pool_names array
param scaling_plan_names array = []

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2025-10-10' existing = {
  name: workspace_name
}

resource hostPools 'Microsoft.DesktopVirtualization/hostPools@2025-10-10' existing = [for n in host_pool_names: {
  name: n
}]

resource scalingPlans 'Microsoft.DesktopVirtualization/scalingPlans@2025-10-10' existing = [for n in scaling_plan_names: {
  name: n
}]

// Microsoft.Insights/diagnosticSettings@2021-05-01-preview: the version that supports category groups (allLogs).
#disable-next-line use-recent-api-versions
resource workspaceDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: guid(workspace.id, log_analytics_workspace_id)
  scope: workspace
  properties: {
    workspaceId: log_analytics_workspace_id
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}

#disable-next-line use-recent-api-versions
resource hostPoolDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [for (n, i) in host_pool_names: {
  name: guid(hostPools[i].id, log_analytics_workspace_id)
  scope: hostPools[i]
  properties: {
    workspaceId: log_analytics_workspace_id
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}]

#disable-next-line use-recent-api-versions
resource scalingPlanDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [for (n, i) in scaling_plan_names: {
  name: guid(scalingPlans[i].id, log_analytics_workspace_id)
  scope: scalingPlans[i]
  properties: {
    workspaceId: log_analytics_workspace_id
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}]

output workspace_diagnostic_setting_id string = workspaceDiagnostics.id
output host_pool_diagnostic_setting_ids array = [for (n, i) in host_pool_names: hostPoolDiagnostics[i].id]
output scaling_plan_diagnostic_setting_ids array = [for (n, i) in scaling_plan_names: scalingPlanDiagnostics[i].id]
