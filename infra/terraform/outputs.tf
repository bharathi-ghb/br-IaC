
output "firewall_public_ip" {
  description = "The platform's single egress IP address."
  value       = module.network_hub.firewall_public_ip
}
