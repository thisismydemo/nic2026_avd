locals {
  hosts = {
    for i in range(var.host_count) : tostring(i) => {
      machine  = var.names["vm_azl_${i + 1}"]
      computer = var.names["cn_azl_${i + 1}"]
      nic      = var.names["nic_azl_${i + 1}"]
      path     = var.storage_path_ids[i]
      gpus     = length(var.gpu_dda_counts) > i ? var.gpu_dda_counts[i] : 0
      vcpu     = length(var.vcpu_per_host) > i && try(var.vcpu_per_host[i], 0) > 0 ? var.vcpu_per_host[i] : var.vcpu
      memory   = length(var.memory_mb_per_host) > i && try(var.memory_mb_per_host[i], 0) > 0 ? var.memory_mb_per_host[i] : var.memory_mb
    }
  }
  resource_group_id = "/subscriptions/${var.subscription_id_azl}/resourceGroups/${var.resource_group_name}"
}

resource "azapi_resource" "machine" {
  for_each  = local.hosts
  type      = "Microsoft.HybridCompute/machines@2025-01-13"
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
  type      = "Microsoft.AzureStackHCI/networkInterfaces@2026-04-01-preview"
  name      = each.value.nic
  parent_id = local.resource_group_id
  location  = var.location
  tags      = var.tags

  body = {
    extendedLocation = {
      type = "CustomLocation"
      name = var.custom_location_id
    }
    properties = merge(length(var.dns_servers) > 0 ? { dnsSettings = { dnsServers = var.dns_servers } } : {}, {
      ipConfigurations = [{
        name = "ipconfig1"
        properties = {
          subnet = { id = var.logical_network_id }
        }
      }]
    })
  }
}

resource "azapi_resource" "vmi" {
  for_each  = local.hosts
  type      = "Microsoft.AzureStackHCI/virtualMachineInstances@2026-04-01-preview"
  name      = "default"
  parent_id = azapi_resource.machine[each.key].id

  body = {
    extendedLocation = {
      type = "CustomLocation"
      name = var.custom_location_id
    }
    properties = {
      hardwareProfile = merge({
        vmSize     = "Custom"
        processors = each.value.vcpu
        memoryMB   = each.value.memory
        }, each.value.gpus > 0 ? {
        virtualMachineGPUs = [for g in range(each.value.gpus) : { assignmentType = "GpuDDA" }]
      } : {})
      osProfile = {
        computerName = each.value.computer
        windowsConfiguration = {
          provisionVMAgent       = true
          provisionVMConfigAgent = true
        }
      }
      storageProfile = {
        imageReference        = { id = var.image_id }
        vmConfigStoragePathId = each.value.path
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

resource "azapi_resource" "ad_join" {
  for_each  = var.join_type == "AD" ? local.hosts : {}
  type      = "Microsoft.HybridCompute/machines/extensions@2025-01-13"
  name      = "JsonADDomainExtension"
  parent_id = azapi_resource.machine[each.key].id
  location  = var.location
  tags      = var.tags

  body = {
    properties = {
      publisher               = "Microsoft.Compute"
      type                    = "JsonADDomainExtension"
      typeHandlerVersion      = "1.3"
      autoUpgradeMinorVersion = true
      settings = {
        name    = var.domain_fqdn
        OUPath  = var.domain_ou_path
        User    = var.domain_join_username
        Restart = "true"
        Options = "3"
      }
    }
  }

  sensitive_body = {
    properties = {
      protectedSettings = {
        Password = var.domain_join_password
      }
    }
  }

  depends_on = [azapi_resource.vmi]
}

resource "azapi_resource" "entra" {
  for_each  = var.join_type == "Entra" ? local.hosts : {}
  type      = "Microsoft.HybridCompute/machines/extensions@2025-01-13"
  name      = "AADLoginForWindows"
  parent_id = azapi_resource.machine[each.key].id
  location  = var.location

  body = {
    properties = {
      publisher               = "Microsoft.Azure.ActiveDirectory"
      type                    = "AADLoginForWindows"
      typeHandlerVersion      = "2.0"
      autoUpgradeMinorVersion = true
      settings = {
        mdmId = ""
      }
    }
  }

  depends_on = [azapi_resource.vmi]
}

resource "azapi_resource" "monitor" {
  for_each  = var.enable_monitoring ? local.hosts : {}
  type      = "Microsoft.HybridCompute/machines/extensions@2025-01-13"
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

  depends_on = [azapi_resource.vmi, azapi_resource.ad_join, azapi_resource.entra]
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
