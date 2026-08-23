# =============================================================================
# Private DNS zone and VNet link resources
# =============================================================================

# PRIVATE DNS ZONES. The zone NAMES are fixed by Azure and must be exact:
#   privatelink.blob.core.windows.net       - Blob Storage
#   privatelink.vaultcore.azure.net         - Key Vault
#   privatelink.azurecr.io                  - ACR (covers BOTH the registry endpoint
#                                             and the <region>.data endpoint)
#   privatelink.<region>.azmk8s.io          - the AKS private API server
#   privatelink.monitor.azure.com,
#   privatelink.oms.opinsights.azure.com,
#   privatelink.ods.opinsights.azure.com,
#   privatelink.agentsvc.azure-automation.net - the five AMPLS zones (the fifth being
#                                             the blob zone above, shared with Storage -
#                                             an unexpected coupling worth knowing about)
#
# HOW THIS ACTUALLY WORKS (the bit people get wrong): the application NEVER asks for
# the 'privatelink' name. It asks for the normal public name, and Azure's PUBLIC DNS
# returns a CNAME to <name>.privatelink.<suffix>. Only then does the linked private
# zone resolve that CNAME target to the private IP. That indirection is why TLS still
# validates - the certificate is issued for the public name.
#
# KNOWN DEFECT (docs/02 P3): 'privatelink.westeurope.azmk8s.io' is HARDCODED in the
# environment tfvars. Deploying to another region would silently fail to find the map
# key. Derive it: "privatelink.${var.location}.azmk8s.io".
resource "azurerm_private_dns_zone" "dns" {
  for_each = toset(var.private_dns_zones)
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# THE LINK IS THE WHOLE MECHANISM. A private DNS zone that is not linked to a VNet is
# invisible from that VNet - resolution falls through to public DNS and returns the
# PUBLIC IP, which then refuses the connection because public access is disabled.
# That is Troubleshooting Scenario 2, and it is the most common Private Link failure.
#
# The nested for/merge builds the full cross-product of zones x VNets, so adding a zone
# or a VNet automatically links everything - it is structurally impossible to forget one.
#
# registration_enabled = false deliberately: auto-registration would add an A record for
# every VM NIC in the linked VNet into this zone, which in a privatelink.* zone is pure
# pollution and a potential conflict. Note also that a VNet may have only ONE
# auto-registration link across all zones.
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

# KNOWN DEFECT (docs/02 P1-3): this block is broken twice over.
#
#  1. for_each = toset(["dns"]) then indexes azurerm_private_dns_zone.dns[each.value] -
#     i.e. it looks up a zone literally named "dns", which does not exist. It should be
#     for_each = var.enable_diagnostics ? toset(var.private_dns_zones) : toset([]).
#
#  2. Private DNS zones DO NOT EMIT RESOURCE LOGS, so category_group = "allLogs" would
#     fail regardless.
#
# WHERE DNS TELEMETRY ACTUALLY COMES FROM: the Azure Firewall DNS proxy logs (which are
# enabled - dns { proxy_enabled = true } in network-hub), or Azure DNS Private Resolver
# query logs. Knowing where DNS visibility genuinely originates is worth more than this
# block was ever going to deliver.
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
