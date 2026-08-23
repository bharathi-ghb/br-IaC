# ---------------------------------------------------------------------------
# VNet - Spoke
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "spoke_vnet" {
  name                = var.spoke_vnet_name
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.spoke_address_space]
  tags                = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# VNet Peering Hub <-------> Spoke
# ---------------------------------------------------------------------------

# BIDIRECTIONAL PEERING. Both directions are required - a peering is not implicitly
# two-way, and a one-sided peering sits in 'Initiated' state and passes no traffic.
#
# allow_forwarded_traffic = true is the setting that makes the firewall hairpin work.
# Traffic returning from the firewall arrives with a source address OUTSIDE the peered
# VNet's range; without this flag the peering drops it. It is a very common cause of
# 'the route is right but nothing gets through'.
#
# allow_gateway_transit / use_remote_gateways are false because there is no
# ExpressRoute or VPN gateway in this design. They would become true the moment
# on-premises connectivity entered the picture.
#
# NOTE: peering is NON-TRANSITIVE. A second spoke could not reach this one through the
# hub by peering alone - that needs UDRs via the firewall, or Azure Virtual WAN, which
# is the answer past roughly 5-10 spokes.
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "peer-spoke-to-hub"
  resource_group_name       = var.resource_group_name
  virtual_network_name      = azurerm_virtual_network.spoke_vnet.name
  remote_virtual_network_id = var.hub_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                      = "peer-hub-to-spoke"
  resource_group_name       = var.hub_resource_group_name
  virtual_network_name      = var.hub_vnet_name
  remote_virtual_network_id = azurerm_virtual_network.spoke_vnet.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false

  lifecycle {
    create_before_destroy = true
    prevent_destroy       = true
  }
}

# ---------------------------------------------------------------------------
# AKS Nodes (Subnet + NSG + NSG rules + NSG association)
# ---------------------------------------------------------------------------

# AKS NODE SUBNET. Sized /24 (251 usable) which is generous - and it is generous
# BECAUSE of Azure CNI Overlay.
#
# With traditional Azure CNI, every POD consumes a VNet IP: a 50-node cluster at 50
# pods/node needs ~2,500 addresses, roughly a /21 per cluster. In a bank, RFC1918 space
# is a governed, contended, slow-to-obtain resource, so that turns every cluster into
# an IPAM negotiation and eventually a renumbering exercise. With Overlay, only nodes
# and internal load balancer IPs consume VNet addresses - so this /24 is sufficient
# regardless of pod count.
#
# TRADE-OFF: pods are not directly addressable from the VNet. That is fine here
# because ingress arrives via a Service and egress SNATs to the node IP - which is also
# why every NSG and firewall rule below targets the NODE subnet, never pod IPs.
resource "azurerm_subnet" "aks_nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke_vnet.name
  address_prefixes     = [var.aks_subnet_prefix]

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------

resource "azurerm_network_security_group" "aks_nodes" {
  name                = "nsg-aks-nodes"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
  }

# DATA-DRIVEN NSG RULES. Rules arrive as a typed list(object) from tfvars, so a rule
# change is an environment config diff rather than a module code change - visible in
# the plan and reviewable in a PR without forking the module.
#
# TRADE-OFF: weaker type safety. A bad priority or protocol string becomes an
# apply-time Azure error rather than a plan-time Terraform error. Worth adding
# validation blocks.
#
# SUBTLE BUG RISK: for_each keys on nsg.priority, so TWO RULES WITH THE SAME PRIORITY
# SILENTLY COLLIDE and one disappears. A precondition asserting uniqueness would catch
# it.
#
# KNOWN DEFECT (docs/02 P1-4): var.nsg_rules_aks_nodes is never passed from the root
# module, so this for_each is empty and the NSG deploys with NO rules at all.
resource "azurerm_network_security_rule" "aks_nodes" {
  for_each                     = { for nsg in var.nsg_rules_aks_nodes : nsg.priority => nsg }
  name                         = each.value.name
  priority                     = each.key
  direction                    = each.value.direction
  description                  = each.value.description
  access                       = each.value.access
  protocol                     = each.value.protocol
  source_address_prefixes      = try(each.value.source_address_prefixes, null)
  source_port_ranges           = each.value.source_port_ranges
  destination_port_ranges      = try(each.value.destination_port_ranges, null)
  destination_address_prefixes = try(each.value.destination_address_prefixes, null)
  resource_group_name          = var.resource_group_name
  network_security_group_name  = azurerm_network_security_group.aks_nodes.name

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_subnet_network_security_group_association" "aks_nodes" {
  subnet_id                 = azurerm_subnet.aks_nodes.id
  network_security_group_id = azurerm_network_security_group.aks_nodes.id
}

