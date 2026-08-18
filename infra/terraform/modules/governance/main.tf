# =============================================================================
# Governance components
# =============================================================================

data "azurerm_resource_group" "rg_infra" {
  name = var.resource_group_name
}

locals {
  builtin = {
    allowed_locations       = "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"
    require_tag             = "/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99"
    storage_deny_public     = "/providers/Microsoft.Authorization/policyDefinitions/b2982f36-99f2-4db5-8eff-283140c09693"
    aks_private_cluster     = "/providers/Microsoft.Authorization/policyDefinitions/040732e8-d947-40b8-95d6-854c95024bf8"
    aks_no_privileged       = "/providers/Microsoft.Authorization/policyDefinitions/95edb821-ddaf-4404-9732-666045e056b4"
    aks_no_privilege_escal  = "/providers/Microsoft.Authorization/policyDefinitions/1c6e92c9-99f0-4e55-9cf2-0c234dc48f99"
    acr_deny_public         = "/providers/Microsoft.Authorization/policyDefinitions/0fdf0491-d080-4575-b627-ad0e843cba0f"
  }
}

resource "azurerm_resource_group_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  display_name         = "Approved regions to deploy"
  description          = "resources only be created in the approved region list."
  resource_group_id    = data.azurerm_resource_group.rg_infra.id
  policy_definition_id = local.builtin.allowed_locations
  enforce              = var.enforce

  parameters = jsonencode({
    listOfAllowedLocations = { value = var.allowed_locations }
  })
}

resource "azurerm_resource_group_policy_assignment" "required_tags" {
  for_each = toset(var.required_tags)

  name                 = "require-tag-${each.value}"
  display_name         = "Require the '${each.value}' tag"
  description          = "Tagging standard: every resource must carry the '${each.value}' tag."
  resource_group_id    = data.azurerm_resource_group.rg_infra.id
  policy_definition_id = local.builtin.require_tag
  enforce              = var.enforce

  parameters = jsonencode({
    tagName = { value = each.value }
  })
}

resource "azurerm_resource_group_policy_assignment" "storage_deny_public" {
  name                 = "storage-deny-public"
  display_name         = "Storage accounts must disable public network access"
  description          = "Prevents a storage account from being re-opened to the internet after deployment."
  resource_group_id    = data.azurerm_resource_group.rg_infra.id
  policy_definition_id = local.builtin.storage_deny_public
  enforce              = var.enforce

  parameters = jsonencode({
    effect = { value = "Deny" }
  })
}

resource "azurerm_resource_group_policy_assignment" "acr_deny_public" {
  name                 = "acr-deny-public"
  display_name         = "Container registries must disable public network access"
  description          = "Prevents the registry from being exposed publicly."
  resource_group_id    = data.azurerm_resource_group.rg_infra.id
  policy_definition_id = local.builtin.acr_deny_public
  enforce              = var.enforce

  parameters = jsonencode({
    effect = { value = "Deny" }
  })
}

resource "azurerm_resource_group_policy_assignment" "aks_private_cluster" {
  name                 = "aks-private-cluster"
  display_name         = "AKS clusters must be private"
  description          = "Blocks creation of an AKS cluster with a public API server endpoint."
  resource_group_id    = data.azurerm_resource_group.rg_infra.id
  policy_definition_id = local.builtin.aks_private_cluster
  enforce              = var.enforce

  parameters = jsonencode({
    effect = { value = "Deny" }
  })
}

resource "azurerm_resource_group_policy_assignment" "aks_no_privileged" {
  name                 = "aks-no-privileged-containers"
  display_name         = "Kubernetes clusters should not allow privileged containers"
  description          = "Gatekeeper control preventing privileged pods from being admitted."
  resource_group_id    = data.azurerm_resource_group.rg_infra.id
  policy_definition_id = local.builtin.aks_no_privileged
  enforce              = var.enforce

  parameters = jsonencode({
    effect                = { value = var.kubernetes_policy_effect }
    excludedNamespaces    = { value = ["kube-system", "gatekeeper-system", "azure-arc"] }
  })
}

resource "azurerm_resource_group_policy_assignment" "aks_no_privilege_escalation" {
  name                 = "aks-no-privilege-escalation"
  display_name         = "Kubernetes containers should not allow privilege escalation"
  description          = "Gatekeeper control preventing allowPrivilegeEscalation=true."
  resource_group_id    = data.azurerm_resource_group.rg_infra.id
  policy_definition_id = local.builtin.aks_no_privilege_escal
  enforce              = var.enforce

  parameters = jsonencode({
    effect             = { value = var.kubernetes_policy_effect }
    excludedNamespaces = { value = ["kube-system", "gatekeeper-system", "azure-arc"] }
  })
}
