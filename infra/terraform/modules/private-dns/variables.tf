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

variable "private_dns_zones" {
  description = "Private DNS zone names to create"
  type        = list(string)
  default     = []
}

variable "linked_virtual_networks" {
  description = "Map of friendly key to VNet resource ID. Every zone is linked to every VNet in this map."
  type        = map(string)
  default     = {}
}
