variable "name" {
  description = "Cluster name."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the cluster resource."
  type        = string
}

variable "node_resource_group_name" {
  description = "Resource group AKS creates for node infrastructure."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource created by this module."
  type        = map(string)
}

variable "tenant_id" {
  description = "Entra ID tenant used for cluster authentication."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version."
  type        = string
  default     = "1.30"
}

variable "automatic_upgrade_channel" {
  description = "AKS auto-upgrade channel: patch, stable, rapid, node-image or none."
  type        = string
  default     = "patch"
}

variable "sku_tier" {
  description = "Control-plane tier. 'Standard' carries the API server SLA and is the minimum for production; 'Free' is acceptable in non-prod."
  type        = string
  default     = "Standard"
}

variable "control_plane_identity_name" {
  description = "Name of the user-assigned identity used by the cluster control plane."
  type        = string
}

# --- Networking --------------------------------------------------------------
variable "node_subnet_id" {
  description = "Subnet the nodes are placed in."
  type        = string
}

variable "enable_forced_tunnelling" {
  description = "Whether the node subnet is attached to a route table that must be granted to the control-plane identity."
  type        = bool
  default     = true
}

variable "route_table_id" {
  description = "Route table forcing egress via the firewall."
  type        = string
  default     = ""
}

variable "private_dns_zone_id" {
  description = "Private DNS zone (privatelink.<region>.azmk8s.io) for the API server record."
  type        = string
}

variable "pod_cidr" {
  description = "Overlay CIDR for pods. Not routable in the VNet."
  type        = string
  default     = "192.168.0.0/16"
}

variable "service_cidr" {
  description = "CIDR for Kubernetes ClusterIP services."
  type        = string
  default     = "172.16.0.0/16"
}

variable "dns_service_ip" {
  description = "CoreDNS service address. Must sit inside service_cidr."
  type        = string
  default     = "172.16.0.10"
}

# --- Node pools --------------------------------------------------------------
variable "availability_zones" {
  description = "Zones for node pools."
  type        = list(string)
  default     = ["1", "2", "3"]
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

variable "system_node_os_disk_gb" {
  description = "OS disk size. Must be large enough for the ephemeral disk cache of the chosen VM size."
  type        = number
  default     = 64
}

variable "enable_user_node_pool" {
  description = "Create a separate user node pool for application workloads."
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

variable "max_pods_per_node" {
  description = "Maximum pods per node."
  type        = number
  default     = 50
}

# --- Access ------------------------------------------------------------------
variable "admin_group_object_ids" {
  description = "Entra group object IDs granted cluster-admin through Azure RBAC."
  type        = list(string)
  default     = []
}

variable "reader_group_object_ids" {
  description = "Entra group object IDs granted read-only access to cluster objects."
  type        = list(string)
  default     = []
}

variable "deployer_principal_ids" {
  description = "Principal IDs (pipeline service connection) granted namespace write access for Helm deployments."
  type        = list(string)
  default     = []
}

# --- Operations --------------------------------------------------------------
variable "log_analytics_workspace_id" {
  description = "Workspace for Container Insights and control-plane diagnostics."
  type        = string
}

variable "maintenance_day" {
  description = "Day of week for the node OS maintenance window."
  type        = string
  default     = "Sunday"
}

variable "maintenance_start_time" {
  description = "Start of the maintenance window in HH:mm, UTC."
  type        = string
  default     = "02:00"
}
