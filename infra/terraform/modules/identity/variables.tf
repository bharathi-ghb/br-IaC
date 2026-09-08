variable "identity_name" {
  description = "Name of the user-assigned managed identity used by the workload."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the identity."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tags" {
  description = "Tags applied to the identity."
  type        = map(string)
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL from the AKS cluster."
  type        = string
}

variable "service_accounts" {
  description = <<-DESC
    Kubernetes ServiceAccounts allowed to federate to this identity, keyed by a
    friendly name. The namespace and service_account_name must match the Helm
    release exactly - Entra ID does an exact string comparison on the subject.
  DESC
  type = map(object({
    namespace            = string
    service_account_name = string
  }))
}
