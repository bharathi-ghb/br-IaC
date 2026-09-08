output "assignment_ids" {
  description = "IDs of the policy assignments created, useful for compliance reporting and exemption scoping."
  value = concat(
    [
      azurerm_subscription_policy_assignment.allowed_locations.id,
      azurerm_subscription_policy_assignment.storage_deny_public.id,
      azurerm_subscription_policy_assignment.acr_deny_public.id,
      azurerm_subscription_policy_assignment.kv_deny_public.id,
    ],
    values(azurerm_subscription_policy_assignment.required_tags)[*].id
  )
}
