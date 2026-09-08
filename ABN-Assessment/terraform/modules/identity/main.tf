# =============================================================================
# Identity Components
# =============================================================================

resource "azurerm_user_assigned_identity" "identity" {
  name                = var.identity_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "identity" {
  for_each = var.service_accounts

  name                      = "fic-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.identity.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = var.oidc_issuer_url
  subject                   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account_name}"
}
