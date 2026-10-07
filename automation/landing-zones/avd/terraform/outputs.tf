# lz-avd outputs — identical set to solution.yml outputs and bicep/main.bicep (tests/LzAvd.Parity.Tests.ps1).

output "rg_names" {
  description = "Resource group names keyed control, net, hosts, img, stor, mon, arc."
  value       = local.resource_group_names
}

output "arc_rg_name" {
  description = "Arc machines resource group for the Hybrid hosts (HYB-02)."
  value       = var.names["rg_arc"]
}

output "hostpool_rg" {
  description = "Control-plane resource group."
  value       = var.names["rg_control"]
}

output "spoke_vnet_id" {
  description = "AVD spoke VNet id."
  value       = module.spoke_vnet.resource_id
}

output "subnet_hosts_id" {
  description = "Session-host subnet id."
  value       = module.spoke_vnet.subnets["hosts"].resource_id
}

output "subnet_pe_id" {
  description = "Private endpoint subnet id."
  value       = module.spoke_vnet.subnets["pe"].resource_id
}

output "subnet_imgbuild_id" {
  description = "Image Builder subnet id."
  value       = module.spoke_vnet.subnets["imgbuild"].resource_id
}

output "subnet_dnsin_id" {
  description = "Resolver inbound subnet id."
  value       = module.spoke_vnet.subnets["dnsin"].resource_id
}

output "dns_resolver_id" {
  description = "DNS Private Resolver id; empty when disabled."
  value       = var.enable_private_endpoints && var.enable_dns_private_resolver ? module.dns_resolver[0].resource_id : ""
}

output "dns_resolver_inbound_ip" {
  description = "Inbound endpoint IP for on-prem DNS; empty when disabled."
  value       = var.enable_private_endpoints && var.enable_dns_private_resolver ? var.dns_resolver_inbound_ip : ""
}

output "privatelink_file_zone_id" {
  description = "privatelink.file.core.windows.net zone id (created or reused)."
  value       = local.file_zone_id
}

output "storage_account_id" {
  description = "FSLogix storage account id."
  value       = module.fslogix_storage.resource_id
}

output "storage_account_name" {
  description = "FSLogix storage account name."
  value       = module.fslogix_storage.name
}

output "fslogix_profile_unc" {
  description = "UNC path of the profiles share."
  value       = "\\\\${module.fslogix_storage.name}.${local.storage_suffix}\\${var.share_names.profiles}"
}

output "fslogix_odfc_unc" {
  description = "UNC path of the ODFC share."
  value       = "\\\\${module.fslogix_storage.name}.${local.storage_suffix}\\${var.share_names.odfc}"
}

output "private_endpoint_id" {
  description = "Azure Files private endpoint id."
  value       = try(module.fslogix_storage.private_endpoints["file"].resource_id, "")
}

output "recovery_vault_id" {
  description = "Recovery Services vault id; empty when enable_backup is false."
  value       = var.enable_backup ? module.recovery_vault[0].resource_id : ""
}

output "gallery_id" {
  description = "Compute Gallery id."
  value       = module.gallery.resource_id
}

output "image_definition_ids" {
  description = "Image definition ids in the order of image_definitions."
  value       = [for def in var.image_definitions : "${module.gallery.resource_id}/images/${def.name}"]
}

output "hostpool_identity_id" {
  description = "Host-pool user-assigned identity resource id."
  value       = module.hostpool_identity.resource_id
}

output "hostpool_identity_principal_id" {
  description = "Host-pool identity principal id."
  value       = module.hostpool_identity.principal_id
}

output "hostpool_identity_client_id" {
  description = "Host-pool identity client id."
  value       = module.hostpool_identity.client_id
}

output "aib_identity_id" {
  description = "Image Builder identity resource id."
  value       = module.aib_identity.resource_id
}

output "aib_identity_principal_id" {
  description = "Image Builder identity principal id."
  value       = module.aib_identity.principal_id
}

output "dcr_avd_insights_id" {
  description = "AVD Insights DCR id."
  value       = module.dcr_avd_insights.resource_id
}

output "azl_spoke_vnet_name" {
  value = var.names["azl_spoke_vnet"]
}

output "azl_spoke_vnet_name_matches" {
  value = lower(local.azl_vnet_segments[length(local.azl_vnet_segments) - 1]) == lower(var.names["azl_spoke_vnet"])
}
