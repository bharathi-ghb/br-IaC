# =============================================================================
# Azure Container Registry + Private Endpoint + Role Assignments + Diagnostics
# =============================================================================

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
}

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
