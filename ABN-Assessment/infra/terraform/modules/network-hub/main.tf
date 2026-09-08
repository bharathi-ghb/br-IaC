
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
  count = var.enable_firewall ? 1 : 0
  name                 = "AzureFirewallSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub_vnet.name
  address_prefixes     = [var.firewall_subnet_prefix]

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_public_ip" "firewall" {
  count = var.enable_firewall ? 1 : 0
  name                = var.firewall_public_ip_name
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.availability_zones
  tags                = var.tags
}

resource "azurerm_firewall_policy" "fwp" {
  count = var.enable_firewall ? 1 : 0
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

resource "azurerm_firewall_policy_rule_collection_group" "egress" {
  count = var.enable_firewall ? 1 : 0

  name               = "egress-rules"
  firewall_policy_id = azurerm_firewall_policy.fwp[0].id
  priority           = 500

  application_rule_collection {
    name     = "allow-workload-egress"
    priority = 100
    action   = "Allow"

    rule {
      name             = "tvmaze-api"
      source_addresses = var.spoke_address_spaces
      destination_fqdns = var.allowed_egress_fqdns
      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  application_rule_collection {
    name     = "allow-aks-platform"
    priority = 200
    action   = "Allow"

    rule {
      name             = "aks-service-tags"
      source_addresses = var.spoke_address_spaces
      destination_fqdn_tags = ["AzureKubernetesService"]
    }
  }

  network_rule_collection {
    name     = "allow-aks-network"
    priority = 300
    action   = "Allow"

    rule {
      name                  = "ntp"
      source_addresses      = var.spoke_address_spaces
      destination_addresses = ["*"]
      destination_ports     = ["123"]
      protocols             = ["UDP"]
    }

    rule {
      name                  = "azure-control-plane"
      source_addresses      = var.spoke_address_spaces
      destination_addresses = ["AzureCloud.${var.location}"]
      destination_ports     = ["443", "1194", "9000"]
      protocols             = ["TCP", "UDP"]
    }
  }
}

resource "azurerm_firewall" "fw" {
  count = var.enable_firewall ? 1 : 0
  name                = var.firewall_name
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

resource "azurerm_monitor_diagnostic_setting" "firewall_hub" {
  count = var.enable_firewall && var.enable_diagnostics ? 1 : 0

  name                           = "network-hub-diagnostics-to-law"
  target_resource_id             = azurerm_firewall.fw[0].id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log { category_group = "allLogs" }

  enabled_metric {
    category = "AllMetrics"
  }
}
