variable "resource_group_name" {
  description = "Resource group that holds the Private DNS zones."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to be applied."
  type        = map(string)
  default     = {}
}

variable "zone_names" {
  description = "Private DNS zone names to create, for example 'privatelink.blob.core.windows.net'."
  type        = list(string)
}

variable "linked_virtual_networks" {
  description = "Map of friendly key to VNet resource ID. Every zone is linked to every VNet in this map."
  type        = map(string)
  default     = {}
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
