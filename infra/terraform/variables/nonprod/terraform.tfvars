environment = "nonprod"

name_prefix = "iac"

nsg_rules_aks_nodes = [
  {
    name                       = "allow-internal-https-in"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "8080"]
    source_address_prefixes    = ["10.0.0.0/8"]
    destination_address_prefix = [""]
  },
  {
    name                       = "deny-internet-in"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
]

nsg_rules_private_endpoints = [
  {
    name                       = "allow-vnet-clients-in"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefixes    = compact([var.aks_subnet_prefix, var.pipeline_agent_subnet_prefix])
    destination_address_prefix = var.private_endpoint_subnet_prefix
  },
  {
    name                       = "deny-internet-in"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
]

nsg_rules_pipeline_agents = []

tags = {
  workload  = "iac-hiring-test"
  managedBy = "terraform"
  owner     = "abn-amro"
  environment = "nonprod"
}