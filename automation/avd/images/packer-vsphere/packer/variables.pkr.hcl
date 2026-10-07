# Reference template, not run in the lab.

variable "customizer_directory" {
  type    = string
  default = "../../shared/customizers"
}

variable "customizer_tokens" {
  type    = map(string)
  default = {}
}

variable "winrm_timeout" {
  type    = string
  default = "2h"
}

variable "shutdown_command" {
  type    = string
  default = "C:\\Windows\\System32\\Sysprep\\Sysprep.exe /generalize /oobe /shutdown /quiet"
}

variable "image_version" {
  type    = string
  default = "1.0.0"
}

variable "arc_agent_uri" {
  type    = string
  default = ""
}

variable "arc_agent_directory" {
  type    = string
  default = "C:\\IIC\\ArcAgent"
}

variable "shortpath_port" {
  type    = number
  default = 3390
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

variable "product_key" {
  type      = string
  default   = ""
  sensitive = true
}

variable "build_username" {
  type    = string
  default = "build-admin"
}

# Supplied only as PKR_VAR_build_password in the child process environment.
variable "build_password" {
  type      = string
  sensitive = true
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory_mb" {
  type    = number
  default = 8192
}

variable "disk_size_mb" {
  type    = number
  default = 65536
}

variable "vm_name" {
  type    = string
  default = "avd-w11-ent"
}

variable "vcenter_server" {
  type = string
}

variable "vcenter_username" {
  type = string
}

# Supplied only as PKR_VAR_vcenter_password in the child process environment.
variable "vcenter_password" {
  type      = string
  sensitive = true
}

variable "vcenter_insecure_connection" {
  type    = bool
  default = false
}

variable "datacenter" {
  type = string
}

variable "cluster" {
  type = string
}

variable "datastore" {
  type = string
}

variable "folder" {
  type = string
}

variable "network" {
  type = string
}

variable "iso_datastore_path" {
  type = string
}

variable "vmtools_iso_path" {
  type    = string
  default = "[] /vmimages/tools-isoimages/windows.iso"
}

variable "vm_version" {
  type    = number
  default = null
}
