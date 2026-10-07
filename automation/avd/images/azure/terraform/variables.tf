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
  description = "Existing image resource group."
  type        = string
}

variable "tags" {
  type = map(string)
}

variable "names" {
  type = map(string)
}

variable "templates" {
  type = list(object({
    key                 = string
    name                = string
    image_definition_id = string
    distribute_vhd      = bool
    run_output_name     = string
    gallery_run_output  = string
  }))
}

variable "aib_identity_id" {
  type = string
}

variable "subnet_imgbuild_id" {
  type = string
}

variable "source_publisher" {
  type = string
}

variable "source_offer" {
  type = string
}

variable "source_sku" {
  type = string
}

variable "source_version" {
  description = "Exact platform image version from Get-PlatformImageVersion.ps1; never the moving alias."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.source_version))
    error_message = "Resolve source_version to an exact numeric platform image version."
  }
}

variable "build_vm_size" {
  type = string
}

variable "os_disk_size_gb" {
  type = number
}

variable "build_timeout_minutes" {
  type    = number
  default = 120
}

variable "replication_regions" {
  type = list(string)
}

variable "shortpath_port" {
  type = number

  validation {
    condition     = var.shortpath_port >= 1024 && var.shortpath_port <= 65535 && floor(var.shortpath_port) == var.shortpath_port
    error_message = "shortpath_port must be an integer from 1024 through 65535."
  }
}

variable "defender_paths" {
  type    = string
  default = ""
}

variable "defender_processes" {
  type    = string
  default = ""
}

variable "vdot_archive_uri" {
  type    = string
  default = ""
}

variable "vdot_archive_sha256" {
  type    = string
  default = ""
}

variable "install_teams_app" {
  type    = string
  default = "false"
}

variable "disable_teams_autoupdate" {
  type    = string
  default = "false"
}
