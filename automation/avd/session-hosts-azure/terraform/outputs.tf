output "session_host_ids" {
  value = [for i in range(var.host_count) : azurerm_windows_virtual_machine.host[tostring(i + 1)].id]
}

output "session_host_names" {
  value = [for i in range(var.host_count) : local.hosts[tostring(i + 1)].computer_name]
}

output "vm_principal_ids" {
  value = [for i in range(var.host_count) : azurerm_windows_virtual_machine.host[tostring(i + 1)].identity[0].principal_id]
}
