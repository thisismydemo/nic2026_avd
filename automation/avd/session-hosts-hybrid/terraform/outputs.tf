output "arc_rg_name" {
  value = data.azurerm_resource_group.arc.name
}

output "arc_rg_id" {
  value = data.azurerm_resource_group.arc.id
}

output "hostpool_hybrid_name" {
  value = var.names.hostpool_hybrid
}

output "hostpool_rg" {
  value = var.names.rg_control
}

output "expected_host_names" {
  value = local.expected_host_names
}

output "arc_machine_ids" {
  value = [for machine in data.azapi_resource.arc_machines : machine.id]
}

output "ama_extension_ids" {
  value = [for extension in azapi_resource.ama : extension.id]
}

output "dcr_association_ids" {
  value = [for association in azapi_resource.dcr_association : association.id]
}

output "role_assignment_count" {
  value = length(azurerm_role_assignment.arc)
}
