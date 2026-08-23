# =============================================================================
# Storage Account + Blob + Private Endpoint + Private DNS Zone Link
# =============================================================================

# THE CACHE. Security settings, and why each is here:
#
#   public_network_access_enabled = false + network_rules.default_action = "Deny"
#     Two independent controls. The first disables the public endpoint entirely; the
#     second is the firewall for any path that remains. Belt and braces.
#
#   min_tls_version = "TLS1_2", https_traffic_only_enabled = true
#     Baseline transport security.
#
#   infrastructure_encryption_enabled = true
#     Double encryption at rest (service level plus infrastructure level).
#     TRADE-OFF: IMMUTABLE. It cannot be changed after creation, only replaced - and
#     combined with prevent_destroy below, changing your mind means a manual migration.
#
#   blob_properties versioning + delete_retention + container_delete_retention
#     Ransomware and fat-finger protection with a real recovery path.
#     TRADE-OFF: every overwrite creates a version, so a frequently-refreshed cache
#     grows storage cost silently. That is exactly what the missing lifecycle policy
#     below is for.
#
# KNOWN DEFECT (docs/02 P1-5): shared_access_key_enabled = true CONTRADICTS the whole
# 'no keys' design. Anyone who can call listKeys - which any Contributor on the RG can -
# bypasses the entire Entra RBAC model and every data-plane audit trail. This is the
# escalation path from control-plane Contributor to full data access. Should be false,
# plus default_to_oauth_authentication = true. The Terraform backend is a separate
# account and already uses use_azuread_auth, so nothing breaks.
#
# KNOWN DEFECT (docs/02 P1-11): var.cache_expiry_days is accepted but there is NO
# azurerm_storage_management_policy resource - so cached blobs are NEVER expired. An
# operator reading the variable name will believe cleanup is happening while the
# container grows forever.
#
# KNOWN GAP (docs/02 P2-9): replication_type is LRS in BOTH environments. The compute
# tier is spread across three availability zones and its cache lives in one - a
# single-zone storage failure takes the cache out for every zone. Prod should be ZRS.
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

# KNOWN DEFECT (docs/02 P1-2): DELETE THIS RESOURCE.
#
# The private endpoint above already has a private_dns_zone_group, which creates and
# lifecycle-manages this exact A record. Two problems:
#   1. CONFLICT - both want to own the same record name in the zone. The apply either
#      fails with 'record already exists' or the two fight on every plan.
#   2. WRONG RESOURCE GROUP - this uses var.resource_group_name (rg_infra), but the
#      zones are created in rg_hub. It targets a zone that does not exist there.
#
# The general principle: hand-writing A records for private endpoints is an
# anti-pattern. The zone group binds the record to the ENDPOINT's lifecycle, so a PE
# recreate updates it. A manual record goes stale and points at a dead IP.
resource "azurerm_private_dns_a_record" "storage_blob" {
  name                = azurerm_storage_account.sa.name
  zone_name           = var.blob_private_dns_zone_name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records = [azurerm_private_endpoint.storage_blob.private_service_connection[0].private_ip_address]
  tags = var.tags
}

# THE ROLE ASSIGNMENT THAT MAKES WORKLOAD IDENTITY ACTUALLY WORK.
#
# Federation gets the pod AUTHENTICATED. This gets it AUTHORISED. Without it, the pod
# obtains a perfectly valid Entra token and receives
# '403 AuthorizationPermissionMismatch' on every blob call - which is exactly
# Troubleshooting Scenario 1.
#
# KNOWN DEFECT (docs/02 P0-5): main.tf never passes data_contributor_principal_ids, so
# this for_each is EMPTY and zero role assignments are created. The platform ships with
# the bug the assessment asks us to debug. Note also that scripts/smoke-test.sh already
# tells the operator 'the agent lacks Storage Blob Data Reader' - the script documents
# a role assignment the Terraform never makes.
#
# LEAST-PRIVILEGE REFINEMENT: scope to the CONTAINER rather than the account for true
# least privilege:
#   scope = "${azurerm_storage_account.sa.id}/blobServices/default/containers/${var.cache_container_name}"
# Account-level is acceptable for a single-purpose account; container-level is what you
# would do in a shared one.
resource "azurerm_role_assignment" "rbac" {
  for_each = toset(var.data_contributor_principal_ids)

  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Blob Data Contributor"
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
