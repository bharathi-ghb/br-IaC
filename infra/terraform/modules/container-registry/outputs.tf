output "id" {
  description = "Resource ID of the container registry."
  value       = azurerm_container_registry.acr.id
}

output "name" {
  description = "Registry name."
  value       = azurerm_container_registry.acr.name
}

output "login_server" {
  description = "Registry login server FQDN"
  value       = azurerm_container_registry.acr.login_server
}
