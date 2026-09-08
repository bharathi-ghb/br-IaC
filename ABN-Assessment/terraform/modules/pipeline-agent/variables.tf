variable "name" {
  description = "Name of the agent VM."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group the VM is deployed into (rg_infra — same RG as AKS, ACR, Storage and Key Vault)."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource created by this module."
  type        = map(string)
}

variable "subnet_id" {
  description = "Resource ID of the pipeline-agent subnet (snet-pipeline-agents). The VM gets no public IP; its NSG must allow outbound 443 to the private-endpoint and AKS API subnets."
  type        = string
}

variable "vm_size" {
  description = "VM size. Needs enough CPU/memory to run Docker builds, Trivy/Checkov scans and Terraform concurrently."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "os_disk_type" {
  description = "OS disk storage type."
  type        = string
  default     = "Premium_LRS"
}

variable "os_disk_size_gb" {
  description = "OS disk size. Sized above the default to hold Docker images pulled/built during CI runs."
  type        = number
  default     = 128
}

variable "admin_username" {
  description = "Local admin username. Day-to-day access is via Entra ID (AADSSHLoginForLinux), not this account directly."
  type        = string
  default     = "azureagent"
}

variable "admin_ssh_public_key" {
  description = "SSH public key for the local admin account. Required by Azure for Linux VM creation even though the intended access path is Entra ID login via AADSSHLoginForLinux/az ssh vm; keep the matching private key out of source control."
  type        = string
}

variable "availability_zone" {
  description = "Availability zone for the VM, or null to let Azure choose."
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# Key Vault access — the agent PAT is read at boot, never stored in Terraform
# -----------------------------------------------------------------------------

variable "key_vault_id" {
  description = "Resource ID of the Key Vault holding the agent's PAT. The VM's managed identity is granted Key Vault Secrets User on this scope."
  type        = string
}

variable "key_vault_uri" {
  description = "Vault URI (https://<name>.vault.azure.net/), resolved privately from the agent subnet. Used by cloud-init to fetch the PAT secret."
  type        = string
}

variable "pat_secret_name" {
  description = "Name of the Key Vault secret holding the Azure DevOps agent pool PAT. The secret itself is created out-of-band (az keyvault secret set) — never by Terraform — so its value never enters state or source control."
  type        = string
  default     = "ado-agent-pat"
}

# -----------------------------------------------------------------------------
# Azure DevOps agent registration
# -----------------------------------------------------------------------------

variable "devops_org_url" {
  description = "Azure DevOps organisation URL, e.g. https://dev.azure.com/<org>."
  type        = string
}

variable "devops_pool_name" {
  description = "Agent pool this VM registers into. Must match privatePoolName in pipelines/variables/common.yml."
  type        = string
  default     = "private-selfhosted-linux"
}

variable "agent_version" {
  description = "Azure Pipelines agent package version (vsts-agent-linux-x64)."
  type        = string
  default     = "4.248.0"
}

# -----------------------------------------------------------------------------
# Pinned tool versions — kept in sync with pipelines/variables/common.yml so
# the pipeline stages stop installing these fresh on every run.
# -----------------------------------------------------------------------------

variable "terraform_version" {
  description = "Terraform version to pre-install. Match pipelines/variables/common.yml terraformVersion."
  type        = string
  default     = "1.9.5"
}

variable "helm_version" {
  description = "Helm version to pre-install. Match pipelines/variables/common.yml helmVersion."
  type        = string
  default     = "3.16.2"
}

variable "kubectl_version" {
  description = "kubectl version to pre-install. Match pipelines/variables/common.yml kubectlVersion."
  type        = string
  default     = "1.30.5"
}

variable "trivy_version" {
  description = "Trivy version to pre-install. Match the version pinned in pipelines/templates/stage-security.yml and stage-build-image.yml."
  type        = string
  default     = "0.58.1"
}

variable "gitleaks_version" {
  description = "Gitleaks version to pre-install. Match the version pinned in pipelines/templates/stage-security.yml."
  type        = string
  default     = "8.21.2"
}

variable "kubeconform_version" {
  description = "kubeconform version to pre-install. Match the version pinned in pipelines/templates/stage-validate.yml."
  type        = string
  default     = "0.6.7"
}

# -----------------------------------------------------------------------------
# Diagnostics
# -----------------------------------------------------------------------------

variable "enable_diagnostics" {
  description = "Install the Azure Monitor agent and send VM logs/metrics to Log Analytics."
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Workspace for diagnostics and the Azure Monitor agent. Required when enable_diagnostics is true."
  type        = string
  default     = ""
}
