locals {
  hosts = {
    for i in range(var.host_count) : tostring(i + 1) => {
      vm_name       = var.names["vm_azure_${i + 1}"]
      computer_name = var.names["cn_azure_${i + 1}"]
      nic_name      = var.names["nic_azure_${i + 1}"]
      osdisk_name   = var.names["osdisk_azure_${i + 1}"]
      zone          = var.session_host_zones[i % length(var.session_host_zones)]
    }
  }
}

resource "azurerm_network_interface" "host" {
  for_each                       = local.hosts
  name                           = each.value.nic_name
  location                       = var.location
  resource_group_name            = var.resource_group_name
  accelerated_networking_enabled = true
  tags                           = var.tags

  ip_configuration {
    name                          = "ipconfig01"
    subnet_id                     = var.hosts_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "host" {
  for_each                   = local.hosts
  name                       = each.value.vm_name
  computer_name              = each.value.computer_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  size                       = var.session_host_sku_azure
  zone                       = tostring(each.value.zone)
  admin_username             = var.local_admin_username
  admin_password             = var.local_admin_password
  network_interface_ids      = [azurerm_network_interface.host[each.key].id]
  source_image_id            = var.image_version_id
  license_type               = "Windows_Client"
  secure_boot_enabled        = true
  vtpm_enabled               = true
  encryption_at_host_enabled = var.encryption_at_host
  patch_mode                 = "Manual"
  automatic_updates_enabled  = false
  provision_vm_agent         = true
  tags                       = var.tags

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    name                 = each.value.osdisk_name
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_sku
    disk_size_gb         = var.os_disk_size_gb
  }

  boot_diagnostics {}
}

resource "azurerm_virtual_machine_extension" "aad_join" {
  for_each                   = local.hosts
  name                       = "AADLoginForWindows"
  virtual_machine_id         = azurerm_windows_virtual_machine.host[each.key].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADLoginForWindows"
  type_handler_version       = "2.0"
  auto_upgrade_minor_version = true
}

resource "azurerm_virtual_machine_extension" "monitor" {
  for_each                   = local.hosts
  name                       = "AzureMonitorWindowsAgent"
  virtual_machine_id         = azurerm_windows_virtual_machine.host[each.key].id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorWindowsAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
  depends_on                 = [azurerm_virtual_machine_extension.aad_join]
}

resource "azurerm_monitor_data_collection_rule_association" "host" {
  for_each                = local.hosts
  name                    = var.names["dcr_assoc"]
  target_resource_id      = azurerm_windows_virtual_machine.host[each.key].id
  data_collection_rule_id = var.dcr_id
  depends_on              = [azurerm_virtual_machine_extension.monitor]
}
