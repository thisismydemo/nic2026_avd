output "workspace_id" {
  description = "Resource ID of the AVD workspace."
  value       = azurerm_virtual_desktop_workspace.control.id
}

output "workspace_name" {
  description = "Name of the AVD workspace."
  value       = azurerm_virtual_desktop_workspace.control.name
}

output "hostpool_ids" {
  description = "Host-pool resource IDs keyed by pool."
  value       = { for key, pool in azapi_resource.host_pool : key => pool.id }
}

output "hostpool_names" {
  description = "Host-pool names keyed by pool."
  value       = { for key, pool in azapi_resource.host_pool : key => pool.name }
}

output "application_group_ids" {
  description = "Desktop application-group resource IDs keyed by pool."
  value       = { for key, group in azurerm_virtual_desktop_application_group.desktop : key => group.id }
}

output "scaling_plan_id" {
  description = "Scaling-plan resource ID, or an empty string when disabled."
  value       = var.enable_scaling_plan ? azurerm_virtual_desktop_scaling_plan.control[0].id : ""
}

output "hostpool_rg" {
  description = "Resource group containing the host pools."
  value       = data.azurerm_resource_group.control.name
}
