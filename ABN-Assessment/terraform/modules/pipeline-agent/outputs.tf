output "vm_id" {
  description = "Resource ID of the agent VM."
  value       = azurerm_linux_virtual_machine.agent.id
}

output "vm_name" {
  description = "Name of the agent VM."
  value       = azurerm_linux_virtual_machine.agent.name
}

output "private_ip_address" {
  description = "Private IP address of the agent VM, inside snet-pipeline-agents."
  value       = azurerm_network_interface.agent.private_ip_address
}

output "identity_principal_id" {
  description = "Principal ID of the agent VM's managed identity."
  value       = azurerm_user_assigned_identity.agent.principal_id
}

output "identity_client_id" {
  description = "Client ID of the agent VM's managed identity."
  value       = azurerm_user_assigned_identity.agent.client_id
}
