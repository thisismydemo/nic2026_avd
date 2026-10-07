variable "org" {
  description = "Manifest parity only."
  type        = string
}

variable "lab_token" {
  description = "Lab token; manifest parity only (not a registration token)."
  type        = string
}

variable "location" {
  type = string
}

variable "location_short" {
  description = "Manifest parity only."
  type        = string
}

variable "tenant_id" {
  type = string
}

variable "subscription_id_azl" {
  type = string
}

variable "resource_group_name" {
  description = "Resource group that receives the session-host Arc machines."
  type        = string
}

variable "tags" {
  type = map(string)
}

variable "names" {
  type = map(string)
  validation {
    condition = alltrue([
      for key in ["vm_azl_1", "cn_azl_1", "nic_azl_1", "vm_azl_2", "cn_azl_2", "nic_azl_2", "dcr_assoc"] :
      contains(keys(var.names), key)
    ])
    error_message = "Supply every catalog name."
  }
  validation {
    condition = alltrue([
      for key in ["cn_azl_1", "cn_azl_2"] :
      try(length(var.names[key]) <= 15, false)
    ])
    error_message = "Computer names are at most 15 characters."
  }
}

variable "host_count" {
  type = number
  validation {
    condition     = var.host_count >= 1 && var.host_count <= 2 && floor(var.host_count) == var.host_count
    error_message = "host_count must be an integer from 1 to 2."
  }
}

variable "vcpu" {
  type = number
  validation {
    condition     = var.vcpu >= 1
    error_message = "vcpu must be positive."
  }
}

variable "memory_mb" {
  type = number
  validation {
    condition     = var.memory_mb >= 1
    error_message = "memory_mb must be positive."
  }
}

variable "custom_location_id" {
  type = string
}

variable "logical_network_id" {
  type = string
}

variable "image_id" {
  type = string
}

variable "dcr_id" {
  type = string
}

variable "entra_join_extension" {
  type    = bool
  default = true
}

variable "enable_monitoring" {
  type    = bool
  default = true
}

variable "hostpool_name" {
  description = "Manifest parity only; the host pool is used by the registration script, not Terraform."
  type        = string
}

variable "hostpool_rg" {
  description = "Manifest parity only; the host pool is used by the registration script, not Terraform."
  type        = string
}

variable "local_admin_username_secret" {
  description = "keyvault:// reference resolved by the deploy script; not used by Terraform."
  type        = string
  sensitive   = true
}

variable "local_admin_password_secret" {
  description = "keyvault:// reference resolved by the deploy script; not used by Terraform."
  type        = string
  sensitive   = true
}

variable "local_admin_username" {
  description = "Resolved by the deploy script in memory. Terraform state holds this VM credential; keep state in the private encrypted backend."
  type        = string
  sensitive   = true
}

variable "local_admin_password" {
  description = "Resolved by the deploy script in memory. Terraform state holds this VM credential; keep state in the private encrypted backend."
  type        = string
  sensitive   = true
}
