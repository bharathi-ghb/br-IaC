output "hub_vnet_id" {
  description = "ID of the hub VNet."
  value       = module.network_hub.id
}

output "firewall_private_ip" {
  description = "Private IP of the firewall."
  value       = var.enable_firewall ? azurerm_firewall.fw[0].ip_configuration[0].private_ip_address : null
}
