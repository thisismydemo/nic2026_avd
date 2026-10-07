variable "org" {
  type = string
}

variable "lab_token" {
  type = string
}

variable "location" {
  type = string
}

variable "location_short" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "subscription_id_avd" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "names" {
  type = object({
    rg_arc            = string
    rg_control        = string
    rg_mon            = string
    hostpool_hybrid   = string
    hostpool_identity = string
    dcr_avd_insights  = string
    dcr_assoc         = string
    arc_onboard_spn   = string
    kv_ops            = string
    fslogix_sa        = string
    sessionhost_hv01  = string
    sessionhost_hv02  = string
  })
}

variable "cluster_name" {
  type = string
}

variable "hybrid_csv_path" {
  type = string
}

variable "compute_switch_name" {
  type = string
}

variable "hybrid_vlan_id" {
  type = number
}

variable "hybrid_vcpu" {
  type = number
}

variable "hybrid_memory_gb" {
  type = number
}

variable "hybrid_disk_gb" {
  type = number
}

variable "hybrid_vms" {
  type = list(object({
    name        = string
    owner_node  = string
    mac_address = string
    ip_address  = string
  }))
}

variable "arc_tags" {
  type = map(string)
}

variable "dhcp_reservations" {
  type = list(any)
}

variable "hybrid_image_vhdx" {
  type = string
}

variable "dns_resolver_inbound_ip" {
  type = string
}

variable "secondary_dns_ip" {
  type = string
}

variable "registration_token_ttl_hours" {
  type = number
}

variable "share_names" {
  type = map(string)
}

variable "shortpath_managed_port" {
  type = number
}

variable "patch_channel" {
  type = string
}

variable "dcr_avd_insights_id" {
  type    = string
  default = ""
}

variable "hostpool_identity_principal_id" {
  type    = string
  default = ""
}

variable "enable_arc_extensions" {
  type    = bool
  default = false
}

variable "manage_arc_rg_rbac" {
  type    = bool
  default = false
}

variable "assign_vm_login_roles" {
  type    = bool
  default = true
}

variable "group_object_ids" {
  type = object({
    avd_users  = string
    avd_admins = string
  })
}

variable "arc_onboard_sp_object_id" {
  type    = string
  default = ""
}

variable "secret_name_prefix" {
  type = string
  validation {
    condition     = length(var.secret_name_prefix) >= 3
    error_message = "secret_name_prefix must be set (for example <org>-<lab>-); an empty prefix would share secret names between environments."
  }
}
