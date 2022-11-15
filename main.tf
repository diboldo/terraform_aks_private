# https://github.com/patuzov/terraform-private-aks

terraform {
 required_version = ">= 0.12"

#To azure can save the Terraform state file into the azure storage account.
backend "azurerm" {
    resource_group_name  = "rg-aks-internal-westus2-003"
    storage_account_name = "sainternalakstf"
    container_name       = "tfstate"
    key                  = "sainternalakstf.blob.core.windows.net.tfstate"
  
}
}

provider "azurerm" {
  version = "~>2.60" //outbound_type https://github.com/terraform-providers/terraform-provider-azurerm/blob/v2.5.0/CHANGELOG.md 
  features {}
}


resource "azurerm_resource_group" "vnet" {
  name     = var.vnet_resource_group_name
  location = var.location
}

resource "azurerm_resource_group" "kube" {
  name     = var.kube_resource_group_name
  location = var.location
}

module "hub_network" {
  source              = "./modules/vnet"
  resource_group_name = azurerm_resource_group.vnet.name
  location            = var.location
  vnet_name           = var.hub_vnet_name
  address_space       = ["10.0.0.0/22"]
  subnets = [
    {
      name : "AzureFirewallSubnet"
      address_prefixes : ["10.0.0.0/24"]
    },
    {
      name : "jumpbox-subnet"
      address_prefixes : ["10.0.1.0/24"]
    }
  ]
}

module "kube_network" {
  source              = "./modules/vnet"
  resource_group_name = azurerm_resource_group.kube.name
  location            = var.location
  vnet_name           = var.kube_vnet_name
  address_space       = ["10.0.4.0/22"]
  subnets = [
    {
      name : "aks-subnet"
      address_prefixes : ["10.0.5.0/24"]
    }
  ]
}

module "vnet_peering" {
  source              = "./modules/vnet_peering"
  vnet_1_name         = var.hub_vnet_name
  vnet_1_id           = module.hub_network.vnet_id
  vnet_1_rg           = azurerm_resource_group.vnet.name
  vnet_2_name         = var.kube_vnet_name
  vnet_2_id           = module.kube_network.vnet_id
  vnet_2_rg           = azurerm_resource_group.kube.name
  peering_name_1_to_2 = "HubToAks-Internal"
  peering_name_2_to_1 = "Aks-InternalToHub"
}

module "firewall" {
  source         = "./modules/firewall"
  resource_group = azurerm_resource_group.vnet.name
  location       = var.location
  pip_name       = "azureFirewalls-ip"
  fw_name        = "kubenetfw"
  subnet_id      = module.hub_network.subnet_ids["AzureFirewallSubnet"]
}

module "routetable" {
  source             = "./modules/route_table"
  resource_group     = azurerm_resource_group.vnet.name
  location           = var.location
  rt_name            = "kubenetfw_fw_rt"
  r_name             = "kubenetfw_fw_r"
  firewal_private_ip = module.firewall.fw_private_ip
  subnet_id          = module.kube_network.subnet_ids["aks-subnet"]
}

data "azurerm_kubernetes_service_versions" "current" {
  location       = var.location
  version_prefix = var.kube_version_prefix
}

resource "azurerm_kubernetes_cluster" "privateaks" {
  name                    = "private-aks"
  location                = var.location
  kubernetes_version      = data.azurerm_kubernetes_service_versions.current.latest_version
  resource_group_name     = azurerm_resource_group.kube.name
  dns_prefix              = "private-aks"
  private_cluster_enabled = true

  default_node_pool {
    name           = "default"
    node_count     = var.nodepool_nodes_count
    vm_size        = var.nodepool_vm_size
    vnet_subnet_id = module.kube_network.subnet_ids["aks-subnet"]
    availability_zones             =["1","2","3"] 
    enable_auto_scaling            = true
      max_count                    = 50
      min_count                    = 3
      max_pods                     = 20
         
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    docker_bridge_cidr = var.network_docker_bridge_cidr
    dns_service_ip     = var.network_dns_service_ip
    network_plugin     = "azure"
    outbound_type      = "userDefinedRouting"
    service_cidr       = var.network_service_cidr
  }

  depends_on = [module.routetable]
  
}

/*resource "azurerm_kubernetes_cluster_node_pool" "usernodepool" {
  name                  = "usernodepool"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.privateaks.id
  vm_size               = "Standard_DS2_v2"
  node_count            = 1

  #depends_on = [azurerm_kubernetes_cluster.privateaks]
}*/

#create node pool
resource "azurerm_kubernetes_cluster_node_pool" "privateaks" {
  name                         = "user1pool"
  kubernetes_cluster_id        = azurerm_kubernetes_cluster.privateaks.id
  node_count                   = var.nodepool_nodes_count
  vm_size                      = var.nodepool_vm_size
  vnet_subnet_id               = module.kube_network.subnet_ids["aks-subnet"]
  availability_zones           = ["1","2","3"]
  enable_auto_scaling          = true
  max_count                    = 50
  min_count                    = 3
  max_pods                     = 20
  os_disk_type                 = "Managed"
  mode                         = "User"
  
  depends_on = [azurerm_kubernetes_cluster.privateaks]
}


#module to create node pool
/*module "node_pool" {
  source = "./modules/node_pool"
  resource_group_name = azurerm_resource_group.private-aks-internal
  kubernetes_cluster_id =privateaks_cluster.id
  name                         = var.additional_node_pool_name
  vm_size                      = var.additional_node_pool_vm_size
  mode                         = var.additional_node_pool_mode
  availability_zones           = var.additional_node_pool_availability_zones
  vnet_subnet_id               = module.kube_network.subnet_ids["aks-subnet"][var.additional_node_pool_subnet_name]
  enable_auto_scaling          = var.additional_node_pool_enable_auto_scaling
  enable_host_encryption       = var.additional_node_pool_enable_host_encryption
  enable_node_public_ip        = var.additional_node_pool_enable_node_public_ip
  max_pods                     = var.additional_node_pool_max_pods
  max_count                    = var.additional_node_pool_max_count
  min_count                    = var.additional_node_pool_min_count
  node_count                   = var.additional_node_pool_node_count
  os_type                      = var.additional_node_pool_os_type
 
  depends_on                   = [module.routetable]
}*/

resource "azurerm_role_assignment" "netcontributor" {
  role_definition_name = "Network Contributor"
  scope                = module.kube_network.subnet_ids["aks-subnet"]
  principal_id         = azurerm_kubernetes_cluster.privateaks.identity[0].principal_id
}




module "jumpbox" {
  source                  = "./modules/jumpbox"
  location                = var.location
  resource_group          = azurerm_resource_group.vnet.name
  vnet_id                 = module.hub_network.vnet_id
  subnet_id               = module.hub_network.subnet_ids["jumpbox-subnet"]
  dns_zone_name           = join(".", slice(split(".", azurerm_kubernetes_cluster.privateaks.private_fqdn), 1, length(split(".", azurerm_kubernetes_cluster.privateaks.private_fqdn))))
  dns_zone_resource_group = azurerm_kubernetes_cluster.privateaks.node_resource_group
}


/*module "bastion_host" {
  source                       = "./modules/bastion_host"
  name                         = var.bastion_host_name
  location                     = var.location
  resource_group_name          = azurerm_resource_group.rg.name
  subnet_id                    = module.hub_network.subnet_ids["AzureBastionSubnet"]
  
}*/
