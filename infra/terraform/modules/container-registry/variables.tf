variable "name" {
  description = "Registry name. Globally unique, alphanumeric only"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the registry."
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
  description = "Tags applied."
  type        = map(string)
}

variable "private_endpoint_subnet_id" {
  description = "Subnet that hosts registry private endpoint."
  type        = string
}

variable "private_dns_zone_id" {
  description = "Resource ID of privatelink.azurecr.io zone."
  type        = string
}

variable "pull_principal_ids" {
  description = "Object IDs granted AcrPull."
  type        = list(string)
  default     = []
}

variable "push_principal_ids" {
  description = "Object IDs granted AcrPush."
  type        = list(string)
  default     = []
}

variable "untagged_retention_days" {
  description = "Days to keep untagged manifests before automatic cleanup."
  type        = number
  default     = 7
}

variable "enable_content_trust" {
  description = "Enable Docker content trust (image signing) on the registry."
  type        = bool
  default     = false
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
