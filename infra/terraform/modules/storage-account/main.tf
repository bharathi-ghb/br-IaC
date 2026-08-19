# =============================================================================
# Storage Account + Blob + Private Endpoint + Private DNS Zone Link
# =============================================================================

resource "azurerm_storage_account" "sa" {
  name                            = var.name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  tags                            = var.tags
  account_tier                    = "Standard"
  account_replication_type        = var.replication_type
  account_kind                    = "StorageV2"
  access_tier                     = "Hot"
  shared_access_key_enabled       = true
  public_network_access_enabled   = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  infrastructure_encryption_enabled = true

  identity {
    type = "SystemAssigned"
  }

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = var.blob_retention_days
    }
    container_delete_retention_policy {
      days = var.blob_retention_days
    }
  }

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "cache" {
  name                  = var.cache_container_name
  storage_account_id    = azurerm_storage_account.sa.id
  container_access_type = "private"
}

resource "azurerm_private_endpoint" "storage_blob" {
  name                = "pe-blob-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-blob-${var.name}"
    private_connection_resource_id = azurerm_storage_account.sa.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-blob-${var.name}"
    private_dns_zone_ids = [var.blob_private_dns_zone_id]
  }
}

resource "azurerm_private_dns_a_record" "storage_blob" {
  name                = azurerm_storage_account.sa.name
  zone_name           = var.blob_private_dns_zone_name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records = [azurerm_private_endpoint.storage_blob.private_service_connection[0].private_ip_address]
  tags = var.tags
}

resource "azurerm_role_assignment" "rbac" {
  for_each = toset(var.data_contributor_principal_ids)

  scope                = azurerm_storage_account.sa.id
  role_definition_name = ["Storage Blob Data Contributor"]
  principal_id         = each.value
}

resource "azurerm_monitor_diagnostic_setting" "blob" {
  for_each = var.enable_diagnostics ? toset(["blob"]) : toset([])

  name                       = "blob-diagnostics-to-law"
  target_resource_id         = "${azurerm_storage_account.sa.id}/blobServices/default"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category_group = "allLogs" }

  enabled_metric {
    category = "AllMetrics"
  }
}
