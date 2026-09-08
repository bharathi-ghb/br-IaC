output "client_id" {
  description = "Client ID of the managed identity."
  value       = azurerm_user_assigned_identity.identity.client_id
}

output "principal_id" {
  description = "Object (principal) ID of the managed identity, used as the target of RBAC role assignments."
  value       = azurerm_user_assigned_identity.identity.principal_id
}

output "id" {
  description = "Resource ID of the managed identity."
  value       = azurerm_user_assigned_identity.identity.id
}
