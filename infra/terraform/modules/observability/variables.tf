variable "resource_group_name" {
  description = "Resource group for monitoring resources."
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

variable "log_analytics_name" {
  description = "Name of the Log Analytics workspace."
  type        = string
}

variable "app_insights_name" {
  description = "Name of the Application Insights component."
  type        = string
}

variable "ampls_name" {
  description = "Name of the Azure Monitor Private Link Scope."
  type        = string
}

variable "retention_in_days" {
  description = "Log retention."
  type        = number
  default     = 90
}

variable "daily_quota_gb" {
  description = "Daily ingestion cap in GB. -1 means unlimited."
  type        = number
  default     = -1
}

variable "sampling_percentage" {
  description = "Application Insights sampling. 100 keeps every trace."
  type        = number
  default     = 100
}

variable "enable_local_auth" {
  description = "Require Entra ID authentication."
  type        = bool
  default     = false
}

variable "enable_private_link" {
  description = "Create an Azure Monitor Private Link Scope and private endpoint."
  type        = bool
  default     = false
}

variable "allow_public_query" {
  description = "Allow queries (portal, workbooks) from outside the VNet while keeping ingestion private."
  type        = bool
  default     = false
}

variable "private_endpoint_subnet_id" {
  description = "Subnet that hosts the AMPLS private endpoint. Required when enable_private_link is true."
  type        = string
  default     = null
}

variable "monitor_private_dns_zone_ids" {
  description = "Resource IDs of all five Azure Monitor privatelink zones."
  type        = list(string)
  default     = []
}

variable "alert_email_receivers" {
  description = "Map of receiver name to email address for the platform action group."
  type        = map(string)
  default     = {}
}

variable "failed_request_threshold" {
  description = "Failed request count over the evaluation window that triggers a severity 1 alert."
  type        = number
  default     = 10
}
