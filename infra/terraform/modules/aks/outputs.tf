output "id" {
  description = "Resource ID of the cluster."
  value       = azurerm_kubernetes_cluster.aks_cluster.id
}

output "name" {
  description = "Cluster name."
  value       = azurerm_kubernetes_cluster.aks_cluster.name
}

# The issuer URL is the trust anchor for Workload Identity: modules/identity uses it as
# the 'issuer' on the federated identity credential, and Entra fetches this URL's JWKS
# to verify the signature on the pod's projected token. It is public and
# unauthenticated, which is fine - it contains only public keys.
output "oidc_issuer_url" {
  description = "OIDC issuer URL. Used as the issuer when creating federated identity credentials for Workload Identity."
  value       = azurerm_kubernetes_cluster.aks_cluster.oidc_issuer_url
}

output "kubelet_identity_object_id" {
  description = "Object ID of the kubelet identity. This is the principal that needs AcrPull - not the control-plane identity."
  value       = azurerm_kubernetes_cluster.aks_cluster.kubelet_identity[0].object_id
}

output "control_plane_identity_principal_id" {
  description = "Principal ID of the control-plane user-assigned identity."
  value       = azurerm_user_assigned_identity.aks_identity.principal_id
}

output "private_fqdn" {
  description = "Private API server FQDN. Only resolvable from VNets linked to the AKS private DNS zone."
  value       = azurerm_kubernetes_cluster.aks_cluster.private_fqdn
}

output "node_resource_group" {
  description = "The AKS-managed node resource group name."
  value       = azurerm_kubernetes_cluster.aks_cluster.node_resource_group
}
