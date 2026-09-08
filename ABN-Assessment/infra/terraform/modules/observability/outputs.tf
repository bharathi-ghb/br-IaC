output "log_analytics_workspace_id" {
  description = "Resource ID of the workspace."
  value       = azurerm_log_analytics_workspace.law.id
}

output "log_analytics_workspace_guid" {
  description = "Workspace GUID (customer ID), used by agents."
  value       = azurerm_log_analytics_workspace.law.workspace_id
}

output "app_insights_connection_string" {
  description = "Application Insights connection string."
  value       = azurerm_application_insights.appi.connection_string
  sensitive   = true
}

output "app_insights_id" {
  description = "Resource ID of the Application Insights."
  value       = azurerm_application_insights.appi.id
}

output "ampls_id" {
  description = "Resource ID of the Azure Monitor Private Link Scope."
  value       = var.enable_private_link ? azurerm_monitor_private_link_scope.ampls[0].id : null
}