# ---------------------------------------------------------------------------

# FORCED TUNNELLING. The 0.0.0.0/0 -> VirtualAppliance route below is what makes ALL
# node egress traverse the firewall.
#
# It only works in combination with outbound_type = "userDefinedRouting" on the cluster
# (see modules/aks). With the default outbound_type = loadBalancer, AKS provisions its
# own Standard Load Balancer with a public IP for outbound SNAT - a second, unmonitored
# exit that bypasses this route entirely. You would have a firewall, a UDR and an
# allow-list, and a door standing open beside them.
#
# ORDERING: this route table must exist BEFORE the cluster is created, and the AKS
# control-plane identity needs Network Contributor on it. That is a hard dependency,
# which is why modules/aks has an explicit depends_on for the role assignment.
resource "azurerm_route_table" "aks_nodes" {
  name                = "rt-aks_nodes"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_route" "aks_nodes" {
  name                = "default-to-firewall"
  resource_group_name = azurerm_route_table.aks_nodes.resource_group_name
  route_table_name    = azurerm_route_table.aks_nodes.name
  address_prefix      = "0.0.0.0/0"
  next_hop_type       = "VirtualAppliance"
  next_hop_in_ip_address = var.firewall_private_ip
}

resource "azurerm_subnet_route_table_association" "aks_nodes" {
  subnet_id      = azurerm_subnet.aks_nodes.id
  route_table_id = azurerm_route_table.aks_nodes.id
}

# ---------------------------------------------------------------------------
# Private Endpoints (Subnet + NSG + NSG rules + NSG association)
# ---------------------------------------------------------------------------

