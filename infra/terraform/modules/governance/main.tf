# =============================================================================
# Governance components
# =============================================================================

data "azurerm_resource_group" "rg_infra" {
  name = var.resource_group_name
}

# BUILT-IN POLICY DEFINITIONS, referenced by their well-known GUIDs.
#
# Built-in rather than custom on purpose: Microsoft maintains them, they map to
# compliance frameworks (CIS, NIST, PCI, ISO 27001), and they surface in Defender for
# Cloud's regulatory compliance dashboard for free. Custom policy is a maintenance
# liability - write it only when nothing built-in fits.
#
# WHY POLICY EXISTS AT ALL when every resource already sets
# public_network_access_enabled = false: Terraform is CORRECTIVE - it only fixes drift
# when it next runs. Azure Policy in Deny mode is PREVENTIVE - it rejects the ARM
# request before it takes effect, regardless of who made it or which tool they used.
# Policy is the only layer in the public-access model that actually prevents accidents.
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

# KNOWN DEFECT ACROSS EVERY ASSIGNMENT IN THIS FILE (docs/02 P1-8):
#
#  1. RESOURCE-GROUP SCOPE IS TOO NARROW. Anyone who can create a NEW resource group
#     escapes every one of these policies, and rg_hub - which holds the firewall and
#     the DNS zones - is entirely ungoverned. Real governance belongs at MANAGEMENT
#     GROUP scope so it applies to subscriptions that do not exist yet. Resource-group
#     scope is a demo convenience, not a control.
#
#  2. THE REQUIRED-TAGS POLICY WILL DENY OUR OWN APPLY. required_tags defaults to
#     [environment, owner, cost_centre], and neither environment's tfvars sets
#     cost_centre. With enforce = true and effect Deny, the next terraform apply into
#     rg_infra is rejected by our own policy.
#
#  3. MISSING: DeployIfNotExists policies. These assignments detect and deny; they do
#     not remediate. The two highest-value DINE policies for this platform would be
#     'Configure private endpoints to use private DNS zones' (which auto-fixes
#     Troubleshooting Scenario 2 across the whole estate) and 'Deploy diagnostic
#     settings to Log Analytics'.
#
#  4. MISSING: a policy INITIATIVE. Individual assignments do not roll up into a
#     compliance score. Attaching a built-in regulatory initiative gives you a
#     compliance dashboard for free.
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

# GATEKEEPER POLICIES, enforced at Kubernetes ADMISSION rather than at ARM.
# These only work because modules/aks sets azure_policy_enabled = true, which installs
# the Gatekeeper add-on.
#
# var.kubernetes_policy_effect defaults to "Audit" DELIBERATELY. Applying Deny to an
# existing cluster instantly blocks deployments that were previously fine - potentially
# including system components in namespaces you forgot to exclude. The correct rollout
# is Audit -> measure compliance -> remediate findings -> promote to Deny, non-prod
# leading production. That progression is the answer, not the end state.
#
# excludedNamespaces covers kube-system, gatekeeper-system and azure-arc because
# platform components legitimately need privileges the workload must never have.
#
# WHAT YOU ALSO NEED, and is missing: an EXEMPTION process, not an off switch.
# azurerm_resource_policy_exemption with a justification and an EXPIRY DATE, reviewed
# like code. The failure mode being avoided is a genuine incident fix blocked by policy
# at 3am, someone disabling the assignment, and nobody ever re-enabling it.
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
