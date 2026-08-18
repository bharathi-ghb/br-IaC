variable "name" {
  description = "Key Vault name. Globally unique, 3-24 characters."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the vault."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant that owns the vault."
  type        = string
}

variable "tags" {
  description = "Tags applied."
  type        = map(string)
}

variable "sku_name" {
  description = "Vault SKU."
  type        = string
  default     = "standard"
}

variable "soft_delete_retention_days" {
  description = "Soft-delete retention window in days."
  type        = number
  default     = 90
}

variable "private_endpoint_subnet_id" {
  description = "Subnet that hosts the vault private endpoint."
  type        = string
}

variable "private_dns_zone_id" {
  description = "Resource ID of the privatelink.vaultcore.azure.net zone."
  type        = string
}

variable "secrets_user_principal_ids" {
  description = "Object IDs granted read access to secret values."
  type        = list(string)
  default     = []
}

variable "secrets_officer_principal_ids" {
  description = "Object IDs granted manage access to secrets. Prefer Entra groups over individuals."
  type        = list(string)
  default     = []
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
