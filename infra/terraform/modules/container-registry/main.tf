# =============================================================================
# Azure Container Registry + Private Endpoint + Role Assignments + Diagnostics
# =============================================================================

# PREMIUM IS MANDATORY, not a preference: Basic and Standard cannot have private
# endpoints at all. The requirement dictates the SKU. Cost is ~$1.67/day vs ~$0.17/day
# for Basic - a 10x step you cannot avoid if you need private connectivity.
#
# admin_enabled = false is one of the most important settings here. The ACR admin
# account is a SHARED username and password with full push/pull rights; it is
# unattributable in the audit log (every push looks identical), and rotating it breaks
# every consumer simultaneously. Its existence would defeat the entire identity model.
# Consequence accepted: every consumer must authenticate with Entra - 'az acr login'
# exchanges an Entra token for a short-lived ACR refresh token, and AKS uses the
# kubelet identity's AcrPull. Any tool that only speaks 'docker login -u -p' needs a
# different integration path.
#
# network_rule_bypass_option = "AzureServices" lets trusted Azure services (ACR Tasks,
# Defender image scanning, geo-replication) through despite public access being off.
# Trade-off: it is a broad category, not a specific service - you are trusting
# Microsoft's definition of 'trusted'.
#
# NOT SET, and worth raising (docs/02 P3):
#   zone_redundancy_enabled  - prod HA
#   data_endpoint_enabled    - stable per-region data FQDNs, which matters if you ever
#                              need to allow-list registry endpoints on a firewall
#   geo-replication          - multi-region
#   image signing            - trust_policy_enabled is a variable defaulting to false;
#                              the modern answer is cosign + Ratify admission enforcement
#   a globally-unique name   - 'acrnonprod' will collide; needs a random suffix
resource "azurerm_container_registry" "acr" {
  name                          = var.name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = "Premium"
  tags                          = var.tags
  admin_enabled                 = false
  public_network_access_enabled = false
  network_rule_bypass_option    = "AzureServices"
  retention_policy_in_days      = var.untagged_retention_days
  trust_policy_enabled          = var.enable_content_trust

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# The private_dns_zone_group is the CORRECT, idempotent way to create the DNS record:
# it binds the A record to the private endpoint's lifecycle, so a PE recreate that
# assigns a new NIC IP updates the record automatically. A hand-written
# azurerm_private_dns_a_record goes silently stale and points at a dead IP - a DNS
# incident that presents as a network incident. (The storage and key-vault modules in
# this repo make exactly that mistake - see docs/02 P1-2.)
#
# NOTE: ACR splits pulls across TWO endpoints - <registry>.azurecr.io for the manifest
# and <registry>.<region>.data.azurecr.io for the blob layers. The 'registry'
# subresource covers both, and both records land in privatelink.azurecr.io. If DNS or
# the endpoint only handles the registry endpoint you get a very confusing failure
# where the manifest resolves fine and the layer download times out. That is the ACR
# private-link gotcha and it is worth checking explicitly in Scenario 3.
resource "azurerm_private_endpoint" "acr" {
  name                = "pe-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_container_registry.acr.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }
  private_dns_zone_group {
    name                 = "acr-${var.environment}-dns"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }
}

# AcrPull goes to the KUBELET identity (passed from main.tf as
# module.aks.kubelet_identity_object_id), NOT the cluster's control-plane identity.
# The kubelet is what pulls images. This is a frequent interview question and a
# frequent real-world mistake.
resource "azurerm_role_assignment" "acr_pull" {
  for_each = toset(var.pull_principal_ids)

  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "acr_push" {
  for_each = toset(var.push_principal_ids)

  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPush"
  principal_id         = each.value
}

resource "azurerm_monitor_diagnostic_setting" "acr" {
  for_each = var.enable_diagnostics ? toset(["acr"]) : toset([])

  name                       = "acr-diagnostics-to-law"
  target_resource_id         = azurerm_container_registry.acr.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { 
    category_group = "allLogs" 
  }
  enabled_metric {
    category = "AllMetrics"
  }
}
