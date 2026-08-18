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
# Observability components Variables
# -----------------------------------------------------------------------------

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 90
}

variable "log_daily_quota_gb" {
  description = "Daily ingestion cap in GB (-1 for unlimited)."
  type        = number
  default     = -1
}

variable "enable_monitor_private_link" {
  description = "Create an Azure Monitor Private Link Scope."
  type        = bool
  default     = true
}

variable "allow_public_log_query" {
  description = "Allow log queries from outside the VNet."
  type        = bool
  default     = false
}

variable "alert_email_receivers" {
  description = "Map of receiver name to email address for alerts."
  type        = map(string)
  default     = {}
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

# -----------------------------------------------------------------------------
# Storage Components Variables
# -----------------------------------------------------------------------------

variable "storage_account_count" {
  description = "sequentially-suffixed storage accounts to create"
  type        = number
  default     = 1
}

variable "storage_replication_type" {
  description = "Storage replication mode."
  type        = string
  default     = "LRS"
}

variable "cache_container_name" {
  description = "Blob container used for cached upstream responses."
  type        = string
  default     = "shows-cache"
}

variable "cache_expiry_days" {
  description = "Days before a cached blob is deleted by lifecycle management."
  type        = number
  default     = 7
}

variable "acr_untagged_retention_days" {
  description = "Days to keep untagged manifests in the registry."
  type        = number
  default     = 7
}

variable "enable_kv_purge_protection" {
  description = "Enable Key Vault purge protection. Irreversible once on."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# AKS Components Variables
# -----------------------------------------------------------------------------

variable "kubernetes_version" {
  description = "Pinned Kubernetes minor version."
  type        = string
  default     = "1.30"
}

variable "aks_sku_tier" {
  description = "AKS control-plane tier."
  type        = string
  default     = "Standard"
}

variable "pod_cidr" {
  description = "Overlay CIDR for pods."
  type        = string
  default     = "192.168.0.0/16"
}

variable "service_cidr" {
  description = "CIDR for Kubernetes services."
  type        = string
  default     = "172.16.0.0/16"
}

variable "dns_service_ip" {
  description = "CoreDNS service IP, inside service_cidr."
  type        = string
  default     = "172.16.0.10"
}

variable "system_node_vm_size" {
  description = "VM size for the system node pool."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "system_node_min_count" {
  description = "Minimum system nodes."
  type        = number
  default     = 2
}

variable "system_node_max_count" {
  description = "Maximum system nodes."
  type        = number
  default     = 4
}

variable "enable_user_node_pool" {
  description = "Create a dedicated application node pool."
  type        = bool
  default     = true
}

variable "user_node_vm_size" {
  description = "VM size for the application node pool."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "user_node_min_count" {
  description = "Minimum application nodes."
  type        = number
  default     = 2
}

variable "user_node_max_count" {
  description = "Maximum application nodes."
  type        = number
  default     = 6
}

variable "aks_admin_group_object_ids" {
  description = "Entra group object IDs with cluster-admin via Azure RBAC. Prefer PIM-eligible groups."
  type        = list(string)
  default     = []
}

variable "aks_reader_group_object_ids" {
  description = "Entra group object IDs with read-only cluster access."
  type        = list(string)
  default     = []
}

variable "kv_admin_group_object_ids" {
  description = "Entra group object IDs allowed to manage Key Vault secrets."
  type        = list(string)
  default     = []
}

variable "pipeline_principal_ids" {
  description = "Object ID(s) of the Azure DevOps service connection identity. Granted AcrPush and AKS RBAC Writer - deliberately not Owner or Contributor."
  type        = list(string)
  default     = []
}