terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# Get operator IP automatically
data "http" "operator_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  operator_cidr = var.operator_ip != "" ? var.operator_ip : "${chomp(data.http.operator_ip.response_body)}/32"
  common_tags = {
    Project     = "avalanche-l1"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

#
# RESOURCE GROUP
#

resource "azurerm_resource_group" "main" {
  name     = "${var.name_prefix}-rg"
  location = var.location

  tags = local.common_tags
}

#
# NETWORKING
#

resource "azurerm_virtual_network" "main" {
  name                = "${var.name_prefix}-vnet"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}

resource "azurerm_subnet" "main" {
  name                 = "${var.name_prefix}-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_cidr]
}

#
# NETWORK SECURITY GROUPS
#

resource "azurerm_network_security_group" "validators" {
  name                = "${var.name_prefix}-validators-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = local.operator_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AvalancheAPI"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9650"
    source_address_prefix      = local.operator_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AvalancheP2P"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9651"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = local.common_tags
}

resource "azurerm_network_security_group" "rpc" {
  name                = "${var.name_prefix}-rpc-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = local.operator_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AvalancheRPC"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9650"
    source_address_prefix      = var.enable_public_rpc ? "*" : local.operator_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AvalancheP2P"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9651"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "BlockscoutAPI"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "4000"
    source_address_prefix      = var.enable_public_blockscout ? "*" : local.operator_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "BlockscoutFrontend"
    priority                   = 140
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "4001"
    source_address_prefix      = var.enable_public_blockscout ? "*" : local.operator_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "BlockscoutStats"
    priority                   = 150
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8050"
    source_address_prefix      = var.enable_public_blockscout ? "*" : local.operator_cidr
    destination_address_prefix = "*"
  }

  tags = local.common_tags
}

resource "azurerm_network_security_group" "monitoring" {
  name                = "${var.name_prefix}-monitoring-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = local.operator_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Grafana"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3000"
    source_address_prefix      = var.enable_public_grafana ? "*" : local.operator_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Prometheus"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9090"
    source_address_prefix      = local.operator_cidr
    destination_address_prefix = "*"
  }

  tags = local.common_tags
}

#
# PUBLIC IPS
#

resource "azurerm_public_ip" "validators" {
  count               = var.validator_count
  name                = "${var.name_prefix}-validator-${count.index + 1}-ip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = local.common_tags
}

resource "azurerm_public_ip" "rpc" {
  count               = var.rpc_count
  name                = "${var.name_prefix}-rpc-${count.index + 1}-ip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = local.common_tags
}

#
# NETWORK INTERFACES
#

resource "azurerm_network_interface" "validators" {
  count               = var.validator_count
  name                = "${var.name_prefix}-validator-${count.index + 1}-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.validators[count.index].id
  }

  tags = local.common_tags
}

resource "azurerm_network_interface" "rpc" {
  count               = var.rpc_count
  name                = "${var.name_prefix}-rpc-${count.index + 1}-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.rpc[count.index].id
  }

  tags = local.common_tags
}

#
# NSG ASSOCIATIONS
#

resource "azurerm_network_interface_security_group_association" "validators" {
  count                     = var.validator_count
  network_interface_id      = azurerm_network_interface.validators[count.index].id
  network_security_group_id = azurerm_network_security_group.validators.id
}

resource "azurerm_network_interface_security_group_association" "rpc" {
  count                     = var.rpc_count
  network_interface_id      = azurerm_network_interface.rpc[count.index].id
  network_security_group_id = azurerm_network_security_group.rpc.id
}

#
# VIRTUAL MACHINES - VALIDATORS
#

resource "azurerm_linux_virtual_machine" "validators" {
  count               = var.validator_count
  name                = "${var.name_prefix}-validator-${count.index + 1}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = var.validator_vm_size
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.validators[count.index].id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  tags = merge(local.common_tags, {
    Role = "validator"
  })
}

#
# VIRTUAL MACHINES - RPC
#

resource "azurerm_linux_virtual_machine" "rpc" {
  count               = var.rpc_count
  name                = "${var.name_prefix}-rpc-${count.index + 1}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = var.rpc_vm_size
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.rpc[count.index].id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  tags = merge(local.common_tags, {
    Role = "rpc"
  })
}

#
# MONITORING SERVER
#

resource "azurerm_public_ip" "monitoring" {
  name                = "${var.name_prefix}-monitoring-ip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = local.common_tags
}

resource "azurerm_network_interface" "monitoring" {
  name                = "${var.name_prefix}-monitoring-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.monitoring.id
  }

  tags = local.common_tags
}

resource "azurerm_network_interface_security_group_association" "monitoring" {
  network_interface_id      = azurerm_network_interface.monitoring.id
  network_security_group_id = azurerm_network_security_group.monitoring.id
}

resource "azurerm_linux_virtual_machine" "monitoring" {
  name                = "${var.name_prefix}-monitoring"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = var.monitoring_vm_size
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.monitoring.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = var.monitoring_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  tags = merge(local.common_tags, {
    Role = "monitoring"
  })
}
