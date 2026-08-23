# =============================================================================
# AKS Components + Private Endpoint + Private DNS Zone Link
# =============================================================================

# CONTROL-PLANE IDENTITY. Note this is NOT the identity that pulls images - that is the
# kubelet identity, which AKS creates separately and which gets AcrPull in the ACR
# module. Confusing the two is one of the most common AKS mistakes: everything
# provisions cleanly and then no image ever pulls.
#
# User-assigned rather than system-assigned because the three role assignments below
# must exist BEFORE the cluster is created (userDefinedRouting and a customer-managed
# private DNS zone are both creation-time dependencies). A system-assigned identity does
# not exist until the cluster does, which is a chicken-and-egg problem.
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

# Required because outbound_type = userDefinedRouting: AKS must be able to read and
# manage routes on the node subnet's route table. Missing this is a very common cause
# of 'cluster creation failed' with an opaque error.
resource "azurerm_role_assignment" "aks_role_assignment_route_table" {
  count = var.enable_forced_tunnelling ? 1 : 0

  scope                = var.route_table_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_identity.principal_id
}

# Required because we supply a CUSTOMER-managed private DNS zone rather than letting
# AKS create a system one. AKS registers the API server's A record into this zone at
# creation time, so it needs Private DNS Zone Contributor on it first.
#
# WHY customer-managed: a system-managed zone lives inside the AKS node resource group
# and cannot be linked to other VNets. This design needs the pipeline agent in the
# spoke - and potentially a hub jumpbox - to resolve the private API server, which
# requires a zone we control and can link where we choose.
resource "azurerm_role_assignment" "aks_role_assignment_private_dns" {
  scope                = var.private_dns_zone_id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_identity.principal_id
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
# THE CLUSTER. Every security-relevant setting below is deliberate - here is why each
# one is there.
#
# PRIVATE ACCESS
#   private_cluster_enabled = true          - the API server has no public endpoint
#   private_cluster_public_fqdn_enabled = false - AKS otherwise ALSO publishes a public
#       FQDN for a private cluster (resolvable anywhere, though only reachable
#       privately). Disabling it removes the resolvable name entirely - defence in
#       depth against reconnaissance.
#   private_dns_zone_id                     - customer-managed, so it can be linked to
#       the spoke and hub VNets (see the role assignment above).
#
# IDENTITY
#   oidc_issuer_enabled = true       - publishes an OIDC discovery document and JWKS so
#       Entra can verify tokens the cluster signs. This is what makes the cluster an
#       identity provider.
#   workload_identity_enabled = true - installs the azure-wi-webhook mutating admission
#       webhook that injects AZURE_* env vars and the projected token volume.
#   local_account_disabled = true    - THE HIGHEST-VALUE SINGLE SETTING HERE. Without
#       it, AKS keeps a clusterAdmin account authenticated by a client CERTIFICATE.
#       Anyone with the Azure Cluster Admin role can fetch that kubeconfig, and it
#       BYPASSES Entra, MFA, Conditional Access and the entire RBAC model - with almost
#       no log trail, because there is no Entra sign-in event.
#       Cost: this removes break-glass. If Entra is unavailable nobody can reach the
#       API server, so the runbook documents a PIM-gated, alerted, two-person procedure
#       to temporarily re-enable it.
#   azure_rbac_enabled = true        - authorisation decisions delegate to Azure role
#       assignments, giving a central Activity Log audit trail, Entra group lifecycle,
#       and PIM just-in-time elevation. Native Kubernetes RBAC still applies alongside
#       it (they are additive authorisers), so fine-grained Role objects remain
#       available for what Azure's four built-in roles cannot express.
#
# NETWORKING
#   network_plugin_mode = "overlay"  - pods get IPs from pod_cidr, NOT from the VNet.
#       Decouples pod scale from VNet IPAM scale (see the node subnet comment).
#   outbound_type = "userDefinedRouting" - CRITICAL. The default (loadBalancer) makes
#       AKS provision a public Standard Load Balancer for outbound SNAT, bypassing the
#       firewall entirely. This setting says 'I own egress; do not create a path'.
#   network_policy = "calico"        - in-cluster pod-to-pod policy enforcement.
#       Azure now recommends Cilium (eBPF, better scaling, L7 and FQDN egress policy);
#       Calico is the mature, well-understood choice and its retirement path has been
#       announced. Worth naming as a decision I would revisit.
#
# OPERATIONS
#   sku_tier = "Standard"            - the Free tier has NO API server SLA. Standard is
#       the minimum for anything production-like (99.95% with availability zones).
#   oms_agent + msi_auth_for_monitoring_enabled - Container Insights authenticating with
#       a managed identity rather than a workspace key.
#   azure_policy_enabled = true      - installs Gatekeeper so the Kubernetes policies in
#       modules/governance are actually enforced at admission.
#   maintenance_window_node_os       - node OS patching lands in a known window
#       (Sunday 02:00 UTC) rather than at random.
#
# LIFECYCLE
#   prevent_destroy                  - a cluster recreate is not a routine operation.
#   ignore_changes on node_count     - the cluster autoscaler owns the live count;
#       without this, every plan shows a diff and every apply fights the autoscaler.
#
# KNOWN DEFECTS (docs/02):
#   P1-13: automatic_upgrade_channel = "patch" with a pinned kubernetes_version = "1.30"
#     produces a PERPETUAL DIFF (state says 1.30, Azure says 1.30.5). Either add
#     kubernetes_version to ignore_changes, or set the channel to "none" and drive
#     upgrades through the pipeline. For a bank I would use node-os patching
#     automatically and control-plane upgrades by PR.
#   P1-9:  os_disk_type = "Ephemeral" on Standard_D2s_v5 - the Dsv5 series has NO local
#     temp disk, so ephemeral OS is unsupported at this size. Needs Standard_D2ds_v5
#     (the 'd' means local storage) or os_disk_type = "Managed".
#   P1-10: only_critical_addons_enabled = var.enable_user_node_pool couples a taint to
#     an unrelated flag. Changing it RECREATES the node pool, and flipping the flag on a
#     live cluster silently lets app pods onto system nodes. Should be an explicit
#     variable with a validation block.
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
    only_critical_addons_enabled = var.enable_user_node_pool
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

# SEPARATE USER NODE POOL. The system pool runs CoreDNS, metrics-server, the Workload
# Identity webhook and the OMS agent. If an application pod with a memory leak lands
# there and triggers eviction, you lose CLUSTER DNS - and a DNS outage presents as a
# total, inexplicable failure of absolutely everything. The CriticalAddonsOnly taint on
# the system pool (via only_critical_addons_enabled) makes that impossible.
#
# TRADE-OFF: a minimum of four nodes even when idle (2 system + 2 user), and worse
# bin-packing because each pool carries its own headroom. In non-prod I would drop the
# system pool to a single node and accept no system-pool HA.
#
# node_labels workload=application is what values-prod.yaml's nodeSelector targets, so
# the API is pinned to this pool.
#
# Zones 1/2/3 with the cluster autoscaler balancing across them means a single-zone
# failure removes roughly a third of capacity rather than all of it. Combined with the
# chart's topologySpreadConstraints and PodDisruptionBudget, that is real zone
# resilience. It does incur cross-zone data transfer charges.
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

# AKS RBAC WRITER for the pipeline - deliberately NOT Admin.
#
# Writer can deploy workloads. It CANNOT create RoleBinding or ClusterRoleBinding
# objects. That is the specific privilege-escalation path being closed: a compromised
# pipeline cannot grant itself cluster-admin.
#
# Note that RBAC Reader (assigned above) also cannot read Secrets - a deliberate
# carve-out in the built-in role.
resource "azurerm_role_assignment" "aks_cluster_deployers" {
  count = length(var.deployer_principal_ids)

  scope                = azurerm_kubernetes_cluster.aks_cluster.id
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  principal_id         = var.deployer_principal_ids[count.index]
}

# CLUSTER USER ROLE is a SEPARATE, and frequently-missed, requirement.
#
# It permits 'az aks get-credentials' - downloading a kubeconfig - and grants NO
# in-cluster permissions at all. Having only this role gives you a working kubeconfig
# and 403 on every command, which reliably looks like a network problem for the first
# twenty minutes of debugging (Troubleshooting Scenario 4).
#
# So every principal that needs to reach the cluster needs BOTH: Cluster User to get
# credentials, plus RBAC Reader/Writer/Admin to actually do anything.
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
