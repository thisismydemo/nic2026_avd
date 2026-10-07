terraform {
  required_version = ">= 1.10, < 2.0"

  backend "azurerm" {}

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id_azl
  tenant_id       = var.tenant_id
}
