
# ---------------------------------------------------------------------------
# VNet - Hub + Firewall resources
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "hub_vnet" {
  name                = var.hub_vnet_name
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.hub_address_space]
  tags                = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub_vnet.name
  address_prefixes     = [var.firewall_subnet_prefix]
}

resource "azurerm_public_ip" "firewall" {
  name                = var.firewall_public_ip_name
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.availability_zones
  tags                = var.tags
}

resource "azurerm_firewall_policy" "fwp" {
  name                     = var.firewall_policy_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  sku                      = var.firewall_sku_tier
  threat_intelligence_mode = "Deny"
  tags                     = var.tags
  dns {
    proxy_enabled = true
  }
}

resource "azurerm_firewall" "fw" {
  name                = "fw-hub-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "AZFW_VNet"
  sku_tier            = var.firewall_sku_tier
  firewall_policy_id  = azurerm_firewall_policy.fwp[0].id
  zones               = var.availability_zones
  tags                = var.tags

  ip_configuration {
    name                 = "ipconfig"
    subnet_id            = azurerm_subnet.firewall[0].id
    public_ip_address_id = azurerm_public_ip.firewall[0].id
  }
  
  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_monitor_diagnostic_setting" "network_hub" {
  for_each = var.enable_diagnostics ? toset(["network_hub"]) : toset([])

  name                       = "network-hub-diagnostics-to-law"
  target_resource_id         = azurerm_virtual_network.hub_vnet.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { 
    category_group = "allLogs" 
  }
  enabled_metric {
    category = "AllMetrics"
  }
}
