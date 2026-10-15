variable "org" {
  description = "Manifest parity only."
  type        = string
}

variable "naming_token" {
  description = "Naming token; manifest parity only (not a registration token)."
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
    condition     = var.host_count >= 1 && var.host_count <= 3 && floor(var.host_count) == var.host_count
    error_message = "host_count must be an integer from 1 to 3."
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

variable "dns_servers" {
  description = "DNS servers of the logical network, repeated on each NIC (NIC DNS is immutable after creation)."
  type        = list(string)
  default     = []
}

variable "image_id" {
  type = string
}

variable "dcr_id" {
  type = string
}

variable "storage_path_ids" {
  description = "Storage path resource IDs, one per host in host order."
  type        = list(string)
}

variable "join_type" {
  description = "AD (JsonADDomainExtension, D-050), Entra (AADLoginForWindows) or None."
  type        = string
  default     = "AD"
  validation {
    condition     = contains(["AD", "Entra", "None"], var.join_type)
    error_message = "join_type must be AD, Entra or None."
  }
}

variable "domain_fqdn" {
  type    = string
  default = ""
}

variable "domain_ou_path" {
  type    = string
  default = ""
}

variable "vcpu_per_host" {
  description = "Per-host vCPU overrides in host order (0 or missing = vcpu)."
  type        = list(number)
  default     = []
}

variable "memory_mb_per_host" {
  description = "Per-host memory overrides in MB in host order (0 or missing = memory_mb)."
  type        = list(number)
  default     = []
}

variable "gpu_dda_counts" {
  description = "GPU DDA devices per host in host order; missing entries mean 0."
  type        = list(number)
  default     = []
}

variable "domain_join_username" {
  description = "Resolved by the deploy script in memory (join_type AD)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "domain_join_password" {
  description = "Resolved by the deploy script in memory (join_type AD). Terraform state holds it; keep state in the private encrypted backend."
  type        = string
  sensitive   = true
  default     = ""
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
