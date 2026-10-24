locals {
  vnet_cidr = "10.10.0.0/16"
  # Subnet name suffix => index of its /24 in the VNet.
  subnets = { app = 0, data = 1 }
}

resource "azurerm_resource_group" "network" {
  name     = "rg-${local.tags.Project}-network-${local.location}"
  location = local.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-main"
  location            = local.location
  resource_group_name = azurerm_resource_group.network.name
  address_space       = [local.vnet_cidr]
  tags                = local.tags
}

# Default rules only: Azure denies inbound traffic from the internet. Add rules per workload.
resource "azurerm_network_security_group" "private" {
  name                = "nsg-private"
  location            = local.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.tags
}

resource "azurerm_subnet" "private" {
  for_each = local.subnets

  name                            = "snet-${each.key}"
  resource_group_name             = azurerm_resource_group.network.name
  virtual_network_name            = azurerm_virtual_network.main.name
  address_prefixes                = [cidrsubnet(local.vnet_cidr, 8, each.value)]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet_network_security_group_association" "private" {
  for_each = local.subnets

  subnet_id                 = azurerm_subnet.private[each.key].id
  network_security_group_id = azurerm_network_security_group.private.id
}
