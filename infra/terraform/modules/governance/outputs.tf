output "assignment_ids" {
  description = "IDs of the policy assignments created, useful for compliance reporting and exemption scoping."
  value = concat(
    [
      azurerm_resource_group_policy_assignment.allowed_locations.id,
      azurerm_resource_group_policy_assignment.storage_deny_public.id,
      azurerm_resource_group_policy_assignment.acr_deny_public.id,
      azurerm_resource_group_policy_assignment.aks_private_cluster.id,
      azurerm_resource_group_policy_assignment.aks_no_privileged.id,
      azurerm_resource_group_policy_assignment.aks_no_privilege_escalation.id,
    ],
    azurerm_resource_group_policy_assignment.required_tags[*].id
  )
}
