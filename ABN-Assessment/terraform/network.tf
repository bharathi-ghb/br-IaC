# =============================================================================
#                   Central Terraform Module.
# =============================================================================

# -----------------------------------------------------------------------------
# Pre-requisites: RG + Defaults
# -----------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "rg_infra" {
  name     = "rg-${var.environment}-${var.name_prefix}"
  location = var.location
  tags     = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_resource_group" "rg_hub" {
  name     = "rg-${var.environment}-${var.name_prefix}-hub"
  location = var.location
  tags     = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Network Components  — VNets(Hub + Spoke) + subnets + NSGs + Firewall + Spoke Peering + Association
# -----------------------------------------------------------------------------

module "network_hub" {
  source = "./modules/network-hub"
  location                = azurerm_resource_group.rg_hub.location
  resource_group_name     = azurerm_resource_group.rg_hub.name
  tags                    = azurerm_resource_group.rg_hub.tags
  environment             = var.environment
  hub_vnet_name           = "vnet-hub-${var.environment}"
  hub_address_space       = var.hub_address_space
  firewall_subnet_prefix  = var.firewall_subnet_prefix
  firewall_name           = var.firewall_name
  firewall_policy_name    = var.firewall_policy
  firewall_public_ip_name = var.firewall_pip
  firewall_sku_tier       = var.firewall_sku_tier
  enable_firewall         = var.enable_firewall
  availability_zones      = var.availability_zones
  spoke_address_spaces    = [var.spoke_address_space]
  allowed_egress_fqdns    = var.allowed_egress_fqdns
  enable_diagnostics         = true
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

module "network_spoke" {
  source = "./modules/network-spoke"
  resource_group_name            = azurerm_resource_group.rg_infra.name
  location                       = azurerm_resource_group.rg_infra.location
  tags                           = azurerm_resource_group.rg_infra.tags
  environment                    = var.environment
  spoke_vnet_name                = "vnet-spoke-${var.environment}"
  spoke_address_space            = var.spoke_address_space
  aks_subnet_prefix              = var.aks_subnet_prefix
  private_endpoint_subnet_prefix = var.private_endpoint_subnet_prefix
  pipeline_agent_subnet_prefix   = var.pipeline_agent_subnet_prefix
  route_table_name               = var.route_table_name
  enable_forced_tunnelling       = var.enable_firewall
  firewall_private_ip            = var.enable_firewall ? module.network_hub.firewall_private_ip : ""
  hub_vnet_id                    = module.network_hub.hub_vnet_id
  hub_vnet_name                  = module.network_hub.hub_vnet_name
  hub_resource_group_name        = azurerm_resource_group.rg_hub.name
  internal_consumer_cidrs        = var.internal_consumer_cidrs
  nsg_rules_aks_nodes            = var.nsg_rules_aks_nodes
  nsg_rules_private_endpoints    = var.nsg_rules_private_endpoints
  nsg_rules_pipeline_agents      = var.nsg_rules_pipeline_agents
  enable_diagnostics             = true
  log_analytics_workspace_id     = module.observability.log_analytics_workspace_id
}

# -----------------------------------------------------------------------------
# DNS Components  — Private DNS Zones + VNet Links
# -----------------------------------------------------------------------------

module "private_dns" {
  source = "./modules/private-dns"
  resource_group_name = azurerm_resource_group.rg_hub.name
  tags                = azurerm_resource_group.rg_hub.tags
  zone_names          = var.private_dns_zones
  linked_virtual_networks = {
    spoke = module.network_spoke.spoke_vnet_id
    hub   = module.network_hub.hub_vnet_id
  }
}

# -----------------------------------------------------------------------------
# Diagnostics settings (Log Analytics Workspace, App Insights, Azure Monitor)
# -----------------------------------------------------------------------------

module "observability" {
  source = "./modules/observability"
  resource_group_name          = azurerm_resource_group.rg_infra.name
  location                     = azurerm_resource_group.rg_infra.location
  tags                         = azurerm_resource_group.rg_infra.tags
  log_analytics_name           = "log-${var.environment}-${var.name_prefix}"
  app_insights_name            = "appi-${var.environment}-${var.name_prefix}"
  ampls_name                   = "ampls-${var.environment}-${var.name_prefix}"
  retention_in_days            = var.log_retention_days
  daily_quota_gb               = var.log_daily_quota_gb
  enable_private_link          = var.enable_monitor_private_link
  allow_public_query           = var.allow_public_log_query
  private_endpoint_subnet_id   = module.network_spoke.private_endpoint_subnet_id
  monitor_private_dns_zone_ids = [for z in var.private_dns_zones : module.private_dns.zone_ids[z]]
  alert_email_receivers        = var.alert_email_receivers
  enable_local_auth            = var.enable_local_auth
}

# -----------------------------------------------------------------------------
# ACR Components — ACR + Private Endpoint + Private DNS Zone Link
# -----------------------------------------------------------------------------

module "acr" {
  source = "./modules/container-registry"
  name                      = "acr${var.environment}"
  resource_group_name        = azurerm_resource_group.rg_infra.name
  location                   = azurerm_resource_group.rg_infra.location
  environment                 = var.environment
  tags                       = azurerm_resource_group.rg_infra.tags
  private_endpoint_subnet_id = module.network_spoke.private_endpoint_subnet_id
  private_dns_zone_id        = module.private_dns.zone_ids["privatelink.azurecr.io"]
  pull_principal_ids         = [module.aks.kubelet_identity_object_id]
  push_principal_ids         = [module.identity.principal_id]
  acr_untagged_retention_days = var.acr_untagged_retention_days
  zone_redundancy_enabled    = var.zone_redundancy_enabled
  enable_diagnostics         = true
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

# -----------------------------------------------------------------------------
# Storage Components — Storage Account + Private Endpoint + Private DNS Zone Link
# -----------------------------------------------------------------------------

module "storage" {
  source   = "../modules/storage-account"
  for_each = { for i in range(var.storage_account_count) : format("%02d", i + 1) => i }

