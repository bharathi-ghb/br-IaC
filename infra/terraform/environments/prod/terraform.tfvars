environment = "prod"

name_prefix = "iac"

hub_address_space              = "10.200.0.0/22"
firewall_subnet_prefix         = "10.200.0.0/26"
spoke_address_space            = "10.201.0.0/22"
aks_subnet_prefix              = "10.201.0.0/24"
private_endpoint_subnet_prefix = "10.201.1.0/24"
pipeline_agent_subnet_prefix   = "10.201.2.0/26"

firewall_name    = "fw-prod-iac"
firewall_policy  = "fwpol-prod-iac"
firewall_pip     = "pip-fw-prod-iac"
route_table_name = "rt-prod-iac"

nsg_rules_aks_nodes = [
  {
    name                          = "allow-internal-https-in"
    priority                      = 100
    direction                     = "Inbound"
    access                        = "Allow"
    protocol                      = "Tcp"
    source_port_ranges            = ["*"]
    destination_port_ranges       = ["443", "8080"]
    source_address_prefixes       = ["10.0.0.0/8"]
    destination_address_prefixes  = []
  },
  {
    name                          = "deny-internet-in"
    priority                      = 4000
    direction                     = "Inbound"
    access                        = "Deny"
    protocol                      = "*"
    source_port_ranges            = ["*"]
    destination_port_ranges       = ["*"]
    source_address_prefixes       = ["Internet"]
    destination_address_prefixes  = ["*"]
  }
]

nsg_rules_private_endpoints = [
  {
    name                          = "allow-vnet-clients-in"
    priority                      = 100
    direction                     = "Inbound"
    access                        = "Allow"
    protocol                      = "Tcp"
    source_port_ranges            = ["*"]
    destination_port_ranges       = ["443"]
    source_address_prefixes       = ["10.201.0.0/24", "10.201.2.0/26"]
    destination_address_prefixes  = ["10.201.1.0/24"]
  },
  {
    name                          = "deny-internet-in"
    priority                      = 4000
    direction                     = "Inbound"
    access                        = "Deny"
    protocol                      = "*"
    source_port_ranges            = ["*"]
    destination_port_ranges       = ["*"]
    source_address_prefixes       = ["Internet"]
    destination_address_prefixes  = ["*"]
  }
]

nsg_rules_pipeline_agents = []

tags = {
  workload  = "iac"
  managedBy = "terraform"
  owner     = "abn-amro"
  environment = "prod"
}

private_dns_zones = [
  "privatelink.blob.core.windows.net",
  "privatelink.vaultcore.azure.net",
  "privatelink.azurecr.io",
  "privatelink.monitor.azure.com",
  "privatelink.ods.opinsights.azure.com",
  "privatelink.oms.opinsights.azure.com",
  "privatelink.agentsvc.azure-automation.net",
  "privatelink.westeurope.azmk8s.io"
]

alert_email_receivers = {
  team1 = "xyz@abc.com"
  team2 = "app@abc.com"
  team3 = "db@abc.com"
}

agent_admin_ssh_public_key = "ssh-ed25519 AAAA...replace-with-a-real-public-key... agent@prod"
devops_org_url             = "https://dev.azure.com/example-bank"
