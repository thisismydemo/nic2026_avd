# lz-avd — AVD landing zone, Terraform track (parity with bicep/main.bicep; design/avd/landing-zone.md).
# AVM modules where verified (versions pinned, see README); azurerm/azapi resources where no AVM module exists.

data "azurerm_subscription" "current" {}

locals {
  subscription_scope = data.azurerm_subscription.current.id

  hub_vnet_segments = split("/", var.hub_vnet_id)
  hub_vnet_name     = element(local.hub_vnet_segments, length(local.hub_vnet_segments) - 1)
  azl_vnet_segments = split("/", var.azl_spoke_vnet_id)
  azl_vnet_name     = element(local.azl_vnet_segments, length(local.azl_vnet_segments) - 1)

  create_file_zone = var.enable_private_endpoints && var.privatelink_file_zone_id == ""
  file_zone_id     = local.create_file_zone ? module.privatelink_file_zone[0].resource_id : (var.enable_private_endpoints ? var.privatelink_file_zone_id : "")

  resource_group_names = {
    control = var.names["rg_control"]
    net     = var.names["rg_net"]
    hosts   = var.names["rg_hosts"]
    img     = var.names["rg_img"]
    stor    = var.names["rg_stor"]
    mon     = var.names["rg_mon"]
    arc     = var.names["rg_arc"]
  }

  diag = {
    lab = { workspace_resource_id = var.log_analytics_workspace_id }
  }

  shortpath_sources = concat([var.p2s_pool], var.onprem_compute_prefixes)
  smb_sources       = concat([var.avd_subnets.hosts, var.azl_spoke_prefix], var.onprem_compute_prefixes)

  share_list = {
    profiles = var.share_names.profiles
    odfc     = var.share_names.odfc
  }

  storage_suffix = "file.core.windows.net"
}

# ---------------------------------------------------------------------------------------------------------------------
# 1. Resource groups — AVM avm-res-resources-resourcegroup 0.4.0 (design §3)
# ---------------------------------------------------------------------------------------------------------------------
module "resource_groups" {
  source   = "Azure/avm-res-resources-resourcegroup/azurerm"
  version  = "0.4.0"
  for_each = local.resource_group_names

  name             = each.value
  location         = var.location
  tags             = var.tags
  enable_telemetry = false
}

# ---------------------------------------------------------------------------------------------------------------------
# 2. Network — NSGs (avm-res-network-networksecuritygroup 0.5.2), VNet (avm-res-network-virtualnetwork 0.22.2)
# ---------------------------------------------------------------------------------------------------------------------
module "nsg_hosts" {
  source  = "Azure/avm-res-network-networksecuritygroup/azurerm"
  version = "0.5.2"

  name                = var.names["nsg_hosts"]
  location            = var.location
  resource_group_name = module.resource_groups["net"].name
  tags                = var.tags
  enable_telemetry    = false
  diagnostic_settings = local.diag

