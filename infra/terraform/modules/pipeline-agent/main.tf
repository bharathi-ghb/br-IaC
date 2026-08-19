# =============================================================================
# Self-hosted Azure Pipelines agent — Linux VM in rg_infra
# ---------------------------------------------------------------------------

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
