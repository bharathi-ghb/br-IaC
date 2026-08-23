
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

# The name AzureFirewallSubnet is RESERVED - Azure requires it verbatim, it must be
# /26 or larger (enforced by the validation block on firewall_subnet_prefix), and it
# cannot have an NSG attached because the firewall manages its own filtering. Same
# class of rule as GatewaySubnet and AzureBastionSubnet.
resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub_vnet.name
  address_prefixes     = [var.firewall_subnet_prefix]

  lifecycle {
    create_before_destroy = true
  }
}

# The platform's SINGLE, KNOWN egress address. Everything the workload sends to the
# internet is SNAT'd to this IP, which means an upstream partner could allow-list us
# if they ever needed to - and it means egress is attributable to one address in any
# third-party's logs.
#
# Zonal (zones = 1,2,3) so a single-zone failure does not take egress down.
#
# SCALING NOTE: Azure Firewall gets 2,496 SNAT ports PER public IP. A NAT Gateway gets
# 64,512. Under high outbound concurrency this is the ceiling that bites first, and
# the symptom is nasty - intermittent, load-correlated connection failures that look
# like an upstream problem. Mitigations: add public IPs, or put a NAT Gateway on the
# AzureFirewallSubnet BEHIND the firewall (a supported pattern giving firewall policy
# with NAT Gateway port scale).
resource "azurerm_public_ip" "firewall" {
  name                = var.firewall_public_ip_name
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.availability_zones
  tags                = var.tags
}

# POLICY-driven rather than classic rules: policies are a separate resource that can
# be versioned, inherited by child policies, and shared across firewalls - so a base
# organisational policy can be inherited and extended per environment.
#
# threat_intelligence_mode = "Deny" blocks traffic to/from known-malicious IPs and
# domains using Microsoft's feed. Cheap, high-value, and worth naming out loud.
#
# dns { proxy_enabled = true } is REQUIRED for FQDN-based network rules to be reliable:
# the firewall must resolve the name itself and see the same answer the client saw,
# otherwise a client could resolve a name to one IP and connect to another (DNS
# rebinding). It also gives us DNS query logs on the firewall, which in this design is
# the ONLY DNS telemetry we have - private DNS zones do not emit resource logs.
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

# THE EGRESS ALLOW-LIST. This is where 'private does not mean isolated' is implemented.
#
# Four rule groups, each answering a different requirement:
#
#  1. allow-workload-egress (app rule, priority 100)
#     The actual business dependency: api.tvmaze.com on HTTPS 443, and nothing else.
#     An APPLICATION rule inspects SNI/Host, so it is FQDN-aware rather than IP-based -
#     which matters because a public API's IPs change without notice.
#
#  2. allow-aks-platform (app rule, priority 200)
#     destination_fqdn_tags = ["AzureKubernetesService"] - Microsoft's curated tag
#     covering mcr.microsoft.com, management.azure.com, login.microsoftonline.com,
#     packages.microsoft.com, acs-mirror.azureedge.net and more. Using the TAG rather
#     than hand-listing these delegates maintenance to Microsoft. Teams that
#     hand-maintain this list break every node pool upgrade when Microsoft adds an
#     endpoint. Trade-off accepted: less visibility into precisely what is allowed.
#
#  3. ntp (network rule, UDP/123)
#     Nodes with skewed clocks fail TLS and certificate validation. A classic,
#     maddening failure that presents as random auth errors.
#
#  4. azure-control-plane (network rule, AzureCloud.<region> on 443/1194/9000)
#     The tunnel between the nodes and the AKS control plane.
#
# Without groups 2-4 a private cluster with forced tunnelling simply never finishes
# provisioning - nodes cannot join. That is the most common 'my private AKS hangs at
# Creating' cause.
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

# KNOWN DEFECT (docs/02 P0-7): this resource, the public IP, the policy and the subnet
# above have NO count, yet they are referenced with [0] indexes here and in outputs.tf.
# Terraform errors with 'this value does not have any indices'.
#
# Worse, var.enable_firewall is honoured on the rule collection group and on the
# outputs but NOT on the firewall itself - so enable_firewall = false would still
# deploy a ~$950/month firewall with no rules, breaking egress AND still costing money.
# Fix: count = var.enable_firewall ? 1 : 0 on the PIP, policy and firewall.
#
# ALSO: var.firewall_name is declared and passed from tfvars but the name is hardcoded
# to "fw-hub-${var.environment}" here. A dead variable that LOOKS live is worse than no
# variable - an operator will believe they changed something when they did not.
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
