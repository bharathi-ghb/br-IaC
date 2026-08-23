# =============================================================================
# Private DNS zone and VNet link resources
# =============================================================================

resource "azurerm_private_dns_zone" "dns" {
  for_each = toset(var.zone_names)
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "private_dns_link" {
  for_each = merge([
    for zone in var.zone_names : {
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

resource "azurerm_monitor_diagnostic_setting" "dns" {
  for_each = var.enable_diagnostics ? toset(["dns"]) : toset([])

  name                       = "dns-diagnostics-to-law"
  target_resource_id         = "${azurerm_private_dns_zone.dns[each.value].id}"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category_group = "allLogs" }

  enabled_metric {
    category = "AllMetrics"
  }
}
