# =============================================================================
# Governance components
# =============================================================================

data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {
  subscription_id = var.subscription_id
}

locals {
  builtin = {
    allowed_locations       = "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"
    require_tag             = "/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99"
    storage_deny_public     = "/providers/Microsoft.Authorization/policyDefinitions/b2982f36-99f2-4db5-8eff-283140c09693"
    kv_deny_public          = "/providers/Microsoft.Authorization/policyDefinitions/55615ac9-af46-4a59-874e-391cc3dfb490"
    acr_deny_public         = "/providers/Microsoft.Authorization/policyDefinitions/0fdf0491-d080-4575-b627-ad0e843cba0f"
  }
}
resource "azurerm_subscription_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  display_name         = "Approved regions to deploy"
  description          = "resources only be created in the approved region list."
  subscription_id      = data.azurerm_subscription.current.subscription_id
  policy_definition_id = local.builtin.allowed_locations
  enforce              = var.enforce
  not_scopes           = var.not_scopes

  parameters = jsonencode({
    listOfAllowedLocations = { value = var.allowed_locations }
  })
}

resource "azurerm_subscription_policy_assignment" "required_tags" {
  for_each = toset(var.required_tags)

  name                 = "require-tag-${each.value}"
  display_name         = "Require the '${each.value}' tag"
  description          = "Tagging standard: every resource must carry the '${each.value}' tag."
  subscription_id      = data.azurerm_subscription.current.subscription_id
  policy_definition_id = local.builtin.require_tag
  enforce              = var.enforce
  not_scopes           = var.not_scopes

  parameters = jsonencode({
    tagName = { value = each.value }
  })
}

resource "azurerm_subscription_policy_assignment" "storage_deny_public" {
  name                 = "storage-deny-public"
  display_name         = "Storage accounts must disable public network access"
  description          = "Prevents a storage account from being re-opened to the internet after deployment."
  subscription_id      = data.azurerm_subscription.current.subscription_id
  policy_definition_id = local.builtin.storage_deny_public
  enforce              = var.enforce
  not_scopes           = var.not_scopes

  parameters = jsonencode({
    effect = { value = "Deny" }
  })
}

resource "azurerm_subscription_policy_assignment" "acr_deny_public" {
  name                 = "acr-deny-public"
  display_name         = "Container registries must disable public network access"
  description          = "Prevents the registry from being exposed publicly."
  subscription_id      = data.azurerm_subscription.current.subscription_id
  policy_definition_id = local.builtin.acr_deny_public
  enforce              = var.enforce
  not_scopes           = var.not_scopes

  parameters = jsonencode({
    effect = { value = "Deny" }
  })
}

resource "azurerm_subscription_policy_assignment" "kv_deny_public" {
  name                 = "kv-deny-public"
  display_name         = "Key vaults must disable public network access"
  description          = "Key vaults must be reachable only over their private endpoint."
  subscription_id      = data.azurerm_subscription.current.subscription_id
  policy_definition_id = local.builtin.kv_deny_public
  enforce              = var.enforce
  not_scopes           = var.not_scopes

  parameters = jsonencode({
    effect = { value = "Deny" }
  })
}
