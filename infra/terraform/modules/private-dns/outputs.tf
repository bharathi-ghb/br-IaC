output "zone_ids" {
  description = "Map of zone name to resource ID."
  value       = { for name, zone in azurerm_private_dns_zone.dns : name => zone.id }
}

output "zone_names" {
  description = "Map of zone name to zone name."
  value       = { for name, zone in azurerm_private_dns_zone.dns : name => zone.name }
}
