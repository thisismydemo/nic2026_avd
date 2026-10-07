# avd-control-plane — provider pins. Backend settings are supplied with `terraform init -backend-config=<file>` (contract §3).
# Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md R-08).
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
  }
}

provider "azurerm" {
  subscription_id     = var.subscription_id_avd
  tenant_id           = var.tenant_id
  storage_use_azuread = true

  features {}
}

provider "azapi" {
  subscription_id = var.subscription_id_avd
  tenant_id       = var.tenant_id
}
