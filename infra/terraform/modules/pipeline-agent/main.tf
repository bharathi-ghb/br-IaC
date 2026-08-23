# =============================================================================
# Self-hosted Azure Pipelines agent — Linux VM in rg_infra
# ---------------------------------------------------------------------------

# THE AGENT VM'S OWN IDENTITY - deliberately almost powerless.
#
# Its ONLY permission is Key Vault Secrets User (below), so it can read its own
# registration PAT at boot and do NOTHING else. It cannot deploy, cannot reach ACR as
# itself, cannot touch AKS.
#
# The DEPLOYMENT identity is entirely separate: the Azure DevOps service connection,
# which uses workload identity federation and therefore has NO stored secret at all.
# That separation is the point - compromising this host yields a PAT scoped to agent
# pools, not a path into the subscription.
#
# HONEST RESIDUAL RISK worth volunteering: an attacker on this host would also get the
# currently-running job's OIDC token for its lifetime, and the azdevops user is in the
# docker group, which is root-equivalent. That is the argument for ephemeral, per-job
# agents - which removes the long-lived host, the PAT, and cross-build state leakage in
# a single change.
resource "azurerm_user_assigned_identity" "agent" {
  name                = "id-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "agent_kv_secrets_user" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
}

# NO PUBLIC IP. Note there is no azurerm_public_ip resource anywhere in this module.
#
# The agent does not need one: its connection to Azure DevOps is AGENT-INITIATED
# OUTBOUND LONG-POLLING on 443. Azure DevOps never dials in, so there is no inbound
# rule and no listener to attack.
#
# Administrative access is via 'az ssh vm' using the AADSSHLoginForLinux extension
# below - so SSH is governed by Entra Conditional Access and MFA rather than by a key
# file sitting on someone's laptop.
resource "azurerm_network_interface" "agent" {
  name                = "nic-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

# ---------------------------------------------------------------------------
# Virtual machine
# ---------------------------------------------------------------------------

# THE AGENT VM. This exists because of the assessment's explicit 'pipeline networking
# requirement': Microsoft-hosted agents cannot reach a private endpoint. They run in
# Microsoft's network with no route to snet-private-endpoints and no link to our private
# DNS zones, so acr*.azurecr.io resolves to a public IP and the connection is refused.
#
# disable_password_authentication = true - key-based only, and even then the intended
# path is Entra SSH login rather than the local admin account.
#
# ignore_changes = [custom_data] - cloud-init only runs on FIRST boot, so changing the
# template would show a perpetual diff and, worse, tempt a replacement that silently
# re-registers the agent. Version changes should go through a rebuilt image instead.
#
# KNOWN GAP (docs/02 P2-10): this is a SINGLE VM with availability_zone defaulting to
# null. If it dies you cannot deploy OR roll back - precisely when you most need to.
# In order of preference the fix is: a VMSS across zones, Azure DevOps Managed DevOps
# Pools, or KEDA-scaled agent PODS in AKS with Workload Identity and no PAT at all.
resource "azurerm_linux_virtual_machine" "agent" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
  size                = var.vm_size
  zone                = var.availability_zone

  network_interface_ids = [azurerm_network_interface.agent.id]

  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.agent.id]
  }

  os_disk {
    caching               = "ReadWrite"
    storage_account_type  = var.os_disk_type
    disk_size_gb          = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  boot_diagnostics {}

  custom_data = base64encode(templatefile("${path.module}/scripts/cloud-init.sh.tftpl", {
    key_vault_uri       = var.key_vault_uri
    pat_secret_name     = var.pat_secret_name
    devops_org_url      = var.devops_org_url
    devops_pool_name    = var.devops_pool_name
    agent_version       = var.agent_version
    terraform_version   = var.terraform_version
    helm_version        = var.helm_version
    kubectl_version     = var.kubectl_version
    trivy_version       = var.trivy_version
    gitleaks_version    = var.gitleaks_version
    kubeconform_version = var.kubeconform_version
  }))

  lifecycle {
    ignore_changes = [custom_data]
  }

  depends_on = [azurerm_role_assignment.agent_kv_secrets_user]
}

resource "azurerm_virtual_machine_extension" "aad_ssh_login" {
  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.agent.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  tags                       = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "agent_vm" {
  for_each = var.enable_diagnostics ? toset(["agent_vm"]) : toset([])

  name                       = "agent-vm-diagnostics-to-law"
  target_resource_id         = azurerm_linux_virtual_machine.agent.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_metric {
    category = "AllMetrics"
  }
}
