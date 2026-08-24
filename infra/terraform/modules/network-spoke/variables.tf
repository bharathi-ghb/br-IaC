variable "resource_group_name" {
  description = "Resource group for the spoke network resources."
  type        = string
  default     = ""
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource created by this module."
  type        = map(string)
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "spoke_vnet_name" {
  description = "Name of the spoke virtual network."
  type        = string
  default     = ""
}

variable "spoke_address_space" {
  description = "CIDR of the spoke virtual network."
  type        = string
  default     = ""
}

variable "aks_subnet_prefix" {
  description = "CIDR for the AKS node subnet. With CNI Overlay this only needs to cover nodes and internal load balancer IPs."
  type        = string
  default     = ""
}

variable "private_endpoint_subnet_prefix" {
  description = "CIDR for the private endpoint subnet."
  type        = string
  default     = ""
}

variable "pipeline_agent_subnet_prefix" {
  description = "CIDR for the self-hosted pipeline agent subnet. Pass an empty string if agents live in a different VNet."
  type        = string
  default     = ""
}

variable "route_table_name" {
  description = "Name of the route table that forces egress through the firewall."
  type        = string
  default     = ""
}

variable "enable_forced_tunnelling" {
  description = "Create the route table that sends 0.0.0.0/0 to the firewall. Boolean rather than a null check so the count is known at plan time."
  type        = bool
  default     = true
}

variable "firewall_private_ip" {
  description = "Private IP of the hub firewall, used as the default-route next hop. Required when enable_forced_tunnelling is true."
  type        = string
  default     = ""
}

variable "hub_vnet_id" {
  description = "Resource ID of the hub virtual network to peer with."
  type        = string
  default     = ""
}

variable "hub_vnet_name" {
  description = "Name of the hub virtual network (needed to create the reverse peering)."
  type        = string
  default     = ""
}

variable "hub_resource_group_name" {
  description = "Resource group of the hub virtual network."
  type        = string
  default     = ""
}

variable "internal_consumer_cidrs" {
  description = "CIDRs of internal networks allowed to call the API through the internal load balancer."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "nsg_rules_aks_nodes" {
  description = "(Optional) A list of security rules to apply to the Network Security Group"
  type = list(object({
    access                                     = string
    description                                = optional(string, "")
    destination_address_prefixes               = optional(list(string), null)
    destination_application_security_group_ids = optional(list(string), [])
    destination_port_ranges                    = optional(list(string), null)
    direction                                  = optional(string, "Inbound")
    name                                       = string
    priority                                   = number
    protocol                                   = optional(string, "Tcp")
    source_address_prefixes                    = var.internal_consumer_cidrs
    source_application_security_group_ids      = optional(list(string), [])
    source_port_ranges                         = optional(list(string), null)
  }))
  default = []
}

variable "nsg_rules_private_endpoints" {
  description = "(Optional) A list of security rules to apply to the Network Security Group"
  type = list(object({
    access                                     = string
    description                                = optional(string, "")
    destination_address_prefixes               = optional(list(string), null)
    destination_application_security_group_ids = optional(list(string), [])
    destination_port_ranges                    = optional(list(string), null)
    direction                                  = optional(string, "Inbound")
    name                                       = string
    priority                                   = number
    protocol                                   = optional(string, "Tcp")
    source_address_prefixes                    = var.internal_consumer_cidrs
    source_application_security_group_ids      = optional(list(string), [])
    source_port_ranges                         = optional(list(string), null)
  }))
  default = []
}

variable "nsg_rules_pipeline_agents" {
  description = "(Optional) A list of security rules to apply to the Network Security Group"
  type = list(object({
    access                                     = string
    description                                = optional(string, "")
    destination_address_prefixes               = optional(list(string), null)
    destination_application_security_group_ids = optional(list(string), [])
    destination_port_ranges                    = optional(list(string), null)
    direction                                  = optional(string, "Inbound")
    name                                       = string
    priority                                   = number
    protocol                                   = optional(string, "Tcp")
    source_address_prefixes                    = optional(list(string), null)
    source_application_security_group_ids      = optional(list(string), [])
    source_port_ranges                         = optional(list(string), null)
  }))
  default = []
}

variable "enable_diagnostics" {
  description = "Send resource logs to Log Analytics. A boolean (rather than a null check on the workspace ID) keeps resource counts known at plan time."
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Workspace for diagnostics. Required when enable_diagnostics is true."
  type        = string
  default     = ""
}
