data "azurerm_resource_group" "arc" {
  name = var.names.rg_arc
}

locals {
  expected_host_names = [
    var.names.sessionhost_hv01,
    var.names.sessionhost_hv02,
  ]

  # Built-in Azure role definition IDs. Keep all literal role GUIDs here.
  roles = {
    reader                       = "acdd72a7-3385-48ef-bd42-f606fba81ae7" # Reader
    vm_user_login                = "fb879df8-f326-4884-b1cf-06f3ad86be52" # Virtual Machine User Login
    vm_administrator_login       = "1c0163c0-47e6-4577-8991-ea5c82e286e4" # Virtual Machine Administrator Login
    connected_machine_onboarding = "b64e21ea-ac4e-4cdf-9dc9-5b892992bee7" # Azure Connected Machine Onboarding
  }

  dcr_id = var.dcr_avd_insights_id != "" ? var.dcr_avd_insights_id : "/subscriptions/${var.subscription_id_avd}/resourceGroups/${var.names.rg_mon}/providers/Microsoft.Insights/dataCollectionRules/${var.names.dcr_avd_insights}"

  hostpool_principal_id = var.hostpool_identity_principal_id != "" ? var.hostpool_identity_principal_id : (
    var.manage_arc_rg_rbac ? data.azapi_resource.hostpool_identity[0].output.properties.principalId : ""
  )

  role_assignments = var.manage_arc_rg_rbac ? merge(
    {
      reader = {
        principal_id   = local.hostpool_principal_id
        principal_type = "ServicePrincipal"
        role_id        = local.roles.reader
      }
    },
    var.assign_vm_login_roles ? {
      vm_user = {
        principal_id   = var.group_object_ids.avd_users
        principal_type = "Group"
        role_id        = local.roles.vm_user_login
      }
      vm_administrator = {
        principal_id   = var.group_object_ids.avd_admins
        principal_type = "Group"
        role_id        = local.roles.vm_administrator_login
      }
    } : {},
    var.arc_onboard_sp_object_id != "" ? {
      onboarding = {
        principal_id   = var.arc_onboard_sp_object_id
        principal_type = "ServicePrincipal"
        role_id        = local.roles.connected_machine_onboarding
      }
    } : {}
  ) : {}
}

data "azapi_resource" "hostpool_identity" {
  count                  = var.manage_arc_rg_rbac && var.hostpool_identity_principal_id == "" ? 1 : 0
  type                   = "Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30"
  name                   = var.names.hostpool_identity
  parent_id              = "/subscriptions/${var.subscription_id_avd}/resourceGroups/${var.names.rg_control}"
  response_export_values = ["properties.principalId"]
}

# The onboarding script creates these machines before extension deployment is enabled.
data "azapi_resource" "arc_machines" {
  count     = var.enable_arc_extensions ? length(local.expected_host_names) : 0
  type      = "Microsoft.HybridCompute/machines@2025-06-01"
  name      = local.expected_host_names[count.index]
  parent_id = data.azurerm_resource_group.arc.id
}

resource "azapi_resource" "ama" {
  count     = var.enable_arc_extensions ? length(local.expected_host_names) : 0
  type      = "Microsoft.HybridCompute/machines/extensions@2025-06-01"
  name      = "AzureMonitorWindowsAgent"
  parent_id = data.azapi_resource.arc_machines[count.index].id
  location  = var.location

  body = {
    properties = {
      publisher               = "Microsoft.Azure.Monitor"
      type                    = "AzureMonitorWindowsAgent"
      typeHandlerVersion      = "1.0"
      autoUpgradeMinorVersion = true
      enableAutomaticUpgrade  = true
    }
  }
}

resource "azapi_resource" "dcr_association" {
  count     = var.enable_arc_extensions ? length(local.expected_host_names) : 0
  type      = "Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11"
  name      = var.names.dcr_assoc
  parent_id = data.azapi_resource.arc_machines[count.index].id

  body = {
    properties = {
      dataCollectionRuleId = local.dcr_id
    }
  }

  depends_on = [azapi_resource.ama]
}

resource "azurerm_role_assignment" "arc" {
  for_each           = local.role_assignments
  scope              = data.azurerm_resource_group.arc.id
  name               = uuidv5("url", "${data.azurerm_resource_group.arc.id}/${each.value.principal_id}/${each.value.role_id}")
  role_definition_id = "/subscriptions/${var.subscription_id_avd}/providers/Microsoft.Authorization/roleDefinitions/${each.value.role_id}"
  principal_id       = each.value.principal_id
  principal_type     = each.value.principal_type
}
