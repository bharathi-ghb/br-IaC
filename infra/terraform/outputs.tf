
# OUTPUTS - the contract between Terraform and the deployment pipeline.
#
# stage-terraform.yml reads these into an outputs.env artifact, and stage-deploy.yml
# sources it and passes the values to helm with --set. That is what makes the Helm
# chart environment-agnostic: nothing infrastructure-derived is hardcoded in a values
# file. It is also the correct fix for the namespace/ServiceAccount mismatch
# (docs/02 P0-6) - the pipeline already reads app_namespace and
# app_service_account_name from here, so Terraform is the single source of truth and
# the chart defaults are simply wrong.
#
# app_insights_connection_string is marked sensitive so it is redacted from logs.
# Note though (docs/02 P2-3): with local_authentication_enabled = false on App
# Insights, the ingestion key inside that string is INERT - so it is arguably not a
# secret at all, and the Kubernetes Secret the pipeline builds from it is unnecessary.

output "firewall_public_ip" {
  description = "The platform's single egress IP address."
  value       = module.network_hub.firewall_public_ip
}

output "aks_cluster_name" {
  description = "Name of the AKS cluster."
  value       = module.aks.name
}

output "resource_group_name" {
  description = "Name of the primary infrastructure resource group."
  value       = azurerm_resource_group.rg_infra.name
}

output "acr_name" {
  description = "Name of the container registry."
  value       = module.acr.name
}

output "acr_login_server" {
  description = "Login server FQDN of the container registry."
  value       = module.acr.login_server
}

output "workload_identity_client_id" {
  description = "Client ID of the workload identity federated to the application ServiceAccount."
  value       = module.identity.client_id
}

output "storage_account_name" {
  description = "Name of the primary storage account."
  value       = values(module.storage)[0].name
}

output "cache_container_name" {
  description = "Name of the blob container used for cached upstream responses."
  value       = values(module.storage)[0].cache_container_name
}

output "app_namespace" {
  description = "Kubernetes namespace the application is deployed into."
  value       = var.app_namespace
}

output "app_service_account_name" {
  description = "ServiceAccount name federated to the workload identity."
  value       = var.app_service_account_name
}

output "pipeline_agent_vm_name" {
  description = "Name of the self-hosted pipeline agent VM, or null when not created."
  value       = var.enable_pipeline_agent_vm ? module.pipeline_agent[0].vm_name : null
}

output "pipeline_agent_private_ip" {
  description = "Private IP of the self-hosted pipeline agent VM, or null when not created."
  value       = var.enable_pipeline_agent_vm ? module.pipeline_agent[0].private_ip_address : null
}

output "app_insights_connection_string" {
  description = "Application Insights connection string."
  value       = module.observability.app_insights_connection_string
  sensitive   = true
}
