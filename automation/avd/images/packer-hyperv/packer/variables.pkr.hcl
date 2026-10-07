variable "iso_path" {
  type = string
}

variable "iso_checksum" {
  type = string
}

variable "vm_name" {
  type = string
}

variable "output_directory" {
  type = string
}

variable "switch_name" {
  type = string
}

variable "vlan_id" {
  type = number
}

variable "cpus" {
  type = number
}

variable "memory_mb" {
  type = number
}

variable "disk_size_mb" {
  type = number
}

variable "build_username" {
  type = string
}

# Supplied only as PKR_VAR_build_password in the child process environment by scripts/Invoke-PackerBuild.ps1.
variable "build_password" {
  type      = string
  sensitive = true
}

variable "customizer_directory" {
  type = string
}

variable "customizer_tokens" {
  type    = map(string)
  default = {}
}

variable "winrm_timeout" {
  type = string
}

variable "shutdown_command" {
  type    = string
  default = "C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /quiet"
}

variable "image_version" {
  type = string
}

variable "arc_agent_uri" {
  type = string
}

variable "arc_agent_directory" {
  type = string
}

variable "shortpath_port" {
  type = number
}

variable "defender_paths" {
  type = string
}

variable "defender_processes" {
  type = string
}

variable "vdot_archive_uri" {
  type = string
}

variable "vdot_archive_sha256" {
  type = string
}

variable "product_key" {
  type    = string
  default = ""
}
