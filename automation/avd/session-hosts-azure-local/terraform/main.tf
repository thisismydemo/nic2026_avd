locals {
  hosts = {
    for i in range(var.host_count) : tostring(i) => {
      machine  = var.names["vm_azl_${i + 1}"]
      computer = var.names["cn_azl_${i + 1}"]
      nic      = var.names["nic_azl_${i + 1}"]
    }
  }
  resource_group_id = "/subscriptions/${var.subscription_id_azl}/resourceGroups/${var.resource_group_name}"
}

resource "azapi_resource" "machine" {
  for_each  = local.hosts
  type      = "Microsoft.HybridCompute/machines@2025-06-01"
  name      = each.value.machine
  parent_id = local.resource_group_id
  location  = var.location
  tags      = var.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "HCI"
  }
}

resource "azapi_resource" "nic" {
  for_each  = local.hosts
  type      = "Microsoft.AzureStackHCI/networkInterfaces@2024-01-01"
  name      = each.value.nic
  parent_id = local.resource_group_id
  location  = var.location
  tags      = var.tags

  body = {
    extendedLocation = {
      type = "CustomLocation"
      name = var.custom_location_id
    }
    properties = {
      ipConfigurations = [{
        name = "ipconfig1"
        properties = {
          subnet = { id = var.logical_network_id }
        }
      }]
    }
  }
}

resource "azapi_resource" "vmi" {
  for_each  = local.hosts
  type      = "Microsoft.AzureStackHCI/virtualMachineInstances@2024-01-01"
  name      = "default"
  parent_id = azapi_resource.machine[each.key].id

  body = {
    extendedLocation = {
      type = "CustomLocation"
      name = var.custom_location_id
    }
    properties = {
      hardwareProfile = {
        vmSize     = "Custom"
        processors = var.vcpu
        memoryMB   = var.memory_mb
      }
      osProfile = {
        computerName = each.value.computer
        windowsConfiguration = {
          provisionVMAgent       = true
          provisionVMConfigAgent = true
        }
      }
      storageProfile = {
        imageReference = { id = var.image_id }
      }
      networkProfile = {
        networkInterfaces = [{ id = azapi_resource.nic[each.key].id }]
      }
    }
  }

  sensitive_body = {
    properties = {
      osProfile = {
        adminUsername = var.local_admin_username
        adminPassword = var.local_admin_password
      }
    }
  }
}

resource "azapi_resource" "entra" {
  for_each  = var.entra_join_extension ? local.hosts : {}
  type      = "Microsoft.HybridCompute/machines/extensions@2025-06-01"
  name      = "AADLoginForWindows"
  parent_id = azapi_resource.machine[each.key].id
  location  = var.location

  body = {
    properties = {
      publisher               = "Microsoft.Azure.ActiveDirectory"
      type                    = "AADLoginForWindows"
      typeHandlerVersion      = "2.0"
      autoUpgradeMinorVersion = true
    }
  }

  depends_on = [azapi_resource.vmi]
}

resource "azapi_resource" "monitor" {
  for_each  = var.enable_monitoring ? local.hosts : {}
  type      = "Microsoft.HybridCompute/machines/extensions@2025-06-01"
  name      = "AzureMonitorWindowsAgent"
  parent_id = azapi_resource.machine[each.key].id
  location  = var.location

  body = {
    properties = {
      publisher               = "Microsoft.Azure.Monitor"
      type                    = "AzureMonitorWindowsAgent"
      typeHandlerVersion      = "1.0"
      autoUpgradeMinorVersion = true
    }
  }

  depends_on = [azapi_resource.vmi, azapi_resource.entra]
}

resource "azapi_resource" "association" {
  for_each  = var.enable_monitoring ? local.hosts : {}
  type      = "Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11"
  name      = var.names["dcr_assoc"]
  parent_id = azapi_resource.machine[each.key].id

  body = {
    properties = {
      dataCollectionRuleId = var.dcr_id
    }
  }

  depends_on = [azapi_resource.monitor]
}
