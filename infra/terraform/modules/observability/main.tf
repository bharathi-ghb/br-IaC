# =============================================================================
# Observability Components — Log Analytics Workspace + Application Insights + Azure Monitor Private Link Scope
# =============================================================================

resource "azurerm_log_analytics_workspace" "law" {
  name                         = var.log_analytics_name
  resource_group_name          = var.resource_group_name
  location                     = var.location
  tags                         = var.tags
  sku                          = "PerGB2018"
  retention_in_days            = var.retention_in_days
  local_authentication_enabled = var.enable_local_auth
  internet_ingestion_enabled   = var.enable_private_link
  internet_query_enabled       = var.allow_public_query
  daily_quota_gb               = var.daily_quota_gb
}

resource "azurerm_application_insights" "appi" {
  name                         = var.app_insights_name
  resource_group_name          = var.resource_group_name
  location                     = var.location
  workspace_id                 = azurerm_log_analytics_workspace.law.id
  application_type             = "web"
  tags                         = var.tags
  local_authentication_enabled = var.enable_local_auth
  internet_ingestion_enabled   = var.enable_private_link
  internet_query_enabled       = var.allow_public_query
  sampling_percentage          = var.sampling_percentage
}

resource "azurerm_monitor_private_link_scope" "ampls" {
  count = var.enable_private_link ? 1 : 0

  name                = var.ampls_name
  resource_group_name = var.resource_group_name
  tags                = var.tags
  ingestion_access_mode = "PrivateOnly"
  query_access_mode     = var.allow_public_query ? "Open" : "PrivateOnly"
}

resource "azurerm_monitor_private_link_scoped_service" "law" {
  count = var.enable_private_link ? 1 : 0

  name                = "law-scoped"
  resource_group_name = var.resource_group_name
  scope_name          = azurerm_monitor_private_link_scope.ampls[0].name
  linked_resource_id  = azurerm_log_analytics_workspace.law.id
}

resource "azurerm_monitor_private_link_scoped_service" "appi" {
  count = var.enable_private_link ? 1 : 0

  name                = "appi-scoped"
  resource_group_name = var.resource_group_name
  scope_name          = azurerm_monitor_private_link_scope.ampls[0].name
  linked_resource_id  = azurerm_application_insights.appi.id
}

resource "azurerm_private_endpoint" "ampls" {
  count = var.enable_private_link ? 1 : 0

  name                = "pe-${var.ampls_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.ampls_name}"
    private_connection_resource_id = azurerm_monitor_private_link_scope.ampls[0].id
    subresource_names              = ["azuremonitor"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-${var.ampls_name}"
    private_dns_zone_ids = var.monitor_private_dns_zone_ids
  }
}

# ---------------------------------------------------------------------------
# Alerting
# ---------------------------------------------------------------------------
resource "azurerm_monitor_action_group" "infra" {
  count = length(var.alert_email_receivers) > 0 ? 1 : 0

  name                = "ag-${var.log_analytics_name}"
  resource_group_name = var.resource_group_name
  short_name          = substr(replace(var.log_analytics_name, "-", ""), 0, 12)
  tags                = var.tags

  dynamic "email_receiver" {
    for_each = var.alert_email_receivers
    content {
      name                    = email_receiver.key
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

resource "azurerm_monitor_metric_alert" "failed_requests" {
  count = length(var.alert_email_receivers) > 0 ? 1 : 0

  name                = "${var.app_insights_name}-failed-requests"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_application_insights.appi.id]
  description         = "API failed request rate above threshold"
  severity            = 1
  frequency           = "PT2M"
  window_size         = "PT10M"
  tags                = var.tags

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "requests/failed"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = var.failed_request_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.infra[0].id
  }
}
