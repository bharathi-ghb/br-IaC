# =============================================================================
# Identity Components
# =============================================================================

resource "azurerm_user_assigned_identity" "identity" {
  name                = var.identity_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# THE FEDERATED IDENTITY CREDENTIAL - the trust relationship that replaces a secret.
#
# Three fields must be exactly right, and Entra compares them as strings:
#
#   issuer   = the AKS cluster's OIDC issuer URL. Entra fetches its JWKS from here to
#              verify the signature on the pod's projected token.
#   audience = api://AzureADTokenExchange. Fixed value; a wrong one gives AADSTS700213.
#   subject  = system:serviceaccount:<namespace>:<serviceaccount>. CHARACTER-FOR-
#              CHARACTER. A namespace rename or a Helm serviceAccount.name that
#              disagrees produces AADSTS70021 - 'no matching federated identity record
#              found for presented assertion subject'.
#
# AADSTS70021 is the single most common Workload Identity failure in the real world,
# and its failure mode is nasty: the pod STARTS fine and only fails on its FIRST Azure
# call, deep inside an SDK stack trace, often minutes later.
#
# KNOWN DEFECT (docs/02 P0-6): the defaults in this repo disagree across three files -
# Terraform says banking-api/banking-api, the chart says banking-application, and the
# pipeline variable says banking-application. The pipeline overrides correctly from
# Terraform outputs, so the defaults are what is wrong. The RIGHT fix is a fail guard
# in the chart's _helpers.tpl comparing the rendered subject against an expected value
# passed from a Terraform output - turning a silent runtime auth failure into a loud
# deploy-time template error.
#
# DESIGN NOTE: this module maps MANY ServiceAccounts to ONE identity, which is
# convenient but wrong at scale - every federated workload then shares the same Azure
# permissions. The right model is one managed identity PER WORKLOAD, so RBAC grants are
# per-workload and a compromise has a one-service blast radius.
resource "azurerm_federated_identity_credential" "identity" {
  for_each = var.service_accounts

  name                      = "fic-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.identity.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = var.oidc_issuer_url
  subject                   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account_name}"
}
