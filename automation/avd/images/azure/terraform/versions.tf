terraform {
  required_version = ">= 1.10, < 2.0"

  backend "azurerm" {}

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.60"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id_avd
  tenant_id       = var.tenant_id
}

provider "azapi" {
  subscription_id = var.subscription_id_avd
  tenant_id       = var.tenant_id
}