  security_rules = {
    shortpath_in = {
      name                       = "AllowShortpathManagedInbound"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Udp"
      source_address_prefixes    = local.shortpath_sources
      source_port_range          = "*"
      destination_address_prefix = var.avd_subnets.hosts
      destination_port_range     = "3390"
      description                = "RDP Shortpath for managed networks from the presenter P2S pool and on-prem clients"
    }
    admin_rdp_in = {
      name                       = "AllowAdminRdpInbound"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefixes    = [var.bastion_subnet_prefix, var.azl_spoke_prefix]
      source_port_range          = "*"
      destination_address_prefix = var.avd_subnets.hosts
      destination_port_range     = "3389"
    }
    lb_in = {
      name                       = "AllowAzureLoadBalancerInbound"
      priority                   = 120
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_address_prefix      = "AzureLoadBalancer"
      source_port_range          = "*"
      destination_address_prefix = "*"
      destination_port_range     = "*"
    }
    deny_in = {
      name                       = "DenyAllInbound"
      priority                   = 4000
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_address_prefix      = "*"
      source_port_range          = "*"
      destination_address_prefix = "*"
      destination_port_range     = "*"
    }
    avd_out = {
      name                       = "AllowAvdServiceOutbound"
      priority                   = 100
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = "*"
      source_port_range          = "*"
      destination_address_prefix = "WindowsVirtualDesktop"
      destination_port_range     = "443"
    }
    entra_out = {
      name                       = "AllowEntraOutbound"
      priority                   = 110
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = "*"
      source_port_range          = "*"
      destination_address_prefix = "AzureActiveDirectory"
      destination_port_range     = "443"
    }
    monitor_out = {
      name                       = "AllowMonitorOutbound"
      priority                   = 120
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = "*"
      source_port_range          = "*"
      destination_address_prefix = "AzureMonitor"
      destination_port_range     = "443"
    }
    storage_out = {
      name                       = "AllowStorageOutbound"
      priority                   = 130
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = "*"
      source_port_range          = "*"
      destination_address_prefix = "Storage"
      destination_port_range     = "443"
    }
    frontdoor_out = {
      name                       = "AllowFrontDoorOutbound"
      priority                   = 140
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = "*"
      source_port_range          = "*"
      destination_address_prefix = "AzureFrontDoor.Frontend"
      destination_port_range     = "443"
    }
    turn_out = {
      name                       = "AllowShortpathTurnOutbound"
      priority                   = 150
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Udp"
      source_address_prefix      = "*"
      source_port_range          = "*"
      destination_address_prefix = "WindowsVirtualDesktop"
      destination_port_range     = "3478"
    }
    stun_out = {
      name                       = "AllowShortpathStunOutbound"
      priority                   = 160
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Udp"
      source_address_prefix      = "*"
      source_port_range          = "*"
      destination_address_prefix = "Internet"
      destination_port_range     = "49152-65535"
    }
    smb_out = {
      name                       = "AllowSmbToPrivateEndpointOutbound"
      priority                   = 170
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = "*"
      source_port_range          = "*"
      destination_address_prefix = var.avd_subnets.pe
      destination_port_range     = "445"
    }
    smb_storage_out = {
      # D-029: the FSLogix share is reached on its public endpoint, so SMB must be allowed to the Storage service tag
      name                       = "AllowSmbToStorageOutbound"
      priority                   = 175
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = "*"
      source_port_range          = "*"
      destination_address_prefix = "Storage"
      destination_port_range     = "445"
    }
    kms_out = {
      name                       = "AllowKmsOutbound"
      priority                   = 180
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = "*"
      source_port_range          = "*"
      destination_address_prefix = "Internet"
      destination_port_range     = "1688"
    }
    web_out = {
      name                       = "AllowWebOutbound"
      priority                   = 190
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = "*"
      source_port_range          = "*"
      destination_address_prefix = "Internet"
      destination_port_ranges    = ["80", "443"]
    }
    deny_internet_out = {
      name                       = "DenyInternetOutbound"
      priority                   = 4000
      direction                  = "Outbound"
      access                     = "Deny"
      protocol                   = "*"
      source_address_prefix      = "*"
      source_port_range          = "*"
      destination_address_prefix = "Internet"
      destination_port_range     = "*"
    }
  }
}

module "nsg_pe" {
  source  = "Azure/avm-res-network-networksecuritygroup/azurerm"
  version = "0.5.2"

  name                = var.names["nsg_pe"]
  location            = var.location
  resource_group_name = module.resource_groups["net"].name
  tags                = var.tags
  enable_telemetry    = false
  diagnostic_settings = local.diag

  security_rules = {
    smb_in = {
      name                       = "AllowSmbInbound"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefixes    = local.smb_sources
      source_port_range          = "*"
      destination_address_prefix = var.avd_subnets.pe
      destination_port_range     = "445"
    }
    deny_in = {
      name                       = "DenyAllInbound"
      priority                   = 4000
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_address_prefix      = "*"
      source_port_range          = "*"
      destination_address_prefix = "*"
      destination_port_range     = "*"
    }
  }
}

module "nsg_imgbuild" {
  source  = "Azure/avm-res-network-networksecuritygroup/azurerm"
  version = "0.5.2"

  name                = var.names["nsg_imgbuild"]
  location            = var.location
  resource_group_name = module.resource_groups["net"].name
  tags                = var.tags
  enable_telemetry    = false
  diagnostic_settings = local.diag

  security_rules = {
    aib_proxy_in = {
      name                       = "AllowImageBuilderProxyInbound"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = "AzureLoadBalancer"
      source_port_range          = "*"
      destination_address_prefix = var.avd_subnets.imgbuild
      destination_port_range     = "60000-60001"
    }
    deny_in = {
      name                       = "DenyAllInbound"
      priority                   = 4000
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_address_prefix      = "*"
      source_port_range          = "*"
      destination_address_prefix = "*"
      destination_port_range     = "*"
    }
  }
}

