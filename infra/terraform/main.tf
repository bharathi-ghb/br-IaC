# =============================================================================
#                   Central Terraform Module.
# =============================================================================
# Pre-requisites: RG
# =============================================================================

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "rg_infra" {
  name     = "rg-${var.environment}-${var.name_prefix}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_resource_group" "rg_hub" {
  name     = "rg-${var.environment}-${var.name_prefix}-hub"
  location = var.location
  tags     = var.tags
}

# -----------------------------------------------------------------------------
# 1. Network — VNets + subnets + NSGs + Firewall + Spoke Peering + Association
# -----------------------------------------------------------------------------
module "network_hub" {
  source = "../modules/network-hub"
  location                = azurerm_resource_group.rg_hub.location
  resource_group_name     = azurerm_resource_group.rg_hub.name
  tags                    = azurerm_resource_group.rg_hub.tags
  hub_vnet_name           = "vnet-hub-${var.environment}"
  hub_address_space       = var.hub_address_space
  firewall_subnet_prefix  = var.firewall_subnet_prefix
  firewall_name           = var.firewall_name
  firewall_policy_name    = var.firewall_policy
  firewall_public_ip_name = var.firewall_pip
  firewall_sku_tier       = var.firewall_sku_tier
  enable_firewall         = var.enable_firewall
  availability_zones      = var.availability_zones
  route_table_name        = var.route_table_name
  spoke_address_spaces    = [var.spoke_address_space]
  allowed_egress_fqdns    = var.allowed_egress_fqdns
  enable_diagnostics      = true
}

module "network_spoke" {
  source = "../modules/network-spoke"
  resource_group_name            = azurerm_resource_group.rg_infra.name
  location                       = azurerm_resource_group.rg_infra.location
  tags                           = azurerm_resource_group.rg_infra.tags
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
  enable_diagnostics             = true
}
