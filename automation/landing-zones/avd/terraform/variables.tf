# lz-avd — variables mirror automation/landing-zones/avd/solution.yml inputs one-to-one (same canonical names).
# Values arrive from terraform.generated.tfvars.json (ConvertTo-NIC26TfVars). No tenant/subscription/address defaults.

variable "org" {
  type        = string
  description = "Organization token in every name (D-006)."
}

variable "lab_token" {
  type        = string
  description = "Lab token in every name (D-005)."
}

variable "location" {
  type        = string
  description = "Azure region for every regional resource (D-010)."
}

variable "location_short" {
  type        = string
  description = "Short region token used in names."
}

variable "tenant_id" {
  type        = string
  description = "Entra tenant id (D-002)."
}

variable "subscription_id_avd" {
  type        = string
  description = "AVD landing-zone subscription id (D-004)."
}

variable "subscription_id_azl" {
  type        = string
  description = "Azure Local landing-zone subscription id (D-004)."
}

variable "management_group_id" {
  type        = string
  description = "Parent management group (informational; policy is assigned at subscription scope, P-06)."
}

variable "owner_email" {
  type        = string
  description = "Owner e-mail for budget notifications."
}

variable "tags" {
  type        = map(string)
  description = "Required tags (naming standard §3a)."
}

variable "names" {
  type        = map(string)
  description = "Name catalog resolved from solution.yml names: (contract §10). IaC never builds a name."
}

variable "hub_vnet_id" {
  type        = string
  description = "Existing hub VNet resource id (connectivity subscription)."
}

variable "hub_address_space" {
  type        = string
  description = "Hub address space."
}

variable "identity_spoke_vnet_id" {
  type        = string
  description = "Existing identity spoke VNet id (privatelink zone link, P-11)."
}

variable "p2s_pool" {
  type        = string
  description = "Point-to-site client pool."
}

variable "onprem_compute_prefixes" {
  type        = list(string)
  description = "On-prem session-host prefixes allowed to the private endpoint."
}

variable "bastion_subnet_prefix" {
  type        = string
  description = "Existing AzureBastionSubnet prefix (admin RDP source; the jump server is covered by azl_spoke_prefix)."
}

variable "azl_spoke_vnet_id" {
  type        = string
  description = "Azure Local spoke VNet id (lz-azure-local output)."
}

variable "azl_spoke_prefix" {
  type        = string
  description = "Azure Local spoke prefix."
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "Lab Log Analytics workspace id (lz-azure-local output)."
}

variable "key_vault_id" {
  type        = string
  description = "Operations Key Vault id (lz-azure-local output). Not read by IaC."
}

variable "action_group_id" {
  type        = string
  description = "Ops action group id (lz-azure-local output)."
}

variable "avd_vnet_prefix" {
  type        = string
  description = "AVD spoke address space (AVD-LZ-04)."
}

variable "avd_subnets" {
  type = object({
    hosts    = string
    pe       = string
    imgbuild = string
    dnsin    = string
  })
  description = "Subnet prefixes keyed hosts, pe, imgbuild, dnsin."
}

variable "enable_private_endpoints" {
  type        = bool
  description = "Owner decision D-029: false (default) = Azure Files on its public endpoint; no privatelink zone, links or resolver. true restores the private-endpoint design."
  default     = false
}

variable "enable_dns_private_resolver" {
  type        = bool
  description = "Deploy the DNS Private Resolver inbound endpoint (P-07 option B)."
}

variable "dns_resolver_inbound_ip" {
  type        = string
  description = "Static inbound endpoint IP inside the dnsin subnet (required when the resolver is enabled)."
  default     = ""
}

variable "privatelink_file_zone_id" {
  type        = string
  description = "Existing privatelink.file zone id to reuse; empty creates the lab zone (P-11)."
  default     = ""
}

variable "link_privatelink_zone_to_hub" {
  type        = bool
  description = "Also link the zone to the hub VNet."
  default     = false
}

variable "share_names" {
  type = object({
    profiles = string
    odfc     = string
  })
  description = "FSLogix share names keyed profiles and odfc."
}

variable "share_quota_gib" {
  type        = number
  description = "Provisioned size per share in GiB."
  default     = 256
}

variable "enable_backup" {
  type        = bool
  description = "Deploy the Recovery Services vault and protect both shares."
  default     = true
}

variable "backup_policy" {
  type = object({
    schedule_time_utc = string
    retention_days    = number
  })
  description = "Backup policy: schedule_time_utc (HH:mm), retention_days (environment schema shape)."
}

variable "image_definitions" {
  type = list(object({
    name               = string
    publisher          = string
    offer              = string
    sku                = string
    os_type            = string
    hyper_v_generation = string
    security_type      = string
    os_state           = string
  }))
  description = "Gallery image definitions (name, publisher, offer, sku, os_type, hyper_v_generation, security_type, os_state)."
}

variable "avd_budget_monthly" {
  type        = number
  description = "Monthly budget amount."
}

variable "deploy_platform_scope_items" {
  type        = bool
  default     = false
  description = "Platform-owned hub peering and policy assignments require explicit ownership approval."
}

variable "enable_policy_assignments" {
  type        = bool
  description = "Assign the built-in Deny/Audit/Modify policies of design §2.4."
  default     = true
}

variable "group_object_ids" {
  type = object({
    avd_users     = string
    avd_admins    = string
    lab_operators = string
  })
  description = "Object ids keyed avd_users, avd_admins, lab_operators."
}

variable "arc_onboard_sp_object_id" {
  type        = string
  description = "Object id of the Arc onboarding service principal; empty skips its role assignment."
  default     = ""
}
