variable "resource_group_name" {
  description = "Resource group the policies are assigned to."
  type        = string
}

variable "allowed_locations" {
  description = "Regions resources may be deployed into. 'global' is normally required for resources such as DNS zones."
  type        = list(string)
}

variable "required_tags" {
  description = "Tag names every resource must carry."
  type        = list(string)
  default     = ["environment", "owner", "cost_centre"]
}

variable "kubernetes_policy_effect" {
  description = "Effect for in-cluster Gatekeeper policies. Start with 'Audit' on an existing cluster and promote to 'Deny' once findings are clean."
  type        = string
  default     = "Audit"

  validation {
    condition     = contains(["Audit", "Deny", "Disabled"], var.kubernetes_policy_effect)
    error_message = "kubernetes_policy_effect must be Audit, Deny or Disabled."
  }
}

variable "enforce" {
  description = "Whether assignments enforce their effect. Set false to run a policy in 'what would this block' mode before turning it on."
  type        = bool
  default     = true
}
