# lz-avd — provider pins. Backend settings are supplied with `terraform init -backend-config=<file>` from environment/
# (contract §3); nothing about the backend is committed here.
terraform {
  required_version = ">= 1.10, < 2.0"

  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.60"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id_avd
  tenant_id       = var.tenant_id

  storage_use_azuread = true

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    recovery_service {
      vm_backup_stop_protection_and_retain_data_on_destroy = false
      purge_protected_items_from_vault_on_destroy          = true
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id_avd
  tenant_id       = var.tenant_id
}
