# avd-control-plane — workspace, three host pools, desktop application groups, scaling plan, diagnostics.
# Host pools are azapi on a preview API on purpose: the stable versions only allow a system-assigned identity and the design
# uses one user-assigned identity on all three pools. No registration token is created, stored or output (K-7).
locals {
  host_pools = {
    azure = {
      name           = var.names["hostpool_azure"]
      app_group_name = var.names["appgroup_azure"]
      settings       = var.host_pools.azure
      group_id       = var.group_object_ids.avd_azure
    }
    azl = {
      name           = var.names["hostpool_azl"]
      app_group_name = var.names["appgroup_azl"]
      settings       = var.host_pools.azl
      group_id       = var.group_object_ids.avd_azl
    }
    hybrid = {
      name           = var.names["hostpool_hybrid"]
      app_group_name = var.names["appgroup_hybrid"]
      settings       = var.host_pools.hybrid
      group_id       = var.group_object_ids.avd_hybrid
    }
  }

  resource_tags = merge(var.tags, {
    workload   = "avd"
    managed-by = "terraform"
  })
}

data "azurerm_resource_group" "control" {
  name = var.names["rg_control"]
}

data "azurerm_user_assigned_identity" "hostpool" {
  name                = var.names["hostpool_identity"]
  resource_group_name = data.azurerm_resource_group.control.name
}

resource "azapi_resource" "host_pool" {
  for_each = local.host_pools

  type      = "Microsoft.DesktopVirtualization/hostPools@2025-11-01-preview"
  name      = each.value.name
  parent_id = data.azurerm_resource_group.control.id
  location  = var.location
  tags      = local.resource_tags

  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.hostpool.id]
  }

  body = {
    properties = {
      hostPoolType          = each.value.settings.type
      loadBalancerType      = each.value.settings.load_balancer
      maxSessionLimit       = each.value.settings.max_session_limit
      startVMOnConnect      = each.value.settings.start_vm_on_connect
      validationEnvironment = each.value.settings.validation_environment
      friendlyName          = each.value.settings.friendly_name
      preferredAppGroupType = each.value.settings.preferred_app_group_type
      customRdpProperty     = var.rdp_properties
    }
  }
}

resource "azurerm_virtual_desktop_application_group" "desktop" {
  for_each = local.host_pools

  name                = each.value.app_group_name
  location            = var.location
  resource_group_name = data.azurerm_resource_group.control.name
  type                = "Desktop"
  host_pool_id        = azapi_resource.host_pool[each.key].id
  tags                = local.resource_tags
}

resource "azurerm_role_assignment" "desktop_user" {
  for_each = local.host_pools

  scope                = azurerm_virtual_desktop_application_group.desktop[each.key].id
  role_definition_name = "Desktop Virtualization User"
  principal_id         = each.value.group_id
  principal_type       = "Group"
}

resource "azurerm_virtual_desktop_workspace" "control" {
  name                = var.names["workspace"]
  location            = var.location
  resource_group_name = data.azurerm_resource_group.control.name
  friendly_name       = var.workspace_friendly_name
  tags                = local.resource_tags
}

resource "azurerm_virtual_desktop_workspace_application_group_association" "desktop" {
  for_each = local.host_pools

  workspace_id         = azurerm_virtual_desktop_workspace.control.id
  application_group_id = azurerm_virtual_desktop_application_group.desktop[each.key].id
}

resource "azurerm_virtual_desktop_scaling_plan" "control" {
  count = var.enable_scaling_plan ? 1 : 0

  name                = var.names["scaling_plan_azure"]
  location            = var.location
  resource_group_name = data.azurerm_resource_group.control.name
  time_zone           = var.scaling_plan.time_zone
  exclusion_tag       = var.scaling_plan.exclusion_tag
  tags                = local.resource_tags

  dynamic "schedule" {
    for_each = var.scaling_plan.schedules

    content {
      name                                 = schedule.value.name
      days_of_week                         = schedule.value.days_of_week
      ramp_up_start_time                   = format("%02d:%02d", schedule.value.ramp_up_start_time.hour, schedule.value.ramp_up_start_time.minute)
      ramp_up_load_balancing_algorithm     = schedule.value.ramp_up_load_balancing_algorithm
      ramp_up_minimum_hosts_percent        = schedule.value.ramp_up_minimum_hosts_percent
      ramp_up_capacity_threshold_percent   = schedule.value.ramp_up_capacity_threshold_percent
      peak_start_time                      = format("%02d:%02d", schedule.value.peak_start_time.hour, schedule.value.peak_start_time.minute)
      peak_load_balancing_algorithm        = schedule.value.peak_load_balancing_algorithm
      ramp_down_start_time                 = format("%02d:%02d", schedule.value.ramp_down_start_time.hour, schedule.value.ramp_down_start_time.minute)
      ramp_down_load_balancing_algorithm   = schedule.value.ramp_down_load_balancing_algorithm
      ramp_down_minimum_hosts_percent      = schedule.value.ramp_down_minimum_hosts_percent
      ramp_down_capacity_threshold_percent = schedule.value.ramp_down_capacity_threshold_percent
      ramp_down_force_logoff_users         = schedule.value.ramp_down_force_logoff_users
      ramp_down_wait_time_minutes          = schedule.value.ramp_down_wait_time_minutes
      ramp_down_notification_message       = schedule.value.ramp_down_notification_message
      ramp_down_stop_hosts_when            = schedule.value.ramp_down_stop_hosts_when
      off_peak_start_time                  = format("%02d:%02d", schedule.value.off_peak_start_time.hour, schedule.value.off_peak_start_time.minute)
      off_peak_load_balancing_algorithm    = schedule.value.off_peak_load_balancing_algorithm
    }
  }
}

resource "azurerm_virtual_desktop_scaling_plan_host_pool_association" "assigned" {
  for_each = var.enable_scaling_plan ? toset(var.scaling_plan.assigned_pools) : toset([])

  host_pool_id    = azapi_resource.host_pool[each.key].id
  scaling_plan_id = azurerm_virtual_desktop_scaling_plan.control[0].id
  enabled         = true

  # The AVD service principal needs Desktop Virtualization Power On Off Contributor before autoscale can act on the pool.
  depends_on = [azurerm_role_assignment.power_on_off]
}

resource "azurerm_monitor_diagnostic_setting" "workspace" {
  count = var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "${var.names["workspace"]}-diagnostics"
  target_resource_id         = azurerm_virtual_desktop_workspace.control.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }
}

resource "azurerm_monitor_diagnostic_setting" "host_pool" {
  for_each = var.log_analytics_workspace_id != "" ? local.host_pools : {}

  name                       = "${each.value.name}-diagnostics"
  target_resource_id         = azapi_resource.host_pool[each.key].id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }
}

resource "azurerm_monitor_diagnostic_setting" "scaling_plan" {
  count = var.enable_scaling_plan && var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "${var.names["scaling_plan_azure"]}-diagnostics"
  target_resource_id         = azurerm_virtual_desktop_scaling_plan.control[0].id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }
}

resource "azurerm_role_assignment" "power_on_off" {
  count = var.avd_service_principal_object_id != "" ? 1 : 0

  scope                = "/subscriptions/${var.subscription_id_avd}"
  role_definition_name = "Desktop Virtualization Power On Off Contributor"
  principal_id         = var.avd_service_principal_object_id
  principal_type       = "ServicePrincipal"
}
