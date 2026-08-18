variable "name" {
  description = "Storage account name. Globally unique, lowercase alphanumeric characters."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the storage account."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tags" {
  description = "Tags applied."
  type        = map(string)
}

variable "replication_type" {
  description = "Replication mode."
  type        = string
  default     = "LRS"
}

variable "cache_container_name" {
  description = "Blob container used for cache."
  type        = string
  default     = "display-cache"
}

variable "cache_expiry_days" {
  description = "Delete cached blobs after last modification."
  type        = number
  default     = 7
}

variable "blob_retention_days" {
  description = "Soft-delete retention window for blobs and containers."
  type        = number
  default     = 7
}

variable "enable_infrastructure_encryption" {
  description = "Enable double encryption at rest. Cannot be changed after creation. Otherwise creates a new storage account."
  type        = bool
  default     = true
}

variable "private_endpoint_subnet_id" {
  description = "Subnet that hosts the blob private endpoint."
  type        = string
}

variable "blob_private_dns_zone_id" {
  description = "Resource ID of the blob dns zone."
  type        = string
}

variable "blob_private_dns_zone_name" {
  description = "Name of the blob dns zone."
  type        = string
}

variable "data_contributor_principal_ids" {
  description = "Object IDs granted the roles in role_definition_names."
  type        = list(string)
  default     = []
}

variable "role_definition_names" {
  description = "Built-in roles assigned to each principal in data_contributor_principal_ids."
  type        = list(string)
  default     = []
}

variable "enable_diagnostics" {
  description = "Send resource logs to Log Analytics."
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Workspace for diagnostics. Required when enable_diagnostics is true."
  type        = string
  default     = ""
}
