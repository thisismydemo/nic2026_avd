# avd-control-plane — variables mirror solution.yml inputs one-to-one (same canonical names). No defaults for tenant/subscription/names.

variable "org" {
  description = "Organization identifier."
  type        = string
}

variable "lab_token" {
  description = "Lab identifier."
  type        = string
}

variable "location" {
  description = "Azure location for control-plane resources."
  type        = string
}

variable "location_short" {
  description = "Short identifier for the Azure location."
  type        = string
}

variable "tenant_id" {
  description = "Microsoft Entra tenant ID."
  type        = string
}

variable "subscription_id_avd" {
  description = "Subscription ID containing the AVD control plane."
  type        = string
}

variable "subscription_id_azl" {
  description = "Subscription ID for Azure Local resources."
  type        = string
}

variable "tags" {
  description = "Tags applied to supported resources."
  type        = map(string)
}

variable "names" {
  description = "Names of the AVD control-plane resources and existing dependencies."
  type        = map(string)

  validation {
    condition = alltrue([
      for key in [
        "workspace",
        "hostpool_azure",
        "hostpool_azl",
        "hostpool_hybrid",
        "appgroup_azure",
        "appgroup_azl",
        "appgroup_hybrid",
        "scaling_plan_azure",
        "hostpool_identity",
        "rg_control"
      ] : try(length(var.names[key]) > 0, false)
    ])
    error_message = "names must contain every required, non-empty resource name."
  }
}

variable "host_pools" {
  description = "Configuration of the Azure, Azure Local, and hybrid host pools."
  type = object({
    azure = object({
      type                     = string
      load_balancer            = string
      max_session_limit        = number
      start_vm_on_connect      = bool
      validation_environment   = bool
      friendly_name            = string
      preferred_app_group_type = string
    })
    azl = object({
      type                     = string
      load_balancer            = string
      max_session_limit        = number
      start_vm_on_connect      = bool
      validation_environment   = bool
      friendly_name            = string
      preferred_app_group_type = string
    })
    hybrid = object({
      type                     = string
      load_balancer            = string
      max_session_limit        = number
      start_vm_on_connect      = bool
      validation_environment   = bool
      friendly_name            = string
      preferred_app_group_type = string
    })
  })

  validation {
    condition = alltrue([
      var.host_pools.azure.type == "Pooled",
      var.host_pools.azl.type == "Pooled",
      var.host_pools.hybrid.type == "Pooled"
    ])
    error_message = "Every host pool type must be Pooled."
  }
}

variable "rdp_properties" {
  description = "Custom RDP properties shared by the host pools."
  type        = string
}

variable "scaling_plan" {
  description = "Scaling plan configuration, assigned pools, and schedules."
  type = object({
    time_zone      = string
    assigned_pools = list(string)
    exclusion_tag  = string
    schedules = list(object({
      name                                 = string
      days_of_week                         = list(string)
      ramp_up_start_time                   = object({ hour = number, minute = number })
      ramp_up_load_balancing_algorithm     = string
      ramp_up_minimum_hosts_percent        = number
      ramp_up_capacity_threshold_percent   = number
      peak_start_time                      = object({ hour = number, minute = number })
      peak_load_balancing_algorithm        = string
      ramp_down_start_time                 = object({ hour = number, minute = number })
      ramp_down_load_balancing_algorithm   = string
      ramp_down_minimum_hosts_percent      = number
      ramp_down_capacity_threshold_percent = number
      ramp_down_force_logoff_users         = bool
      ramp_down_wait_time_minutes          = number
      ramp_down_notification_message       = string
      ramp_down_stop_hosts_when            = string
      off_peak_start_time                  = object({ hour = number, minute = number })
      off_peak_load_balancing_algorithm    = string
    }))
  })

  validation {
    condition     = alltrue([for pool in var.scaling_plan.assigned_pools : contains(["azure", "azl", "hybrid"], pool)])
    error_message = "scaling_plan.assigned_pools may contain only azure, azl, or hybrid."
  }
}

variable "enable_scaling_plan" {
  description = "Whether to deploy the scaling plan and its host-pool associations."
  type        = bool
  default     = true
}

variable "workspace_friendly_name" {
  description = "Display name of the AVD workspace."
  type        = string
}

variable "group_object_ids" {
  description = "Microsoft Entra group object IDs granted desktop access."
  type = object({
    avd_azure  = string
    avd_azl    = string
    avd_hybrid = string
  })
}

variable "avd_service_principal_object_id" {
  description = "Optional AVD service principal object ID granted VM power permissions."
  type        = string
  default     = ""
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID for diagnostics; empty disables diagnostic settings."
  type        = string
}
