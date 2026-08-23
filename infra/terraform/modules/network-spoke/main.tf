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