# Explicit outbound path: every subnet has default outbound access disabled and the spoke has no firewall or route table, so the
# host and image-build subnets egress through one NAT gateway (the AVD service, Entra ID, Azure Monitor, Storage and Windows
# activation are public endpoints). Same shape as the Bicep track.
resource "azurerm_public_ip" "nat" {
  name                = var.names["pip_nat"]
  location            = var.location
  resource_group_name = module.resource_groups["net"].name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "avd" {
  name                    = var.names["nat_gateway"]
  location                = var.location
  resource_group_name     = module.resource_groups["net"].name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 30
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "avd" {
  nat_gateway_id       = azurerm_nat_gateway.avd.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

module "spoke_vnet" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "0.22.2"

  name                = var.names["spoke_vnet"]
  location            = var.location
  parent_id           = module.resource_groups["net"].resource_id
  address_space       = [var.avd_vnet_prefix]
  tags                = var.tags
  enable_telemetry    = false
  diagnostic_settings = local.diag

  subnets = {
    hosts = {
      name                            = var.names["subnet_hosts"]
      address_prefixes                = [var.avd_subnets.hosts]
      network_security_group          = { id = module.nsg_hosts.resource_id }
      nat_gateway                     = { id = azurerm_nat_gateway.avd.id }
      default_outbound_access_enabled = false
    }
    pe = {
      name                              = var.names["subnet_pe"]
      address_prefixes                  = [var.avd_subnets.pe]
      network_security_group            = { id = module.nsg_pe.resource_id }
      private_endpoint_network_policies = "Enabled"
      default_outbound_access_enabled   = false
    }
    imgbuild = {
      name                                          = var.names["subnet_imgbuild"]
      address_prefixes                              = [var.avd_subnets.imgbuild]
      network_security_group                        = { id = module.nsg_imgbuild.resource_id }
      private_link_service_network_policies_enabled = false
      nat_gateway                                   = { id = azurerm_nat_gateway.avd.id }
      default_outbound_access_enabled               = false
    }
    dnsin = {
      name                            = var.names["subnet_dnsin"]
      address_prefixes                = [var.avd_subnets.dnsin]
      default_outbound_access_enabled = false
      delegations = [{
        name               = "Microsoft.Network.dnsResolvers"
        service_delegation = { name = "Microsoft.Network/dnsResolvers" }
      }]
    }
  }
}

# 2a. Peerings — azapi so both the hub side (connectivity subscription) and the Azure Local side are created by one
# provider; hub side first (gateway transit must exist before useRemoteGateways is accepted).
resource "azapi_resource" "peer_hub_to_spoke" {
  type      = "Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01"
  name      = var.names["peer_hub_to_spoke"]
  parent_id = var.hub_vnet_id

  body = {
    properties = {
      remoteVirtualNetwork      = { id = module.spoke_vnet.resource_id }
      allowVirtualNetworkAccess = true
      allowForwardedTraffic     = true
      allowGatewayTransit       = true
      useRemoteGateways         = false
    }
  }
}

resource "azapi_resource" "peer_spoke_to_hub" {
  type      = "Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01"
  name      = var.names["peer_spoke_to_hub"]
  parent_id = module.spoke_vnet.resource_id

  body = {
    properties = {
      remoteVirtualNetwork      = { id = var.hub_vnet_id }
      allowVirtualNetworkAccess = true
      allowForwardedTraffic     = true
      allowGatewayTransit       = false
      useRemoteGateways         = true
    }
  }

  depends_on = [azapi_resource.peer_hub_to_spoke]
}

resource "azapi_resource" "peer_azl_to_spoke" {
  type      = "Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01"
  name      = var.names["peer_azl_to_spoke"]
  parent_id = var.azl_spoke_vnet_id

  body = {
    properties = {
      remoteVirtualNetwork      = { id = module.spoke_vnet.resource_id }
      allowVirtualNetworkAccess = true
      allowForwardedTraffic     = true
      allowGatewayTransit       = false
      useRemoteGateways         = false
    }
  }
}

resource "azapi_resource" "peer_spoke_to_azl" {
  type      = "Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01"
  name      = var.names["peer_spoke_to_azl"]
  parent_id = module.spoke_vnet.resource_id

  body = {
    properties = {
      remoteVirtualNetwork      = { id = var.azl_spoke_vnet_id }
      allowVirtualNetworkAccess = true
      allowForwardedTraffic     = true
      allowGatewayTransit       = false
      useRemoteGateways         = false
    }
  }

  depends_on = [azapi_resource.peer_azl_to_spoke, azapi_resource.peer_spoke_to_hub]
}

# 2b. DNS Private Resolver — avm-res-network-dnsresolver 0.8.0, behind enable_dns_private_resolver (P-07)
module "dns_resolver" {
  source  = "Azure/avm-res-network-dnsresolver/azurerm"
  version = "0.8.0"
  count   = var.enable_private_endpoints && var.enable_dns_private_resolver ? 1 : 0

  name                        = var.names["dns_resolver"]
  location                    = var.location
  resource_group_name         = module.resource_groups["net"].name
  virtual_network_resource_id = module.spoke_vnet.resource_id
  tags                        = var.tags
  enable_telemetry            = false

  inbound_endpoints = {
    inbound = {
      name                         = var.names["dns_resolver_inbound"]
      subnet_name                  = var.names["subnet_dnsin"]
      private_ip_allocation_method = "Static"
      private_ip_address           = var.dns_resolver_inbound_ip
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# 3. Private DNS zone — avm-res-network-privatednszone 0.5.0 (design §4.5, P-11)
# ---------------------------------------------------------------------------------------------------------------------
module "privatelink_file_zone" {
  source  = "Azure/avm-res-network-privatednszone/azurerm"
  version = "0.5.0"
  count   = local.create_file_zone ? 1 : 0

  domain_name      = var.names["file_zone"]
  parent_id        = module.resource_groups["net"].resource_id
  tags             = var.tags
  enable_telemetry = false

  virtual_network_links = merge(
    {
      avd = {
        name                 = var.names["link_avd"]
        virtual_network_id   = module.spoke_vnet.resource_id
        registration_enabled = false
      }
      azl = {
        name                 = var.names["link_azl"]
        virtual_network_id   = var.azl_spoke_vnet_id
        registration_enabled = false
      }
      identity = {
        name                 = var.names["link_identity"]
        virtual_network_id   = var.identity_spoke_vnet_id
        registration_enabled = false
      }
    },
    var.link_privatelink_zone_to_hub ? {
      hub = {
        name                 = var.names["link_hub"]
        virtual_network_id   = var.hub_vnet_id
        registration_enabled = false
      }
    } : {}
  )
}

# ---------------------------------------------------------------------------------------------------------------------
# 4. Identities — avm-res-managedidentity-userassignedidentity 0.5.3 (design §5.2)
# ---------------------------------------------------------------------------------------------------------------------
module "hostpool_identity" {
  source  = "Azure/avm-res-managedidentity-userassignedidentity/azurerm"
  version = "0.5.3"

  name                = var.names["hostpool_identity"]
  location            = var.location
  resource_group_name = module.resource_groups["control"].name
  tags                = var.tags
  enable_telemetry    = false
}

module "aib_identity" {
  source  = "Azure/avm-res-managedidentity-userassignedidentity/azurerm"
  version = "0.5.3"

  name                = var.names["aib_identity"]
  location            = var.location
  resource_group_name = module.resource_groups["img"].name
  tags                = var.tags
  enable_telemetry    = false
}

# ---------------------------------------------------------------------------------------------------------------------
# 5. Profile storage — avm-res-storage-storageaccount 0.10.0 (design §7); backup — avm-res-recoveryservices-vault 1.3.2
# Entra Kerberos: azure_files_authentication.directory_type = AADKERB (cloud-only identities need no AD properties).
# What ARM cannot do (admin consent, kdc_enable_cloud_group_sids tag, privatelink identifierUri, CA exclusion) lives in
# scripts/Set-AvdStorageEntraKerberos.ps1.
# ---------------------------------------------------------------------------------------------------------------------
module "fslogix_storage" {
  source  = "Azure/avm-res-storage-storageaccount/azurerm"
  version = "0.10.0"

  name                       = var.names["fslogix_sa"]
  location                   = var.location
  parent_id                  = module.resource_groups["stor"].resource_id
  tags                       = var.tags
  enable_telemetry           = false
  account_kind               = "FileStorage"
  account_tier               = "Premium"
  account_replication_type   = "LRS"
  min_tls_version            = "TLS1_2"
  https_traffic_only_enabled = true
  # Azure Backup for Azure Files needs key access on the source account (Learn support matrix); the FSLogix path stays Kerberos-only.
  shared_access_key_enabled               = var.enable_backup
  allow_nested_items_to_be_public         = false
  cross_tenant_replication_enabled        = false
  default_to_oauth_authentication         = true
  public_network_access_enabled           = !var.enable_private_endpoints
  large_file_share_enabled                = null
  private_endpoints_manage_dns_zone_group = true

  network_rules = {
    default_action = var.enable_private_endpoints ? "Deny" : "Allow"
    bypass         = ["AzureServices"]
  }

  azure_files_authentication = {
    directory_type                 = "AADKERB"
    default_share_level_permission = "None"
  }

  file_service_properties = {
    share_retention_policy = {
      enabled = true
      days    = 14
    }
    smb = {
      versions                        = ["SMB3.1.1"]
      authentication_types            = ["Kerberos"]
      kerberos_ticket_encryption_type = ["AES-256"]
      channel_encryption_types        = ["AES-128-GCM", "AES-256-GCM"]
    }
  }

  shares = {
    for key, share in local.share_list : key => {
      name             = share
      quota            = var.share_quota_gib
      enabled_protocol = "SMB"
      access_tier      = "Premium"
      role_assignments = {
        users = {
          role_definition_id_or_name = "Storage File Data SMB Share Contributor"
          principal_id               = var.group_object_ids.avd_users
          principal_type             = "Group"
          description                = "FSLogix share-level permission for the union group (design §7.5)"
        }
        admins = {
          role_definition_id_or_name = "Storage File Data SMB Share Elevated Contributor"
          principal_id               = var.group_object_ids.avd_admins
          principal_type             = "Group"
          description                = "NTFS/ACL management (design §7.5)"
        }
      }
    }
  }

  private_endpoints = var.enable_private_endpoints ? {
    file = {
      name                          = var.names["fslogix_pe"]
      subnet_resource_id            = module.spoke_vnet.subnets["pe"].resource_id
      subresource_name              = "file"
      private_dns_zone_resource_ids = [local.file_zone_id]
      tags                          = var.tags
    }
  } : {}

  diagnostic_settings_storage_account = local.diag
  diagnostic_settings_file            = local.diag
}

module "recovery_vault" {
  source  = "Azure/avm-res-recoveryservices-vault/azurerm"
  version = "1.3.2"
  count   = var.enable_backup ? 1 : 0

  name                          = var.names["recovery_vault"]
  location                      = var.location
  resource_group_name           = module.resource_groups["stor"].name
  tags                          = var.tags
  enable_telemetry              = false
  sku                           = "Standard"
  storage_mode_type             = "LocallyRedundant"
  cross_region_restore_enabled  = false
  public_network_access_enabled = true
  diagnostic_settings           = local.diag

  file_share_backup_policy = {
    fslogix = {
      name            = var.names["backup_policy"]
      timezone        = "UTC"
      frequency       = "Daily"
      backup_tier     = "snapshot"
      retention_daily = var.backup_policy.retention_days
      backup          = { time = var.backup_policy.schedule_time_utc }
    }
  }

  backup_protected_file_share = {
    for key, share in local.share_list : key => {
      source_storage_account_id     = module.fslogix_storage.resource_id
      backup_file_share_policy_name = var.names["backup_policy"]
      source_file_share_name        = share
    }
  }

  depends_on = [module.fslogix_storage]
}

# ---------------------------------------------------------------------------------------------------------------------
# 6. Images — avm-res-compute-gallery 0.2.1 (design §8.1)
# ---------------------------------------------------------------------------------------------------------------------
module "gallery" {
  source  = "Azure/avm-res-compute-gallery/azurerm"
  version = "0.2.1"

  name                = var.names["gallery"]
  location            = var.location
  resource_group_name = module.resource_groups["img"].name
  description         = "AVD images for the three realms (multi-session for Azure and Azure Local, single-session for Hybrid)"
  tags                = var.tags
  enable_telemetry    = false

  role_assignments = {
    lab_operators_reader = {
      role_definition_id_or_name = "Reader"
      principal_id               = var.group_object_ids.lab_operators
      principal_type             = "Group"
    }
  }

  shared_image_definitions = {
    for def in var.image_definitions : def.name => {
      name                   = def.name
      identifier             = { publisher = def.publisher, offer = def.offer, sku = def.sku }
      os_type                = def.os_type
      hyper_v_generation     = def.hyper_v_generation
      architecture           = "x64"
      trusted_launch_enabled = def.security_type == "TrustedLaunch"
      specialized            = def.os_state == "Specialized"
      tags                   = var.tags
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# 7. Monitoring — avm-res-insights-datacollectionrule 0.1.0 (design §9.2); alerts via azurerm (no AVM module)
# ---------------------------------------------------------------------------------------------------------------------
locals {
  perf_counters_60s = [
    "\\LogicalDisk(C:)\\% Free Space",
    "\\LogicalDisk(C:)\\Avg. Disk Queue Length",
    "\\LogicalDisk(C:)\\Avg. Disk sec/Transfer",
    "\\LogicalDisk(C:)\\Current Disk Queue Length",
    "\\Memory\\Available Mbytes",
    "\\Memory\\Page Faults/sec",
    "\\Memory\\Pages/sec",
    "\\Memory\\% Committed Bytes In Use",
    "\\PhysicalDisk(*)\\Avg. Disk Queue Length",
    "\\PhysicalDisk(*)\\Avg. Disk sec/Read",
    "\\PhysicalDisk(*)\\Avg. Disk sec/Transfer",
    "\\PhysicalDisk(*)\\Avg. Disk sec/Write",
    "\\Processor Information(_Total)\\% Processor Time",
  ]
  perf_counters_30s = [
    "\\Terminal Services(*)\\Active Sessions",
    "\\Terminal Services(*)\\Inactive Sessions",
    "\\Terminal Services(*)\\Total Sessions",
    "\\User Input Delay per Process(*)\\Max Input Delay",
    "\\User Input Delay per Session(*)\\Max Input Delay",
    "\\RemoteFX Network(*)\\Current TCP RTT",
    "\\RemoteFX Network(*)\\Current UDP Bandwidth",
  ]
  event_xpaths = [
    "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]",
    "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]",
    "System!*[System[(Level=2 or Level=3)]]",
    "Application!*[System[(Level=2 or Level=3)]]",
    "Microsoft-FSLogix-Apps/Operational!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]",
    "Microsoft-FSLogix-Apps/Admin!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]",
  ]
  alerts = {
    hostunavailable = {
      name        = var.names["alert_hostunavailable"]
      description = "A session host has not reported Available for more than 10 minutes (silent hosts included: the look-back is one hour)"
      query       = "WVDAgentHealthStatus | where TimeGenerated > ago(1h) | summarize arg_max(TimeGenerated, *) by SessionHostName | where Status != \"Available\" or TimeGenerated < ago(10m)"
      severity    = 2
      window      = "PT1H"
    }
    fslogixerror = {
      name        = var.names["alert_fslogixerror"]
      description = "FSLogix error events (profile attach or detach failures) from the Operational and Admin channels"
      query       = "Event | where EventLog in (\"Microsoft-FSLogix-Apps/Operational\", \"Microsoft-FSLogix-Apps/Admin\") | where EventLevelName == \"Error\""
      severity    = 1
      window      = "PT15M"
    }
    connfail = {
      name        = var.names["alert_connfail"]
      description = "AVD connection failures reported by the service"
      query       = "WVDErrors | where ActivityType == \"Connection\""
      severity    = 2
      window      = "PT15M"
    }
  }
}

module "dcr_avd_insights" {
  source  = "Azure/avm-res-insights-datacollectionrule/azurerm"
  version = "0.1.0"

  name             = var.names["dcr_avd_insights"]
  location         = var.location
  parent_id        = module.resource_groups["mon"].resource_id
  kind             = "Windows"
  description      = "AVD Insights default counters and events for all three realms (Azure VMs and Arc machines)"
  tags             = var.tags
  enable_telemetry = false

  data_sources = {
    performance_counters = [
      {
        name                          = "avdInsightsPerf60"
        streams                       = ["Microsoft-Perf"]
        sampling_frequency_in_seconds = 60
        counter_specifiers            = local.perf_counters_60s
      },
      {
        name                          = "avdInsightsPerf30"
        streams                       = ["Microsoft-Perf"]
        sampling_frequency_in_seconds = 30
        counter_specifiers            = local.perf_counters_30s
      },
    ]
    windows_event_logs = [
      {
        name           = "avdInsightsEvents"
        streams        = ["Microsoft-Event"]
        x_path_queries = local.event_xpaths
      },
    ]
  }

  destinations = {
    log_analytics = [
      {
        name                  = "lawLab"
        workspace_resource_id = var.log_analytics_workspace_id
      },
    ]
  }

  data_flows = [
    {
      streams      = ["Microsoft-Perf", "Microsoft-Event"]
      destinations = ["lawLab"]
    },
  ]
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "avd" {
  for_each = local.alerts

  name                    = each.value.name
  resource_group_name     = module.resource_groups["mon"].name
  location                = var.location
  tags                    = var.tags
  description             = each.value.description
  severity                = each.value.severity
  enabled                 = true
  auto_mitigation_enabled = true
  evaluation_frequency    = "PT5M"
  window_duration         = each.value.window
  scopes                  = [var.log_analytics_workspace_id]

  criteria {
    query                   = each.value.query
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0

    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }

  action {
    action_groups = [var.action_group_id]
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# 8. Governance — budget (azurerm; no AVM Terraform budget module), policy (azurerm; definitions looked up by display name)
# ---------------------------------------------------------------------------------------------------------------------
resource "azurerm_consumption_budget_subscription" "avd" {
  name            = var.names["budget"]
  subscription_id = local.subscription_scope
  amount          = var.avd_budget_monthly
  time_grain      = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  dynamic "notification" {
    for_each = {
      actual50    = { threshold = 50, type = "Actual" }
      actual80    = { threshold = 80, type = "Actual" }
      actual100   = { threshold = 100, type = "Actual" }
      forecast100 = { threshold = 100, type = "Forecasted" }
    }
    content {
      enabled        = true
      operator       = "GreaterThanOrEqualTo"
      threshold      = notification.value.threshold
      threshold_type = notification.value.type
      contact_emails = [var.owner_email]
      contact_groups = [var.action_group_id]
    }
  }

  lifecycle {
    ignore_changes = [time_period]
  }
}

locals {
  governed_tags = ["project", "workload", "environment", "owner", "lifecycle"]
  policy_display_names = {
    allowed_locations       = "Allowed locations"
    require_tag_on_rg       = "Require a tag on resource groups"
    inherit_tag_from_rg     = "Inherit a tag from the resource group if missing"
    storage_public_access   = "Storage accounts should disable public network access"
    storage_secure_transfer = "Secure transfer to storage accounts should be enabled"
    nic_no_public_ip        = "Network interfaces should not have public IPs"
  }
}

data "azurerm_policy_definition" "builtin" {
  for_each     = var.enable_policy_assignments ? local.policy_display_names : {}
  display_name = each.value
}

resource "azurerm_subscription_policy_assignment" "allowed_locations" {
  count = var.enable_policy_assignments ? 1 : 0

  name                 = var.names["asg_allowed_locations"]
  display_name         = "AVD lab: allowed locations"
  subscription_id      = local.subscription_scope
  policy_definition_id = data.azurerm_policy_definition.builtin["allowed_locations"].id
  enforce              = true
  parameters = jsonencode({
    listOfAllowedLocations = { value = [var.location, "global"] }
  })
}

resource "azurerm_subscription_policy_assignment" "require_tags" {
  for_each = var.enable_policy_assignments ? toset(local.governed_tags) : toset([])

  name                 = "${var.names["asg_require_tags"]}-${each.key}"
  display_name         = "AVD lab: require tag ${each.key} on resource groups"
  subscription_id      = local.subscription_scope
  policy_definition_id = data.azurerm_policy_definition.builtin["require_tag_on_rg"].id
  enforce              = true
  parameters           = jsonencode({ tagName = { value = each.key } })
}

resource "azurerm_subscription_policy_assignment" "inherit_tags" {
  for_each = var.enable_policy_assignments ? toset(local.governed_tags) : toset([])

  name                 = "${var.names["asg_inherit_tags"]}-${each.key}"
  display_name         = "AVD lab: inherit tag ${each.key} from the resource group"
  subscription_id      = local.subscription_scope
  policy_definition_id = data.azurerm_policy_definition.builtin["inherit_tag_from_rg"].id
  location             = var.location
  enforce              = true
  parameters           = jsonencode({ tagName = { value = each.key } })

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "inherit_tags_identity" {
  for_each = var.enable_policy_assignments ? toset(local.governed_tags) : toset([])

  scope                = local.subscription_scope
  role_definition_name = "Tag Contributor"
  principal_id         = azurerm_subscription_policy_assignment.inherit_tags[each.key].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_subscription_policy_assignment" "storage_hygiene" {
  for_each = var.enable_policy_assignments ? { "1" = "storage_public_access", "2" = "storage_secure_transfer" } : {}

  name                 = "${var.names["asg_storage_hygiene"]}-${each.key}"
  display_name         = "AVD lab: storage hygiene (${each.key})"
  subscription_id      = local.subscription_scope
  policy_definition_id = data.azurerm_policy_definition.builtin[each.value].id
  enforce              = true
  parameters           = jsonencode({ effect = { value = "Audit" } })
}

resource "azurerm_resource_group_policy_assignment" "hosts_no_public_ip" {
  count = var.enable_policy_assignments ? 1 : 0

  name                 = var.names["asg_no_public_ip"]
  display_name         = "AVD lab: no public IPs on session hosts"
  resource_group_id    = module.resource_groups["hosts"].resource_id
  policy_definition_id = data.azurerm_policy_definition.builtin["nic_no_public_ip"].id
  enforce              = true
}

# ---------------------------------------------------------------------------------------------------------------------
# 9. RBAC — design §5.3 (azurerm_role_assignment by role name; custom AIB roles via azurerm_role_definition)
# ---------------------------------------------------------------------------------------------------------------------
resource "azurerm_role_definition" "aib_image" {
  name        = var.names["role_aib_image"]
  scope       = local.subscription_scope
  description = "Azure Image Builder: read the gallery and definitions, write image versions and managed images (lab)"

  permissions {
    actions = [
      "Microsoft.Compute/galleries/read",
      "Microsoft.Compute/galleries/images/read",
      "Microsoft.Compute/galleries/images/versions/read",
      "Microsoft.Compute/galleries/images/versions/write",
      "Microsoft.Compute/images/read",
      "Microsoft.Compute/images/write",
      "Microsoft.Compute/images/delete",
    ]
    not_actions = []
  }

  assignable_scopes = [module.resource_groups["img"].resource_id]
}

resource "azurerm_role_definition" "aib_network" {
  name        = var.names["role_aib_network"]
  scope       = local.subscription_scope
  description = "Azure Image Builder: join the image-build subnet of the AVD spoke (existing-VNet build)"

  permissions {
    actions = [
      "Microsoft.Network/virtualNetworks/read",
      "Microsoft.Network/virtualNetworks/subnets/join/action",
    ]
    not_actions = []
  }

  assignable_scopes = [module.resource_groups["net"].resource_id]
}

locals {
  role_assignments = merge(
    {
      hostpool_reader_arc  = { scope = module.resource_groups["arc"].resource_id, role = "Reader", principal = module.hostpool_identity.principal_id, type = "ServicePrincipal" }
      users_vmlogin_hosts  = { scope = module.resource_groups["hosts"].resource_id, role = "Virtual Machine User Login", principal = var.group_object_ids.avd_users, type = "Group" }
      users_vmlogin_arc    = { scope = module.resource_groups["arc"].resource_id, role = "Virtual Machine User Login", principal = var.group_object_ids.avd_users, type = "Group" }
      admins_vmadmin_hosts = { scope = module.resource_groups["hosts"].resource_id, role = "Virtual Machine Administrator Login", principal = var.group_object_ids.avd_admins, type = "Group" }
      admins_vmadmin_arc   = { scope = module.resource_groups["arc"].resource_id, role = "Virtual Machine Administrator Login", principal = var.group_object_ids.avd_admins, type = "Group" }
      admins_dv_contrib    = { scope = module.resource_groups["control"].resource_id, role = "Desktop Virtualization Contributor", principal = var.group_object_ids.avd_admins, type = "Group" }
      admins_dv_reader     = { scope = local.subscription_scope, role = "Desktop Virtualization Reader", principal = var.group_object_ids.avd_admins, type = "Group" }
    },
    var.arc_onboard_sp_object_id != "" ? {
      arc_onboarding = { scope = module.resource_groups["arc"].resource_id, role = "Azure Connected Machine Onboarding", principal = var.arc_onboard_sp_object_id, type = "ServicePrincipal" }
    } : {}
  )
}

resource "azurerm_role_assignment" "builtin" {
  for_each = local.role_assignments

  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = each.value.principal
  principal_type       = each.value.type
}

resource "azurerm_role_assignment" "aib_image" {
  scope              = module.resource_groups["img"].resource_id
  role_definition_id = azurerm_role_definition.aib_image.role_definition_resource_id
  principal_id       = module.aib_identity.principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "aib_network" {
  scope              = module.resource_groups["net"].resource_id
  role_definition_id = azurerm_role_definition.aib_network.role_definition_resource_id
  principal_id       = module.aib_identity.principal_id
  principal_type     = "ServicePrincipal"
}