# PRIVATE ENDPOINT SUBNET. One private IP per endpoint: ACR, Key Vault, Blob, the AKS
# API server, and AMPLS.
#
# private_endpoint_network_policies = "Enabled" matters more than it looks.
# HISTORICALLY, private endpoint traffic BYPASSED NSGs entirely - so without this
# setting, the 'only the AKS and agent subnets may reach 443' rule below would be
# purely decorative. Turning network policies on is what makes the NSG genuinely
# enforced for PE traffic. Knowing this is a strong current-knowledge signal.
#
# private_link_service_network_policies_enabled = false is the counterpart, needed only
# if this subnet ever HOSTS a Private Link Service (it does not here) - included for
# symmetry.
resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke_vnet.name
  address_prefixes     = [var.private_endpoint_subnet_prefix]
  private_endpoint_network_policies = "Enabled"
  private_link_service_network_policies_enabled = false

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-private-endpoints"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_network_security_rule" "private_endpoints" {
  for_each                     = { for nsg in var.nsg_rules_private_endpoints : nsg.priority => nsg }
  name                         = each.value.name
  priority                     = each.key
  direction                    = each.value.direction
  description                  = each.value.description
  access                       = each.value.access
  protocol                     = each.value.protocol
  source_address_prefixes      = compact([var.aks_subnet_prefix, var.pipeline_agent_subnet_prefix])
  source_port_ranges           = each.value.source_port_ranges
  destination_port_ranges      = try(each.value.destination_port_ranges, null)
  destination_address_prefixes = [var.private_endpoint_subnet_prefix]
  resource_group_name          = var.resource_group_name
  network_security_group_name  = azurerm_network_security_group.private_endpoints.name

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# ---------------------------------------------------------------------------

# NOTE THE DELIBERATE ABSENCE OF A ROUTE HERE (the commented-out stub below).
#
# Private endpoint traffic must NOT be forced-tunnelled through the firewall. Doing so
# breaks the Private Link data path with asymmetric routing - the return path does not
# traverse the firewall. Azure also installs a /32 system route per private endpoint
# that takes precedence over a 0.0.0.0/0 UDR anyway, so the route would be both harmful
# and largely ineffective.
#
# The empty route table exists so that a future, specific route can be added without
# restructuring. TIDY-UP: delete the commented-out stub before submitting -
# commented-out code reads as unfinished work rather than as a deliberate decision.
resource "azurerm_route_table" "private_endpoints" {
  name                = "rt-private-endpoints"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

/*
resource "azurerm_route" "private_endpoints" {
  name                = ""
  resource_group_name = azurerm_route_table.private_endpoints.resource_group_name
  route_table_name    = azurerm_route_table.private_endpoints.name
  address_prefix      = ""
  next_hop_type       = ""
  next_hop_in_ip_address = ""
}
*/

resource "azurerm_subnet_route_table_association" "private_endpoints" {
  subnet_id      = azurerm_subnet.private_endpoints.id
  route_table_id = azurerm_route_table.private_endpoints.id
}

# ---------------------------------------------------------------------------
# Pipeline Agents (Subnet + NSG + NSG rules + NSG association)
# ---------------------------------------------------------------------------

# PIPELINE AGENT SUBNET - small (/26) and deliberately SEPARATE from the node subnet
# so the private-endpoint NSG can allow the agent explicitly and that grant is
# auditable as its own rule rather than hidden inside a broad VNet allow.
#
# KNOWN GAP (docs/02 P2-12): this subnet has a route table but NO default route to the
# firewall, so the agent VM egresses to the internet UNFILTERED - outside the Azure
# Firewall allow-list. cloud-init pulls from download.docker.com, dl.k8s.io, github.com,
# releases.hashicorp.com, pypi.org and deb.nodesource.com over that unfiltered path.
# That contradicts the egress-control story on the machine that deploys to production.
# Fix: route it through the firewall and extend the FQDN allow-list, or bake a golden
# agent image so it never needs internet access at all.
resource "azurerm_subnet" "pipeline_agents" {
  name                 = "snet-pipeline-agents"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke_vnet.name
  address_prefixes     = [var.pipeline_agent_subnet_prefix]

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_network_security_group" "pipeline_agents" {
  name                = "nsg-pipeline-agents"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_network_security_rule" "pipeline_agents" {
  for_each                     = { for nsg in var.nsg_rules_pipeline_agents : nsg.priority => nsg }
  name                         = each.value.name
  priority                     = each.key
  direction                    = each.value.direction
  description                  = each.value.description
  access                       = each.value.access
  protocol                     = each.value.protocol
  source_address_prefixes      = try(each.value.source_address_prefixes, null)
  source_port_ranges           = try(each.value.source_port_ranges, null)
  destination_port_ranges      = try(each.value.destination_port_ranges, null)
  destination_address_prefixes = try(each.value.destination_address_prefixes, null)
  resource_group_name          = var.resource_group_name
  network_security_group_name  = azurerm_network_security_group.pipeline_agents.name

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_subnet_network_security_group_association" "pipeline_agents" {
  subnet_id                 = azurerm_subnet.pipeline_agents.id
  network_security_group_id = azurerm_network_security_group.pipeline_agents.id
}

# ---------------------------------------------------------------------------

resource "azurerm_route_table" "pipeline_agents" {
  name                = "rt-pipeline-agents"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

/*
resource "azurerm_route" "pipeline_agents" {
  name                = ""
  resource_group_name = azurerm_route_table.pipeline_agents.resource_group_name
  route_table_name    = azurerm_route_table.pipeline_agents.name
  address_prefix      = ""
  next_hop_type       = ""
  next_hop_in_ip_address = ""
}
*/

resource "azurerm_subnet_route_table_association" "pipeline_agents" {
  subnet_id      = azurerm_subnet.pipeline_agents.id
  route_table_id = azurerm_route_table.pipeline_agents.id
}

resource "azurerm_monitor_diagnostic_setting" "network_spoke" {
  for_each = var.enable_diagnostics ? toset(["network_spoke"]) : toset([])

  name                       = "network-spoke-diagnostics-to-law"
  target_resource_id         = azurerm_virtual_network.spoke_vnet.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { 
    category_group = "allLogs" 
  }
  enabled_metric {
    category = "AllMetrics"
  }
}
