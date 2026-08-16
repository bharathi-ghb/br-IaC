output "spoke_vnet_id" {
  description = "Resource ID of the spoke virtual network."
  value       = azurerm_virtual_network.spoke_vnet.id
}

output "spoke_vnet_name" {
  description = "Name of the spoke virtual network."
  value       = azurerm_virtual_network.spoke_vnet.name
}

output "aks_subnet_id" {
  description = "Resource ID of the AKS node subnet."
  value       = azurerm_subnet.aks_nodes.id
}

output "private_endpoint_subnet_id" {
  description = "Resource ID of the private endpoint subnet."
  value       = azurerm_subnet.private_endpoints.id
}

output "pipeline_agent_subnet_id" {
  description = "Resource ID of the pipeline agent subnet, or null when not created."
  value       = var.pipeline_agent_subnet_prefix == "" ? null : azurerm_subnet.pipeline_agents.id
}

output "route_table_id" {
  description = "Resource ID of the AKS route table, or null when forced tunnelling is disabled. The AKS control-plane identity needs Network Contributor on this resource."
  value       = var.enable_forced_tunnelling ? azurerm_route_table.aks_nodes.id : null
}
