# =============================================================================
# Private DNS zone and VNet link resources
# =============================================================================

resource "azurerm_private_dns_zone" "dns" {
  for_each = toset(var.private_dns_zones)
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "private_dns_link" {
  for_each = merge([
    for zone in var.private_dns_zones : {
      for vnet_key, vnet_id in var.linked_virtual_networks :
      "${vnet_key}--${replace(zone, ".", "-")}" => {
        zone_name = zone
        vnet_key  = vnet_key
        vnet_id   = vnet_id
      }
    }
  ])

  name                  = "link-${each.value.vnet_key}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.dns[each.value.zone_name].name
  virtual_network_id    = each.value.vnet_id
  registration_enabled = false
  tags                 = var.tags
}
