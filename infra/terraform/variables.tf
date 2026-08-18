# -----------------------------------------------------------------------------
# Common Variables
# -----------------------------------------------------------------------------

variable "location" {
  type        = string
  default     = "westeurope"
  description = "Azure region"
}

variable "name_prefix" {
  type        = string
  default     = ""
  description = "named resources"
}

variable "environment" {
  type        = string
  default     = ""
  description = "Environment name"
}

variable "tags" {
  type = map(string)
  default = {
    workload  = "iac"
    managedBy = "terraform"
    owner     = "abn-amro"
    environment = ""
  }
}

# -----------------------------------------------------------------------------
# Network Components Variables
# -----------------------------------------------------------------------------

variable "hub_address_space" {
  description = "CIDR of the hub VNet."
  type        = string
}

variable "firewall_subnet_prefix" {
  description = "CIDR of AzureFirewallSubnet."
  type        = string
}

variable "spoke_address_space" {
  description = "CIDR of spoke VNet."
  type        = string
}

variable "aks_subnet_prefix" {
  description = "CIDR of AKS node subnet."
  type        = string
}

variable "private_endpoint_subnet_prefix" {
  description = "CIDR of private endpoint subnet."
  type        = string
}

variable "pipeline_agent_subnet_prefix" {
  description = "CIDR of self-hosted pipeline agent subnet."
  type        = string
  default     = ""
}

variable "internal_consumer_cidrs" {
  description = "Internal networks permitted."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "enable_firewall" {
  description = "Deploy Azure Firewall."
  type        = bool
  default     = true
}

variable "firewall_sku_tier" {
  description = "Azure Firewall tier."
  type        = string
  default     = "Standard"
}

variable "firewall_policy" {
  description = "Azure Firewall tier."
  type        = string
  default     = ""
}

variable "firewall_pip" {
  description = "Azure Firewall tier."
  type        = string
  default     = ""
}

variable "allowed_egress_fqdns" {
  description = "External FQDNs."
  type        = list(string)
  default     = []
}

variable "availability_zones" {
  description = "Availability zones."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "route_table_name" {
  description = "Name of the route table"
  type        = string
  default     = ""
}

variable "firewall_name" {
  description = "Name of the Azure Firewall"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# DNS Components Variables
# -----------------------------------------------------------------------------

variable "private_dns_zones" {
  description = "List of private DNS zones to create."
  type        = list(string)
  default     = []
}
