# PROVIDER AND BACKEND CONFIGURATION
#
# backend "azurerm" {} is intentionally EMPTY - all settings come from
# -backend-config=environments/<env>/azurerm.tfbackend at init time. That is what lets
# one root module target two environments whose state lives in separate storage
# accounts in separate subscriptions.
#
# Chose separate state files over Terraform WORKSPACES deliberately: workspaces are
# for ephemeral variations of the same thing, not an isolation boundary - they share a
# backend and therefore share credentials. Here a compromised non-prod pipeline
# identity is physically unable to read prod state, and prod state contains secrets.
#
# KNOWN DEFECT (docs/02 P0-4): azurerm is pinned '~> 3' but the module code uses v4
# argument names throughout (enabled_metric, auto_scaling_enabled,
# rbac_authorization_enabled, enforce on policy assignments). Every terraform validate
# fails with 'Unsupported argument'. Should be '~> 4.14', and v4 additionally requires
# subscription_id on the provider block explicitly.
#
# ALSO MISSING: .terraform.lock.hcl is not committed. Without it, two runs weeks apart
# can resolve different provider builds and produce different plans - a reproducibility
# gap that matters in a regulated environment.

terraform {
  required_version = ">= 1.5.0, < 2"

  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 1.15"
    }
  }
}

# use_oidc = true is the single most important CI/CD security control in this repo:
# authentication is by workload identity federation, so there is NO client secret
# stored in Azure DevOps at all. The token is minted per pipeline run and lives for
# minutes. Compare with a service principal secret in a variable group - a durable
# credential that anyone able to edit a pipeline can exfiltrate with one echo.
#
# storage_use_azuread = true makes the provider use Entra rather than shared keys for
# storage data-plane calls, which is what allows shared_access_key_enabled = false on
# the storage accounts (see docs/02 P1-5).
#
# purge_soft_delete_on_destroy = false + recover_soft_deleted_key_vaults = true:
# a destroyed vault is recoverable rather than purged, and a re-apply recovers it
# instead of failing on the reserved name. Necessary because purge protection is on.
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
