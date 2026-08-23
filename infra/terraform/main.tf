# =============================================================================
#                   Central Terraform Module.
# =============================================================================

# -----------------------------------------------------------------------------
# Pre-requisites: RG + Defaults
# -----------------------------------------------------------------------------

# WHY TWO RESOURCE GROUPS
# -----------------------
# rg_hub holds shared connectivity/security (Azure Firewall, private DNS zones).
# rg_infra holds the workload (AKS, ACR, Storage, Key Vault, pipeline agent).
# Separating them gives the two layers independent blast radii, independent RBAC and
# independent change cadence - a platform team can own the hub while an application
# team owns the spoke. It is also the shape every Azure Landing Zone assumes, so it
# grows into a real estate without rework.
#
# TRADE-OFF: cross-RG references. Private endpoints in rg_infra register DNS records
# into zones in rg_hub, which in a real bank means a delegated RBAC grant and a
# cross-team dependency for every new private endpoint.

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "rg_infra" {
  name     = "rg-${var.environment}-${var.name_prefix}"
  location = var.location
  tags     = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_resource_group" "rg_hub" {
  name     = "rg-${var.environment}-${var.name_prefix}-hub"
  location = var.location
  tags     = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Diagnostics settings (Log Analytics Workspace, App Insights, Azure Monitor)
# -----------------------------------------------------------------------------

# Layer 0 - the telemetry sink. Everything else sends diagnostics here, so it must be
# created first and must itself depend on nothing.
#
# KNOWN DEFECT (docs/02 P0-3): this module ALSO creates the AMPLS private endpoint,
# which needs module.network_spoke and module.private_dns - both of which need this
# module's workspace ID. That is a dependency CYCLE and Terraform will refuse to build
# the graph. The fix is never depends_on: it is to split this into observability-core
# (workspace, layer 0) and observability-ampls (private access, layer 2). A cycle
# always means one module is doing two jobs at two different layers.
module "observability" {
  source = "../modules/observability"
  resource_group_name          = azurerm_resource_group.rg_infra.name
  location                     = azurerm_resource_group.rg_infra.location
  tags                         = azurerm_resource_group.rg_infra.tags
  log_analytics_name           = "log-${var.environment}-${var.name_prefix}"
  app_insights_name            = "appi-${var.environment}-${var.name_prefix}"
  ampls_name                   = "ampls-${var.environment}-${var.name_prefix}"
  retention_in_days            = var.log_retention_days
  daily_quota_gb               = var.log_daily_quota_gb
  enable_private_link          = var.enable_monitor_private_link
  allow_public_query           = var.allow_public_log_query
  private_endpoint_subnet_id   = module.network_spoke.private_endpoint_subnet_id
  monitor_private_dns_zone_ids = [for z in var.private_dns_zones : module.private_dns.zone_ids[z]]
  alert_email_receivers        = var.alert_email_receivers
}

# -----------------------------------------------------------------------------
# Network Components  — VNets(Hub + Spoke) + subnets + NSGs + Firewall + Spoke Peering + Association
# -----------------------------------------------------------------------------

# HUB - shared connectivity. Azure Firewall is the single controlled egress point.
#
# The security decision embedded here: allowed_egress_fqdns is an explicit ALLOW-list
# (api.tvmaze.com), not a deny-list. Everything unnamed is denied and logged, which
# turns 'denied egress' into a detection signal - a compromised container trying to
# phone home both fails and shows up in Log Analytics.
#
# Chose Firewall over NAT Gateway for POLICY, not connectivity. NAT Gateway is cheaper
# (~$35 vs ~$950/month) and has far better SNAT headroom (64,512 vs 2,496 ports per
# public IP), but applies no policy at all - no data-exfiltration control and no
# per-destination logging. See docs/03 section B for the full comparison.
module "network_hub" {
  source = "../modules/network-hub"
  location                = azurerm_resource_group.rg_hub.location
  resource_group_name     = azurerm_resource_group.rg_hub.name
  tags                    = azurerm_resource_group.rg_hub.tags
  environment             = var.environment
  hub_vnet_name           = "vnet-hub-${var.environment}"
  hub_address_space       = var.hub_address_space
  firewall_subnet_prefix  = var.firewall_subnet_prefix
  firewall_name           = var.firewall_name
  firewall_policy_name    = var.firewall_policy
  firewall_public_ip_name = var.firewall_pip
  firewall_sku_tier       = var.firewall_sku_tier
  enable_firewall         = var.enable_firewall
  availability_zones      = var.availability_zones
  route_table_name        = var.route_table_name
  spoke_address_spaces    = [var.spoke_address_space]
  allowed_egress_fqdns    = var.allowed_egress_fqdns
  enable_diagnostics         = true
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

# SPOKE - the workload network. Three subnets, three distinct trust levels:
#   snet-aks-nodes         - forced-tunnelled to the firewall via UDR
#   snet-private-endpoints - deliberately NOT forced-tunnelled (see the module)
#   snet-pipeline-agents   - the CI/CD agent, no public IP
#
# enable_forced_tunnelling = var.enable_firewall couples the default route to the
# firewall's existence. Without the coupling, disabling the firewall would leave a
# route pointing at a next hop that no longer exists, black-holing all egress.
#
# KNOWN DEFECT (docs/02 P1-4): nsg_rules_* are defined in the environment tfvars but
# never declared in this root module and never passed here - so all three NSGs deploy
# EMPTY and fall back to Azure defaults (allow all intra-VNet, allow all outbound).
# The network layer of defence-in-depth does not currently exist in deployed form.
module "network_spoke" {
  source = "../modules/network-spoke"
  resource_group_name            = azurerm_resource_group.rg_infra.name
  location                       = azurerm_resource_group.rg_infra.location
  tags                           = azurerm_resource_group.rg_infra.tags
  environment                    = var.environment
  spoke_vnet_name                = "vnet-spoke-${var.environment}"
  spoke_address_space            = var.spoke_address_space
  aks_subnet_prefix              = var.aks_subnet_prefix
  private_endpoint_subnet_prefix = var.private_endpoint_subnet_prefix
  pipeline_agent_subnet_prefix   = var.pipeline_agent_subnet_prefix
  route_table_name               = var.route_table_name
  enable_forced_tunnelling       = var.enable_firewall
  firewall_private_ip            = var.enable_firewall ? module.network_hub.firewall_private_ip : ""
  hub_vnet_id                    = module.network_hub.hub_vnet_id
  hub_vnet_name                  = module.network_hub.hub_vnet_name
  hub_resource_group_name        = azurerm_resource_group.rg_hub.name
  internal_consumer_cidrs        = var.internal_consumer_cidrs
  enable_diagnostics             = true
  log_analytics_workspace_id     = module.observability.log_analytics_workspace_id
}

# -----------------------------------------------------------------------------
# DNS Components  — Private DNS Zones + VNet Links
# -----------------------------------------------------------------------------

# PRIVATE DNS - the mechanism that makes 'private endpoint' actually work.
#
# Zones live in the HUB because DNS is a shared connectivity service whose lifecycle
# should outlive any single workload. They are linked to BOTH VNets deliberately:
#   - the spoke link is what makes PODS resolve private IPs
#   - the hub link is what makes the FIREWALL's DNS proxy (and any future jumpbox or
#     DNS Private Resolver) resolve them too
#
# A zone linked to the wrong VNet is the single most common Private Link failure:
# resolution silently falls through to public DNS, returns the PUBLIC IP, and the
# connection is then refused because public access is disabled. That is Scenario 2.
#
# KNOWN DEFECT (docs/02 P1-3): the module declares 'private_dns_zones', not
# 'zone_names' - this argument name does not match and Terraform will error.
module "private_dns" {
  source = "../modules/private-dns"
  resource_group_name = azurerm_resource_group.rg_hub.name
  tags                = azurerm_resource_group.rg_hub.tags
  zone_names          = var.private_dns_zones
  enable_diagnostics  = true
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
  linked_virtual_networks = {
    spoke = module.network_spoke.spoke_vnet_id
    hub   = module.network_hub.hub_vnet_id
  }
}

# -----------------------------------------------------------------------------
# ACR Components — ACR + Private Endpoint + Private DNS Zone Link
# -----------------------------------------------------------------------------

# ACR - Premium is MANDATORY here, not a preference: Basic and Standard cannot have
# private endpoints at all. Worth saying it that way - the requirement dictates the
# SKU, rather than defending Premium on its feature list.
#
# Note WHICH identity gets WHICH role. This is a classic interview trap:
#   pull_principal_ids = kubelet identity  <- the KUBELET pulls images, NOT the
#     cluster's control-plane identity. They are separate managed identities, and
#     granting AcrPull to the wrong one means everything provisions cleanly and no
#     image ever pulls (ImagePullBackOff - Scenario 3).
#   push_principal_ids = pipeline          <- AcrPush, deliberately not Owner, which
#     could disable the registry firewall.
module "acr" {
  source = "../modules/container-registry"
  name                      = "acr${var.environment}"
  resource_group_name        = azurerm_resource_group.rg_infra.name
  location                   = azurerm_resource_group.rg_infra.location
  environment                 = var.environment
  tags                       = azurerm_resource_group.rg_infra.tags
  private_endpoint_subnet_id = module.network_spoke.private_endpoint_subnet_id
  private_dns_zone_id        = module.private_dns.zone_ids["privatelink.azurecr.io"]
  pull_principal_ids         = [module.aks.kubelet_identity_object_id]
  push_principal_ids         = var.pipeline_principal_ids
  enable_diagnostics         = true
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

# -----------------------------------------------------------------------------
# Storage Components — Storage Account + Private Endpoint + Private DNS Zone Link
# -----------------------------------------------------------------------------

# STORAGE - the TVMaze response cache.
#
# for_each over a count lets the storage tier be PARTITIONED later without
# restructuring the module. A single account throttles around 20,000 req/s, so this is
# the pre-built escape hatch for that ceiling.
#
# Why Blob rather than Redis: for a 1-hour TTL, Blob's 10-50ms read latency is
# irrelevant next to the ~200ms upstream call it replaces, and it is durable, cheap,
# and shared across every replica with no extra tier to operate. Redis becomes the
# right answer the moment the TTL drops below about a minute.
#
# KNOWN DEFECT (docs/02 P0-5): data_contributor_principal_ids is NOT passed, so
# module.identity receives ZERO role assignments and the pod gets
# '403 AuthorizationPermissionMismatch' on every blob call. This ships the exact bug
# the assessment asks us to troubleshoot (Scenario 1). Fix:
#   data_contributor_principal_ids = [module.identity.principal_id]
module "storage" {
  source   = "../modules/storage-account"
  for_each = { for i in range(var.storage_account_count) : format("%02d", i + 1) => i }

  name                           = "sa${var.environment}${each.key}"
  resource_group_name            = azurerm_resource_group.rg_infra.name
  location                       = azurerm_resource_group.rg_infra.location
  tags                           = azurerm_resource_group.rg_infra.tags
  replication_type               = var.storage_replication_type
  cache_container_name           = var.cache_container_name
  cache_expiry_days              = var.cache_expiry_days
  private_endpoint_subnet_id     = module.network_spoke.private_endpoint_subnet_id
  blob_private_dns_zone_id       = module.private_dns.zone_ids["privatelink.blob.core.windows.net"]
  blob_private_dns_zone_name     = module.private_dns.zone_names["privatelink.blob.core.windows.net"]
  enable_diagnostics             = true
  log_analytics_workspace_id     = module.observability.log_analytics_workspace_id
}

# -----------------------------------------------------------------------------
# Keyvault Components — + Private Endpoint + Private DNS Zone Link
# -----------------------------------------------------------------------------

# KEY VAULT - provisioned by IaC, but deliberately EMPTY.
#
# Terraform never writes a secret VALUE anywhere in this repository. The only real
# secret in the whole design (the Azure DevOps agent registration PAT) is created
# out-of-band with 'az keyvault secret set' and read at boot by the agent VM's managed
# identity. That separation - IaC provisions the vault, operations populate it - is
# precisely why no secret ever enters Terraform state or source control.
#
#   secrets_user_principal_ids    = read secret VALUES (pipeline, agent)
#   secrets_officer_principal_ids = MANAGE secrets     (admin group, ideally PIM-eligible)
# Note this is Secrets Officer, not Key Vault Administrator - the latter would also
# let the holder change who else has access.
module "key_vault" {
  source = "../modules/key-vault"

  name                          = "kv-${var.environment}-${var.name_prefix}"
  resource_group_name           = azurerm_resource_group.rg_infra.name
  location                      = azurerm_resource_group.rg_infra.location
  tags                          = azurerm_resource_group.rg_infra.tags
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  private_endpoint_subnet_id    = module.network_spoke.private_endpoint_subnet_id
  private_dns_zone_id           = module.private_dns.zone_ids["privatelink.vaultcore.azure.net"]
  private_dns_zone_name         = module.private_dns.zone_names["privatelink.vaultcore.azure.net"]
  secrets_user_principal_ids    = var.pipeline_principal_ids
  secrets_officer_principal_ids = var.kv_admin_group_object_ids
  enable_diagnostics            = true
  log_analytics_workspace_id    = module.observability.log_analytics_workspace_id
}

# ---------------------------------------------------------------------------
# AKS Components + Private Endpoint + Private DNS Zone Link
# ---------------------------------------------------------------------------
# AKS - the core of the platform. The security-relevant settings live inside the
# module; the wiring that matters is here:
#
#   private_dns_zone_id -> a CUSTOMER-managed zone, not 'System'. A system-managed zone
#     lives inside the AKS-managed node resource group and cannot be linked to other
#     VNets, so the pipeline agent could never resolve the private API server.
#
#   route_table_id -> the control-plane identity needs Network Contributor on this
#     BEFORE cluster creation, because outbound_type = userDefinedRouting makes the
#     route table a hard creation-time dependency of the cluster.
#
# KNOWN DEFECT (docs/02 P0-8): node_resource_group_name == resource_group_name. Azure
# rejects this - the node RG is AKS-managed and must not already exist. It also breaks
# isolation: never put ACR/KV/Storage inside a resource group an AKS upgrade can
# mutate. Should be "rg-${var.environment}-${var.name_prefix}-aks-nodes".
module "aks" {
  source = "../modules/aks"
  name                        = "aks-${var.environment}-${var.name_prefix}"
  node_resource_group_name    = azurerm_resource_group.rg_infra.name
  control_plane_identity_name = "id-aks-control-${var.environment}-${var.name_prefix}"
  resource_group_name         = azurerm_resource_group.rg_infra.name
  location                    = azurerm_resource_group.rg_infra.location
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  tags                        = azurerm_resource_group.rg_infra.tags
  kubernetes_version          = var.kubernetes_version
  sku_tier                    = var.aks_sku_tier
  node_subnet_id              = module.network_spoke.aks_subnet_id
  enable_forced_tunnelling    = var.enable_firewall
  private_dns_zone_id         = module.private_dns.zone_ids["privatelink.westeurope.azmk8s.io"]
  private_dns_zone_name       = module.private_dns.zone_names["privatelink.westeurope.azmk8s.io"]
  route_table_id              = module.network_spoke.route_table_id
  pod_cidr                    = var.pod_cidr
  service_cidr                = var.service_cidr
  dns_service_ip              = var.dns_service_ip
  availability_zones          = var.availability_zones
  system_node_vm_size         = var.system_node_vm_size
  system_node_min_count       = var.system_node_min_count
  system_node_max_count       = var.system_node_max_count
  enable_user_node_pool       = var.enable_user_node_pool
  user_node_vm_size           = var.user_node_vm_size
  user_node_min_count         = var.user_node_min_count
  user_node_max_count         = var.user_node_max_count
  admin_group_object_ids      = var.aks_admin_group_object_ids
  reader_group_object_ids     = var.aks_reader_group_object_ids
  deployer_principal_ids      = var.pipeline_principal_ids
  log_analytics_workspace_id  = module.observability.log_analytics_workspace_id
}

# ---------------------------------------------------------------------------
# Identity Components
# ---------------------------------------------------------------------------

# WORKLOAD IDENTITY - the credential-free path from pod to Azure.
#
# Creates a user-assigned managed identity plus a FEDERATED IDENTITY CREDENTIAL whose
# 'subject' must EXACTLY equal system:serviceaccount:<namespace>:<serviceaccount>.
# Entra performs a character-for-character comparison; a mismatch produces AADSTS70021
# ('no matching federated identity record') on the pod's first Azure call.
#
# User-assigned rather than system-assigned on purpose: a system-assigned identity is
# tied to its resource's lifecycle, so recreating the resource yields a NEW principal
# ID and every role assignment silently breaks. User-assigned identities are
# independent, which also lets you grant permissions before the consumer exists -
# useful for breaking dependency cycles.
#
# KNOWN DEFECT (docs/02 P0-6): var.app_service_account_name defaults to 'banking-api',
# charts/banking-application/values.yaml defaults to 'banking-application', and
# pipelines/variables/common.yml uses 'banking-application' for the namespace. The
# pipeline overrides both correctly from these outputs, so the DEFAULTS are what is
# wrong - but the real fix is to make disagreement impossible rather than unlikely
# (a fail guard in _helpers.tpl comparing the rendered subject to an expected value).
module "identity" {
  source = "../modules/identity"

  identity_name       = "id-aks-${var.environment}-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.rg_infra.name
  location            = azurerm_resource_group.rg_infra.location
  tags                = azurerm_resource_group.rg_infra.tags
  oidc_issuer_url     = module.aks.oidc_issuer_url

  service_accounts = {
    api = {
      namespace            = var.app_namespace
      service_account_name = var.app_service_account_name
    }
  }
}

# ---------------------------------------------------------------------------
# Self-hosted Azure Pipelines agent — Linux VM in rg_infra
# ---------------------------------------------------------------------------

# SELF-HOSTED PIPELINE AGENT - the answer to the assessment's 'pipeline networking
# requirement'. A Microsoft-hosted agent physically cannot deploy here: it runs in
# Microsoft's network with no route to snet-private-endpoints and no link to our
# private DNS zones, so acr*.azurecr.io resolves to a public IP and the connection is
# refused because public network access is disabled.
#
# TWO IDENTITIES, deliberately separated:
#   - this VM's managed identity: Key Vault Secrets User ONLY. It can read its own
#     registration PAT and can deploy NOTHING.
#   - the Azure DevOps service connection: federated (no stored secret), holding
#     AcrPush + AKS RBAC Writer + the ARM roles Terraform needs.
# So compromising the agent HOST yields a PAT scoped to agent pools, not a path into
# the subscription. Residual risk: the currently-running job's OIDC token - which is
# the argument for ephemeral, per-job agents.
#
# KNOWN GAP (docs/02 P2-10): this is a SINGLE VM with no availability zone. If it dies
# you cannot deploy OR roll back - during an incident, which is exactly when you need
# to. Production wants a VMSS across zones, Managed DevOps Pools, or KEDA-scaled agent
# pods running in AKS itself.
module "pipeline_agent" {
  count  = var.enable_pipeline_agent_vm ? 1 : 0
  source = "../modules/pipeline-agent"

  name                 = "vm-agent-${var.environment}-${var.name_prefix}"
  resource_group_name  = azurerm_resource_group.rg_infra.name
  location             = azurerm_resource_group.rg_infra.location
  tags                 = azurerm_resource_group.rg_infra.tags
  subnet_id            = module.network_spoke.pipeline_agent_subnet_id
  vm_size              = var.agent_vm_size
  admin_username       = var.agent_admin_username
  admin_ssh_public_key = var.agent_admin_ssh_public_key
  key_vault_id         = module.key_vault.id
  key_vault_uri        = module.key_vault.vault_uri
  pat_secret_name      = var.agent_pat_secret_name
  devops_org_url       = var.devops_org_url
  devops_pool_name     = var.agent_pool_name
  agent_version        = var.agent_package_version
  terraform_version   = var.agent_terraform_version
  helm_version        = var.agent_helm_version
  kubectl_version     = var.agent_kubectl_version
  trivy_version       = var.agent_trivy_version
  gitleaks_version    = var.agent_gitleaks_version
  kubeconform_version = var.agent_kubeconform_version
  enable_diagnostics  = true
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

# ---------------------------------------------------------------------------
# Governance
# ---------------------------------------------------------------------------
# GOVERNANCE - Azure Policy is the only genuinely PREVENTIVE layer in the
# public-access model.
#
# Terraform is CORRECTIVE: it only fixes drift when it next runs. Policy in Deny mode
# rejects the ARM request before it takes effect, regardless of who made it or which
# tool they used - portal, CLI, or another pipeline. That is why policy exists here
# even though every resource already sets public_network_access_enabled = false.
#
# kubernetes_policy_effect defaults to Audit on purpose: applying Deny Gatekeeper
# constraints to a live cluster instantly blocks deployments that were previously
# fine, potentially including system components. Correct rollout is
# Audit -> measure -> remediate -> Deny.
#
# KNOWN DEFECTS (docs/02 P1-8): assignments are at RESOURCE-GROUP scope, so anyone who
# can create a new RG escapes all of them and rg_hub is entirely ungoverned - real
# governance belongs at management-group scope. And the required-tags policy demands
# 'cost_centre', which the environment tfvars do not set, so this policy would deny
# our own next apply.
module "governance" {
  source = "../modules/governance"

  resource_group_name      = azurerm_resource_group.rg_infra.name
  allowed_locations        = var.policy_allowed_locations
  required_tags            = var.policy_required_tags
  kubernetes_policy_effect = var.kubernetes_policy_effect
  enforce                  = var.policy_enforce
  depends_on = [module.aks, module.storage, module.acr]
}
