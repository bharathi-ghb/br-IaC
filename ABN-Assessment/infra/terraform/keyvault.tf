data "azurerm_client_config" "current" {}

# -----------------------------------------------------------------------------
# Keyvault Components — + Private Endpoint + Private DNS Zone Link
# -----------------------------------------------------------------------------

module "key_vault" {
  source = "./modules/key-vault"

  name                          = "kv-${var.environment}-${var.name_prefix}"
  resource_group_name           = azurerm_resource_group.rg_infra.name
  location                      = azurerm_resource_group.rg_infra.location
  tags                          = azurerm_resource_group.rg_infra.tags
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  private_endpoint_subnet_id    = module.network_spoke.private_endpoint_subnet_id
  private_dns_zone_id           = module.private_dns.zone_ids["privatelink.vaultcore.azure.net"]
  private_dns_zone_name         = module.private_dns.zone_names["privatelink.vaultcore.azure.net"]
  secrets_user_principal_ids    = [module.identity.principal_id]
  secrets_officer_principal_ids = var.kv_admin_group_object_ids
  enable_kv_purge_protection    = var.enable_kv_purge_protection
  enable_diagnostics            = true
  log_analytics_workspace_id    = module.observability.log_analytics_workspace_id
}
