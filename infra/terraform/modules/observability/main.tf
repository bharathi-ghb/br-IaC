# =============================================================================
# Observability Components — Log Analytics Workspace + Application Insights + Azure Monitor Private Link Scope
# =============================================================================

# ONE WORKSPACE FOR EVERYTHING. This is the single most important observability design
# decision in the platform.
#
# Application traces, container stdout, the Kubernetes audit log, Storage data-plane
# logs, firewall flows and the Activity Log all land here, which is what makes
# cross-layer correlation possible in a single KQL query. During an incident you can
# take one failing request, follow its operation_Id into AppDependencies to see a Blob
# 403, then join to StorageBlobLogs at the same timestamp to see exactly which principal
# ID was denied and why. Split across workspaces, that is four investigations and a
# spreadsheet.
#
# Counter-argument, worth acknowledging: one workspace means one RBAC boundary and one
# cost centre. At estate scale you use a shared platform workspace with RESOURCE-CONTEXT
# RBAC so teams see only their own resources' logs.
#
# local_authentication_enabled = false forces Entra-authenticated ingestion. Without it,
# anyone holding the workspace key can inject arbitrary telemetry - poisoning the exact
# data you would rely on during an incident.
#
# KNOWN DEFECT (docs/02 P1-1): internet_ingestion_enabled = var.enable_private_link is
# INVERTED. With enable_private_link = true it sets internet ingestion to TRUE - so we
# build the AMPLS, create its private endpoint, set the scope to PrivateOnly, and then
# leave the workspace itself accepting public ingestion. Should be
# !var.enable_private_link.
#
# KNOWN GAP (docs/02 P2-9): retention is 90 days in BOTH environments. Banking/DORA
# retention for production is typically 365+ days, with immutable archive beyond that.
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

  lifecycle {
    prevent_destroy = true
  }
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

# AMPLS - Azure Monitor Private Link Scope. The assessment names this explicitly:
# 'if private-only monitoring is implemented, use AMPLS'.
#
# Without it, the OMS agent and the App Insights SDK send telemetry to PUBLIC Azure
# Monitor endpoints - an egress path out of the private network carrying potentially
# sensitive log content.
#
# THE DELIBERATE COMPROMISE:
#   ingestion_access_mode = "PrivateOnly"  - telemetry never leaves the VNet going in
#   query_access_mode     = Open when allow_public_query - engineers can still
#     investigate from a laptop, over Conditional-Access-protected Entra auth
# Requiring engineers to be on the corporate network to read logs during an incident is
# a real availability cost with limited security benefit. Making it a VARIABLE means the
# risk owner decides rather than the engineer.
#
# NOTE THE DIFFERENCE between these two controls, because it is a good interview
# distinction: internet_ingestion_enabled is a RESOURCE-level switch on the workspace;
# ingestion_access_mode = PrivateOnly is a SCOPE-level switch meaning 'resources in this
# scope may only be reached over the private link'. You want both.
#
# THE AMPLS TRAP: PrivateOnly is GLOBAL in effect. Once a VNet resolves Azure Monitor
# through an AMPLS private endpoint, ALL Azure Monitor resources it reaches are subject
# to that scope's access mode - so one AMPLS in PrivateOnly can silently cut off another
# team's workspace sharing the same private DNS zones. This is the most common AMPLS
# incident. Limits: 300 resources per AMPLS, 10 AMPLS per resource, 10 PEs per AMPLS.
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

# THE ONLY ALERT RULE DEFINED IN CODE - and that is a gap, not a design.
#
# The minimum production set (see docs/07) is roughly ten paging alerts: availability,
# zero-Ready-replicas, p95 latency, 5xx rate, pod restarts, OOMKilled, ImagePullBackOff,
# ANY Blob 403, Entra auth failures, and node pressure - plus security alerts on
# publicNetworkAccess changes and role assignment creation.
#
# Two specific points worth making about alert design:
#
#  1. Blob 403 should alert on ANY occurrence, not a rate. In a correctly functioning
#     system the count is exactly zero - the app either holds the role assignment or it
#     does not. A rate threshold would hide precisely the failure this platform is most
#     likely to have.
#
#  2. This rule uses a static threshold. The better model is SLO-based multi-window,
#     multi-burn-rate alerting: 14.4x error-budget burn over an hour pages, 1x over
#     three days raises a ticket. Static thresholds produce both failure modes - paging
#     on a blip nobody noticed, and silence while a 2% error rate eats the whole monthly
#     budget over a week.
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
