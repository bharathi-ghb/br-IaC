# =============================================================================
# Key Vault Components - Key Vault + Private Endpoint + RBAC + Diagnostics
# =============================================================================

resource "azurerm_key_vault" "kv" {
  name                          = var.name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  tenant_id                     = var.tenant_id
  sku_name                      = var.sku_name
  tags                          = var.tags
  rbac_authorization_enabled    = true
  enabled_for_disk_encryption   = true
  purge_protection_enabled      = true
  public_network_access_enabled = false
  soft_delete_retention_days    = var.soft_delete_retention_days

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

resource "azurerm_private_endpoint" "kv" {
  name                = "pe-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags
  
  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_key_vault.kv.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-${var.name}"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }
}

resource "azurerm_private_dns_a_record" "kv" {
  name                = azurerm_key_vault.kv.name
  zone_name           = var.private_dns_zone_name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records = [azurerm_private_endpoint.kv.private_service_connection[0].private_ip_address]
  tags = var.tags
}

resource "azurerm_role_assignment" "secrets_user" {
  for_each = toset(var.secrets_user_principal_ids)

  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "secrets_officer" {
  for_each = toset(var.secrets_officer_principal_ids)

  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

resource "azurerm_monitor_diagnostic_setting" "kv" {
  for_each = var.enable_diagnostics ? toset(["kv"]) : toset([])

  name                       = "kv-diagnostics-to-law"
  target_resource_id         = azurerm_key_vault.kv.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category_group = "allLogs" }

  enabled_metric {
    category = "AllMetrics"
  }
}
