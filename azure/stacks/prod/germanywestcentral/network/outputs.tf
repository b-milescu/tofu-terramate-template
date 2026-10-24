output "vnet_id" {
  description = "ID of the virtual network."
  value       = azurerm_virtual_network.main.id
}

output "subnet_ids" {
  description = "IDs of the private subnets by subnet name."
  value       = { for s in azurerm_subnet.private : s.name => s.id }
}

output "network_security_group_id" {
  description = "ID of the network security group attached to every private subnet."
  value       = azurerm_network_security_group.private.id
}
