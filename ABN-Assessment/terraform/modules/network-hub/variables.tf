variable "resource_group_name" {
  description = "Resource group that will contain the hub network resources."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource created by this module."
  type        = map(string)
}

variable "hub_vnet_name" {
  description = "Name of the hub virtual network."
  type        = string
}

variable "hub_address_space" {
  description = "CIDR of the hub virtual network."
  type        = string
}

variable "firewall_subnet_prefix" {
  description = "CIDR for AzureFirewallSubnet. Must be /26 or larger."
  type        = string

  validation {
    condition     = tonumber(split("/", var.firewall_subnet_prefix)[1]) <= 26
    error_message = "AzureFirewallSubnet must be /26 or larger (a smaller prefix number)."
  }
}

variable "firewall_name" {
  description = "Name of the Azure Firewall instance."
  type        = string
}

variable "firewall_policy_name" {
  description = "Name of the Azure Firewall policy."
  type        = string
}

variable "firewall_public_ip_name" {
  description = "Name of the firewall public IP (this is the platform's single, known egress address)."
  type        = string
}

variable "firewall_sku_tier" {
  description = "Azure Firewall tier. 'Standard' is sufficient here; 'Premium' adds TLS inspection and IDPS if the risk appetite requires it."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Premium"], var.firewall_sku_tier)
    error_message = "firewall_sku_tier must be Standard or Premium."
  }
}

variable "enable_firewall" {
  description = "Deploy Azure Firewall. Set to false in throwaway subscriptions where the cost is not justified; the spoke then needs an alternative egress (NAT Gateway)."
  type        = bool
  default     = true
}

variable "spoke_address_spaces" {
  description = "Spoke CIDRs allowed to egress through the firewall. Used as the source in firewall rules."
  type        = list(string)
}

variable "allowed_egress_fqdns" {
  description = "Explicit allow-list of external FQDNs the workload may reach. Keep this list as short as the application permits."
  type        = list(string)
  default     = ["api.tvmaze.com", "www.tvmaze.com"]
}

variable "availability_zones" {
  description = "Zones for the firewall and its public IP. Empty list means non-zonal."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "enable_diagnostics" {
  description = "Send firewall logs to Log Analytics. Kept as a boolean rather than a null check so the count stays known at plan time."
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Workspace for firewall diagnostics. Required when enable_diagnostics is true."
  type        = string
  default     = ""
}
