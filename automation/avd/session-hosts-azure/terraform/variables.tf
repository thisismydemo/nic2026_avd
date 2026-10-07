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

variable "resource_group_name" {
  description = "Resource group that receives the session-host VMs."
  type        = string
}

variable "tags" {
  type = map(string)
}

variable "names" {
  type = map(string)
}

variable "host_count" {
  type = number
  validation {
    condition     = var.host_count >= 1 && var.host_count <= 2 && floor(var.host_count) == var.host_count
    error_message = "host_count must be an integer from 1 to 2."
  }
}

variable "os_disk_sku" {
  type    = string
  default = "Premium_LRS"
}

variable "os_disk_size_gb" {
  type    = number
  default = 128
}

variable "session_host_sku_azure" {
  type = string
}

variable "session_host_zones" {
  type = list(number)
  validation {
    condition     = length(var.session_host_zones) > 0 && alltrue([for zone in var.session_host_zones : contains([1, 2, 3], zone)])
    error_message = "Supply at least one availability zone, numbered 1 through 3."
  }
}

variable "hosts_subnet_id" {
  type = string
}

variable "image_version_id" {
  type = string
}

variable "dcr_id" {
  type = string
}

variable "encryption_at_host" {
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
