output "machine_ids" {
  value = [for i in range(var.host_count) : azapi_resource.machine[tostring(i)].id]
}

output "computer_names" {
  value = [for i in range(var.host_count) : local.hosts[tostring(i)].computer]
}

output "machine_principal_ids" {
  value = [for i in range(var.host_count) : azapi_resource.machine[tostring(i)].identity[0].principal_id]
}
