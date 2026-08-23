# =============================================================================
# Key Vault Components - Key Vault + Private Endpoint + RBAC + Diagnostics
# =============================================================================

# KEY VAULT. Two choices worth defending:
#
# rbac_authorization_enabled = true - RBAC rather than legacy access policies.
#   RBAC gives per-secret scoping, standard Azure role assignments (so PIM, access
#   reviews and 'az role assignment list' all work), Activity Log auditing, and no
#   assignment cap. Access policies are vault-only granularity, use a bespoke ACL model
#   no other Azure service shares, and cap at 1,024 entries.
#   TRADE-OFF: RBAC propagation can take up to ~10 minutes, which bites in CI/CD -
#   Terraform creates a role assignment and immediately tries to write a secret, getting
#   a 403. The standard workaround is a retry or a time_sleep, which is ugly but real.
#
# purge_protection_enabled = true - a deleted vault or secret cannot be permanently
#   purged until the soft-delete window expires. It exists to stop an attacker with
#   Contributor rights destroying your keys and, with them, everything they encrypt.
#   TRADE-OFF, and this one is practical: it is IRREVERSIBLE once enabled, and it
#   RESERVES THE VAULT NAME for the full retention window (90 days here) after a
#   destroy - so re-running the same Terraform with the same name fails for three
#   months. Correct for production, wrong for an ephemeral environment. That is exactly
#   why var.enable_kv_purge_protection exists in the root module - and it is never
#   passed here (docs/02 P1-11), so this is hardcoded true regardless.
#
# THE DESIGN POINT: this vault is deliberately EMPTY in source control. Terraform never
# writes a secret value. The only real secret in the design (the agent PAT) is created
# out-of-band. IaC provisions the vault; operations populate it.
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

  lifecycle {
    prevent_destroy = true
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

# KNOWN DEFECT (docs/02 P1-2): DELETE THIS - same issue as the storage module. The
# private endpoint's private_dns_zone_group already creates and manages this record,
# and this one additionally targets the wrong resource group (rg_infra rather than the
# rg_hub where the zones live).
resource "azurerm_private_dns_a_record" "kv" {
  name                = azurerm_key_vault.kv.name
  zone_name           = var.private_dns_zone_name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records = [azurerm_private_endpoint.kv.private_service_connection[0].private_ip_address]
  tags = var.tags
}

# Secrets USER reads secret values. Secrets OFFICER (below) manages them.
#
# Note that neither is Key Vault ADMINISTRATOR, which would also let the holder change
# who else has access - that is the privilege-escalation distinction that matters, and
# it is why Officer rather than Administrator goes to the admin group.
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
