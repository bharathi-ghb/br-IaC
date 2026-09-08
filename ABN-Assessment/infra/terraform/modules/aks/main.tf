# =============================================================================
# AKS Components + Private Endpoint + Private DNS Zone Link
# =============================================================================

resource "azurerm_user_assigned_identity" "aks_identity" {
  name                = var.control_plane_identity_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_role_assignment" "aks_role_assignment_subnet" {
  scope                = var.node_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_identity.principal_id
}

resource "azurerm_role_assignment" "aks_role_assignment_route_table" {
  count = var.enable_forced_tunnelling ? 1 : 0

  scope                = var.route_table_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_identity.principal_id
}

resource "azurerm_role_assignment" "aks_role_assignment_private_dns" {
  scope                = var.private_dns_zone_id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_identity.principal_id
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "aks_cluster" {
  name                       = var.name
  resource_group_name        = var.resource_group_name
  location                   = var.location
  dns_prefix_private_cluster = var.name
  node_resource_group        = var.node_resource_group_name
  tags                       = var.tags
  kubernetes_version         = var.kubernetes_version
  automatic_upgrade_channel  = var.automatic_upgrade_channel
  sku_tier                   = var.sku_tier

  private_cluster_enabled             = true
  private_dns_zone_id                 = var.private_dns_zone_id
  private_cluster_public_fqdn_enabled = false # do not publish a public FQDN at all
  oidc_issuer_enabled                 = true
  workload_identity_enabled           = true
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks_identity.id]
  }

  local_account_disabled   = true
  azure_active_directory_role_based_access_control {
    tenant_id              = var.tenant_id
    azure_rbac_enabled     = true
    admin_group_object_ids = var.admin_group_object_ids
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "calico"
    network_data_plane  = "azure"
    load_balancer_sku   = "standard"
    outbound_type       = "userDefinedRouting"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
  }

  default_node_pool {
    name                 = "system"
    vm_size              = var.system_node_vm_size
    vnet_subnet_id       = var.node_subnet_id
    zones                = var.availability_zones
    orchestrator_version = var.kubernetes_version
    auto_scaling_enabled = true
    min_count            = var.system_node_min_count
    max_count            = var.system_node_max_count
    os_disk_type         = "Ephemeral"
    os_disk_size_gb      = var.system_node_os_disk_gb
    max_pods             = var.max_pods_per_node
    only_critical_addons_enabled = var.taint_system_pool
    temporary_name_for_rotation  = "systemtmp"

    upgrade_settings {
      max_surge = "33%"
    }
  }

  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }
  azure_policy_enabled = true

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = var.maintenance_day
    start_time  = var.maintenance_start_time
    utc_offset  = "+00:00"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      default_node_pool[0].node_count,
    ]
  }

  depends_on = [
    azurerm_role_assignment.aks_role_assignment_subnet,
    azurerm_role_assignment.aks_role_assignment_route_table,
    azurerm_role_assignment.aks_role_assignment_private_dns,
  ]
}

resource "azurerm_kubernetes_cluster_node_pool" "aks_node_pool" {
  count = var.enable_user_node_pool ? 1 : 0

  name                  = "app"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks_cluster.id
  vm_size               = var.user_node_vm_size
  vnet_subnet_id        = var.node_subnet_id
  zones                 = var.availability_zones
  orchestrator_version  = var.kubernetes_version
  tags                  = var.tags
  auto_scaling_enabled  = true
  min_count             = var.user_node_min_count
  max_count             = var.user_node_max_count
  os_disk_type          = "Ephemeral"
  max_pods              = var.max_pods_per_node
  mode                  = "User"
  node_labels = {
    "workload" = "application"
  }

  lifecycle {
    ignore_changes = [node_count]
  }
}

resource "azurerm_role_assignment" "aks_cluster_readers" {
  count = length(var.reader_group_object_ids)

  scope                = azurerm_kubernetes_cluster.aks_cluster.id
  role_definition_name = "Azure Kubernetes Service RBAC Reader"
  principal_id         = var.reader_group_object_ids[count.index]
}

resource "azurerm_role_assignment" "aks_cluster_deployers" {
  count = length(var.deployer_principal_ids)

  scope                = azurerm_kubernetes_cluster.aks_cluster.id
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  principal_id         = var.deployer_principal_ids[count.index]
}

locals {
  cluster_user_principals = concat(var.deployer_principal_ids, var.reader_group_object_ids)
}

resource "azurerm_role_assignment" "cluster_user" {
  count = length(local.cluster_user_principals)

  scope                = azurerm_kubernetes_cluster.aks_cluster.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = local.cluster_user_principals[count.index]
}

resource "azurerm_monitor_diagnostic_setting" "aks" {
  count = var.enable_diagnostics ? 1 : 0
  
  name                       = "aks-diagnostics-to-law"
  target_resource_id         = azurerm_kubernetes_cluster.aks_cluster.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { 
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