  name                           = "sa${var.environment}${each.key}"
  resource_group_name            = azurerm_resource_group.rg_infra.name
  location                       = azurerm_resource_group.rg_infra.location
  tags                           = azurerm_resource_group.rg_infra.tags
  replication_type               = var.storage_replication_type
  cache_container_name           = var.cache_container_name
  cache_expiry_days              = var.cache_expiry_days
  private_endpoint_subnet_id     = module.network_spoke.private_endpoint_subnet_id
  blob_private_dns_zone_id       = module.private_dns.zone_ids["privatelink.blob.core.windows.net"]
  blob_private_dns_zone_name     = module.private_dns.zone_names["privatelink.blob.core.windows.net"]
  data_contributor_principal_ids = [module.identity.principal_id]
  enable_diagnostics             = true
  log_analytics_workspace_id     = module.observability.log_analytics_workspace_id
}

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

# ---------------------------------------------------------------------------
# AKS Components + Private Endpoint + Private DNS Zone Link
# ---------------------------------------------------------------------------
module "aks" {
  source = "./modules/aks"
  name                        = "aks-${var.environment}-${var.name_prefix}"
  node_resource_group_name    = "rg-${var.environment}-${var.name_prefix}-aks-nodes"
  control_plane_identity_name = "id-aks-control-${var.environment}-${var.name_prefix}"
  resource_group_name         = azurerm_resource_group.rg_infra.name
  location                    = azurerm_resource_group.rg_infra.location
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  tags                        = azurerm_resource_group.rg_infra.tags
  kubernetes_version          = var.kubernetes_version
  automatic_upgrade_channel   = var.automatic_upgrade_channel
  sku_tier                    = var.aks_sku_tier
  node_subnet_id              = module.network_spoke.aks_subnet_id
  enable_forced_tunnelling    = var.enable_firewall
  private_dns_zone_id         = module.private_dns.zone_ids["privatelink.westeurope.azmk8s.io"]
  route_table_id              = module.network_spoke.route_table_id
  pod_cidr                    = var.pod_cidr
  service_cidr                = var.service_cidr
  dns_service_ip              = var.dns_service_ip
  availability_zones          = var.availability_zones
  system_node_vm_size         = var.system_node_vm_size
  system_node_min_count       = var.system_node_min_count
  system_node_max_count       = var.system_node_max_count
  enable_user_node_pool       = var.enable_user_node_pool
  taint_system_pool           = var.taint_system_pool
  user_node_vm_size           = var.user_node_vm_size
  user_node_min_count         = var.user_node_min_count
  user_node_max_count         = var.user_node_max_count
  admin_group_object_ids      = var.aks_admin_group_object_ids
  reader_group_object_ids     = var.aks_reader_group_object_ids
  deployer_principal_ids      = var.pipeline_principal_ids
  enable_diagnostics          = true
  log_analytics_workspace_id  = module.observability.log_analytics_workspace_id
}

# ---------------------------------------------------------------------------
# Identity Components
# ---------------------------------------------------------------------------

module "identity" {
  source = "./modules/identity"

  identity_name       = "id-aks-${var.environment}-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.rg_infra.name
  location            = azurerm_resource_group.rg_infra.location
  tags                = azurerm_resource_group.rg_infra.tags
  oidc_issuer_url     = module.aks.oidc_issuer_url

  service_accounts = {
    api = {
      namespace            = var.app_namespace
      service_account_name = var.app_service_account_name
    }
  }
}

# ---------------------------------------------------------------------------
# Self-hosted Azure Pipelines agent — Linux VM in rg_infra
# ---------------------------------------------------------------------------

module "pipeline_agent" {
  count  = var.enable_pipeline_agent_vm ? 1 : 0
  source = "./modules/pipeline-agent"

  name                 = "vm-agent-${var.environment}-${var.name_prefix}"
  resource_group_name  = azurerm_resource_group.rg_infra.name
  location             = azurerm_resource_group.rg_infra.location
  tags                 = azurerm_resource_group.rg_infra.tags
  subnet_id            = module.network_spoke.pipeline_agent_subnet_id
  vm_size              = var.agent_vm_size
  admin_username       = var.agent_admin_username
  admin_ssh_public_key = var.agent_admin_ssh_public_key
  key_vault_id         = module.key_vault.id
  key_vault_uri        = module.key_vault.vault_uri
  pat_secret_name      = var.agent_pat_secret_name
  devops_org_url       = var.devops_org_url
  devops_pool_name     = var.agent_pool_name
  agent_version        = var.agent_package_version
  terraform_version   = var.agent_terraform_version
  helm_version        = var.agent_helm_version
  kubectl_version     = var.agent_kubectl_version
  trivy_version       = var.agent_trivy_version
  gitleaks_version    = var.agent_gitleaks_version
  kubeconform_version = var.agent_kubeconform_version
  enable_diagnostics  = true
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

# ---------------------------------------------------------------------------
# Governance
# ---------------------------------------------------------------------------
module "governance" {
  source = "./modules/governance"

  subscription_id          = "${var.environment}SubscriptionId"
  allowed_locations        = var.policy_allowed_locations
  required_tags            = var.policy_required_tags
  kubernetes_policy_effect = var.kubernetes_policy_effect
  enforce                  = var.policy_enforce
  depends_on = [module.aks, module.storage, module.acr]
}
