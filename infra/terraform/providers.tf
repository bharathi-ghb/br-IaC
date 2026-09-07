terraform {
  required_version = ">= 1.9.0, < 2" # 1.9 added cross-variable references in validation blocks

  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 1.15"
    }
  }
}

provider "azurerm" {
  use_oidc                   = true
  storage_use_azuread        = true
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "azuread" {
  use_oidc = true
}

provider "azapi" {
  use_oidc = true
}
