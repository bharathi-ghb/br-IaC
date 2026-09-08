output "hub_vnet_id" {
  description = "ID of the hub VNet."
  value       = azurerm_virtual_network.hub_vnet.id
}

output "hub_vnet_name" {
  description = "Name of the hub VNet."
  value       = azurerm_virtual_network.hub_vnet.name
}

output "firewall_private_ip" {
  description = "Private IP of the firewall."
  value       = var.enable_firewall ? azurerm_firewall.fw[0].ip_configuration[0].private_ip_address : null
}

output "firewall_public_ip" {
  description = "Public IP of the firewall. The platform's single egress IP address."
  value       = var.enable_firewall ? azurerm_public_ip.firewall[0].ip_address : null
}
