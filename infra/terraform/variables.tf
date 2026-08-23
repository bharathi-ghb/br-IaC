# -----------------------------------------------------------------------------
# Common Variables
# -----------------------------------------------------------------------------

variable "location" {
  type        = string
  default     = "westeurope"
  description = "Azure region"
}

variable "name_prefix" {
  type        = string
  default     = ""
  description = "named resources"
}

variable "environment" {
  type        = string
  default     = ""
  description = "Environment name"
}

variable "tags" {
  type = map(string)
  default = {
    workload  = "iac"
    managedBy = "terraform"
    owner     = "abn-amro"
    environment = ""
  }
}

# -----------------------------------------------------------------------------
# Observability components Variables
# -----------------------------------------------------------------------------

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 90
}

variable "log_daily_quota_gb" {
  description = "Daily ingestion cap in GB (-1 for unlimited)."
  type        = number
  default     = -1
}

variable "enable_monitor_private_link" {
  description = "Create an Azure Monitor Private Link Scope."
  type        = bool
  default     = true
}

variable "allow_public_log_query" {
  description = "Allow log queries from outside the VNet."
  type        = bool
  default     = false
}

variable "alert_email_receivers" {
  description = "Map of receiver name to email address for alerts."
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# Network Components Variables
# -----------------------------------------------------------------------------

variable "hub_address_space" {
  description = "CIDR of the hub VNet."
  type        = string
}

variable "firewall_subnet_prefix" {
  description = "CIDR of AzureFirewallSubnet."
  type        = string
}

variable "spoke_address_space" {
  description = "CIDR of spoke VNet."
  type        = string
}

variable "aks_subnet_prefix" {
  description = "CIDR of AKS node subnet."
  type        = string
}

variable "private_endpoint_subnet_prefix" {
  description = "CIDR of private endpoint subnet."
  type        = string
}

variable "pipeline_agent_subnet_prefix" {
  description = "CIDR of self-hosted pipeline agent subnet."
  type        = string
  default     = ""
}

variable "internal_consumer_cidrs" {
  description = "Internal networks permitted."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "enable_firewall" {
  description = "Deploy Azure Firewall."
  type        = bool
  default     = true
}

variable "firewall_sku_tier" {
  description = "Azure Firewall tier."
  type        = string
  default     = "Standard"
}

variable "firewall_policy" {
  description = "Azure Firewall tier."
  type        = string
  default     = ""
}

variable "firewall_pip" {
  description = "Azure Firewall tier."
  type        = string
  default     = ""
}

variable "allowed_egress_fqdns" {
  description = "External FQDNs."
  type        = list(string)
  default     = []
}

variable "availability_zones" {
  description = "Availability zones."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "route_table_name" {
  description = "Name of the route table"
  type        = string
  default     = ""
}

variable "firewall_name" {
  description = "Name of the Azure Firewall"
  type        = string
  default     = ""
}

variable "nsg_rules_aks_nodes" {
  description = "(Optional) A list of security rules to apply to the Network Security Group"
  type = list(object({
    access                                     = string
    description                                = optional(string, "")
    destination_address_prefixes               = optional(list(string), null)
    destination_application_security_group_ids = optional(list(string), [])
    destination_port_ranges                    = optional(list(string), null)
    direction                                  = optional(string, "Inbound")
    name                                       = string
    priority                                   = number
    protocol                                   = optional(string, "Tcp")
    source_address_prefixes                    = optional(list(string), null)
    source_application_security_group_ids      = optional(list(string), [])
    source_port_ranges                         = optional(list(string), null)
  }))
  default = []
}

variable "nsg_rules_private_endpoints" {
  description = "(Optional) A list of security rules to apply to the Network Security Group"
  type = list(object({
    access                                     = string
    description                                = optional(string, "")
    destination_address_prefixes               = optional(list(string), null)
    destination_application_security_group_ids = optional(list(string), [])
    destination_port_ranges                    = optional(list(string), null)
    direction                                  = optional(string, "Inbound")
    name                                       = string
    priority                                   = number
    protocol                                   = optional(string, "Tcp")
    source_address_prefixes                    = optional(list(string), null)
    source_application_security_group_ids      = optional(list(string), [])
    source_port_ranges                         = optional(list(string), null)
  }))
  default = []
}

variable "nsg_rules_pipeline_agents" {
  description = "(Optional) A list of security rules to apply to the Network Security Group"
  type = list(object({
    access                                     = string
    description                                = optional(string, "")
    destination_address_prefixes               = optional(list(string), null)
    destination_application_security_group_ids = optional(list(string), [])
    destination_port_ranges                    = optional(list(string), null)
    direction                                  = optional(string, "Inbound")
    name                                       = string
    priority                                   = number
    protocol                                   = optional(string, "Tcp")
    source_address_prefixes                    = optional(list(string), null)
    source_application_security_group_ids      = optional(list(string), [])
    source_port_ranges                         = optional(list(string), null)
  }))
  default = []
}

# -----------------------------------------------------------------------------
# DNS Components Variables
# -----------------------------------------------------------------------------

variable "private_dns_zones" {
  description = "List of private DNS zones to create."
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# Storage Components Variables
# -----------------------------------------------------------------------------

variable "storage_account_count" {
  description = "sequentially-suffixed storage accounts to create"
  type        = number
  default     = 1
}

variable "storage_replication_type" {
  description = "Storage replication mode."
  type        = string
  default     = "LRS"
}

variable "cache_container_name" {
  description = "Blob container used for cached upstream responses."
  type        = string
  default     = "shows-cache"
}

variable "cache_expiry_days" {
  description = "Days before a cached blob is deleted by lifecycle management."
  type        = number
  default     = 7
}

variable "acr_untagged_retention_days" {
  description = "Days to keep untagged manifests in the registry."
  type        = number
  default     = 7
}

variable "enable_kv_purge_protection" {
  description = "Enable Key Vault purge protection. Irreversible once on."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# AKS Components Variables
# -----------------------------------------------------------------------------

variable "kubernetes_version" {
  description = "Pinned Kubernetes minor version."
  type        = string
  default     = "1.30"
}

variable "aks_sku_tier" {
  description = "AKS control-plane tier."
  type        = string
  default     = "Standard"
}

variable "pod_cidr" {
  description = "Overlay CIDR for pods."
  type        = string
  default     = "192.168.0.0/16"
}

variable "service_cidr" {
  description = "CIDR for Kubernetes services."
  type        = string
  default     = "172.16.0.0/16"
}

variable "dns_service_ip" {
  description = "CoreDNS service IP, inside service_cidr."
  type        = string
  default     = "172.16.0.10"
}

variable "system_node_vm_size" {
  description = "VM size for the system node pool."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "system_node_min_count" {
  description = "Minimum system nodes."
  type        = number
  default     = 2
}

variable "system_node_max_count" {
  description = "Maximum system nodes."
  type        = number
  default     = 4
}

variable "enable_user_node_pool" {
  description = "Create a dedicated application node pool."
  type        = bool
  default     = true
}

variable "user_node_vm_size" {
  description = "VM size for the application node pool."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "user_node_min_count" {
  description = "Minimum application nodes."
  type        = number
  default     = 2
}

variable "user_node_max_count" {
  description = "Maximum application nodes."
  type        = number
  default     = 6
}

variable "aks_admin_group_object_ids" {
  description = "Entra group object IDs with cluster-admin via Azure RBAC. Prefer PIM-eligible groups."
  type        = list(string)
  default     = []
}

variable "aks_reader_group_object_ids" {
  description = "Entra group object IDs with read-only cluster access."
  type        = list(string)
  default     = []
}

variable "kv_admin_group_object_ids" {
  description = "Entra group object IDs allowed to manage Key Vault secrets."
  type        = list(string)
  default     = []
}

variable "pipeline_principal_ids" {
  description = "Object ID(s) of the Azure DevOps service connection identity. Granted AcrPush and AKS RBAC Writer - deliberately not Owner or Contributor."
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# Self-hosted Pipeline Agent Variables
# -----------------------------------------------------------------------------

variable "enable_pipeline_agent_vm" {
  description = "Provision the self-hosted Azure Pipelines agent VM in rg_infra. Disable if agent infrastructure is managed elsewhere."
  type        = bool
  default     = true
}

variable "agent_vm_size" {
  description = "VM size for the self-hosted agent."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "agent_admin_username" {
  description = "Local admin username on the agent VM. Day-to-day access is via Entra ID login (AADSSHLoginForLinux), not this account."
  type        = string
  default     = "azureagent"
}

variable "agent_admin_ssh_public_key" {
  description = "SSH public key for the agent VM's local admin account. Required by Azure for VM creation; keep the matching private key out of source control."
  type        = string
}

variable "agent_pat_secret_name" {
  description = "Name of the Key Vault secret holding the Azure DevOps agent pool PAT. Create the secret out-of-band (az keyvault secret set) - Terraform never writes its value."
  type        = string
  default     = "ado-agent-pat"
}

variable "devops_org_url" {
  description = "Azure DevOps organisation URL, e.g. https://dev.azure.com/<org>."
  type        = string
}

variable "agent_pool_name" {
  description = "Agent pool the VM registers into. Must match privatePoolName in pipelines/variables/common.yml."
  type        = string
  default     = "private-selfhosted-linux"
}

variable "agent_package_version" {
  description = "Azure Pipelines agent package version (vsts-agent-linux-x64)."
  type        = string
  default     = "4.248.0"
}

variable "agent_terraform_version" {
  description = "Terraform version pre-installed on the agent. Keep in sync with pipelines/variables/common.yml terraformVersion."
  type        = string
  default     = "1.9.5"
}

variable "agent_helm_version" {
  description = "Helm version pre-installed on the agent. Keep in sync with pipelines/variables/common.yml helmVersion."
  type        = string
  default     = "3.16.2"
}

variable "agent_kubectl_version" {
  description = "kubectl version pre-installed on the agent. Keep in sync with pipelines/variables/common.yml kubectlVersion."
  type        = string
  default     = "1.30.5"
}

variable "agent_trivy_version" {
  description = "Trivy version pre-installed on the agent. Keep in sync with the version pinned in pipelines/templates/stage-security.yml."
  type        = string
  default     = "0.58.1"
}

variable "agent_gitleaks_version" {
  description = "Gitleaks version pre-installed on the agent. Keep in sync with the version pinned in pipelines/templates/stage-security.yml."
  type        = string
  default     = "8.21.2"
}

variable "agent_kubeconform_version" {
  description = "kubeconform version pre-installed on the agent. Keep in sync with the version pinned in pipelines/templates/stage-validate.yml."
  type        = string
  default     = "0.6.7"
}

# -----------------------------------------------------------------------------
# Identity Components Variables
# -----------------------------------------------------------------------------

variable "app_namespace" {
  description = "Kubernetes namespace for the application. Must match the Helm release namespace."
  type        = string
  default     = "banking-api"
}

variable "app_service_account_name" {
  description = "ServiceAccount name federated to the workload identity. Must match the Helm chart."
  type        = string
  default     = "banking-api"
}

# -----------------------------------------------------------------------------
# Policy Components Variables
# -----------------------------------------------------------------------------

variable "policy_allowed_locations" {
  description = "Regions permitted by the data residency policy."
  type        = list(string)
  default     = ["westeurope", "northeurope"]
}

variable "policy_required_tags" {
  description = "Tags every resource must carry."
  type        = list(string)
  default     = ["environment", "owner", "cost_centre"]
}

variable "kubernetes_policy_effect" {
  description = "Effect for in-cluster Gatekeeper policies: Audit, Deny or Disabled."
  type        = string
  default     = "Audit"
}

variable "policy_enforce" {
  description = "Whether policy assignments enforce their effect."
  type        = bool
  default     = true
}
