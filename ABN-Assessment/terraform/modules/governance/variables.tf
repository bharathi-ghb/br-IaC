variable "subscription_id" {
  description = "Subscription the policies are assigned to. Leave null to use the subscription the provider is authenticated against."
  type        = string
  default     = ""
}

variable "not_scopes" {
  description = "Scope IDs (resource groups, resources) exempted from every assignment in this module. Use for legacy or sandbox resource groups that cannot yet meet these controls."
  type        = list(string)
  default     = []
}

variable "allowed_locations" {
  description = "Regions resources may be deployed into. 'global' is normally required for resources such as DNS zones."
  type        = list(string)
  default     = ["westeurope", "northeurope"]
}

variable "required_tags" {
  description = "Tag names every resource must carry."
  type        = list(string)
  default     = ["environment", "owner", "application", "cost_centre"]
}

variable "kubernetes_policy_effect" {
  description = "Effect for in-cluster Gatekeeper policies. Start with 'Audit' on an existing cluster and promote to 'Deny' once findings are clean."
  type        = string
  default     = ""

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

variable "keyvault_rbac_effect" {
  description = "Effect for the Key Vault RBAC permission model policy. Keep 'Audit' while the vault still uses access policies; move to 'Deny' once it is migrated to RBAC."
  type        = string
  default     = "Audit"

  validation {
    condition     = contains(["Audit", "Deny", "Disabled"], var.keyvault_rbac_effect)
    error_message = "keyvault_rbac_effect must be Audit, Deny or Disabled."
  }
}
