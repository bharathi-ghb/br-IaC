output "id" {
  description = "Resource ID of the storage account."
  value       = azurerm_storage_account.sa.id
}

output "name" {
  description = "Storage account name."
  value       = azurerm_storage_account.sa.name
}

output "blob_endpoint" {
  description = "Primary blob endpoint. Resolves to a private IP."
  value       = azurerm_storage_account.sa.primary_blob_endpoint
}

output "cache_container_name" {
  description = "Name of the cache container."
  value       = azurerm_storage_container.cache.name
}
