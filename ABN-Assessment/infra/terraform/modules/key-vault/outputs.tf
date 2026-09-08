output "id" {
  description = "Resource ID of the Key Vault."
  value       = azurerm_key_vault.kv.id
}

output "name" {
  description = "Key Vault name."
  value       = azurerm_key_vault.kv.name
}

output "vault_uri" {
  description = "Vault URI. Resolves to a private IP inside the linked VNets."
  value       = azurerm_key_vault.kv.vault_uri
}
