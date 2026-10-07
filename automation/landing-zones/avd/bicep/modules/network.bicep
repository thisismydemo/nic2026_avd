// lz-avd network — design/avd/landing-zone.md §4.1, §4.6, §4.5 (resolver behind enable_dns_private_resolver)
// Resource-group scope (rg-*-avd-net). Uses AVM network-security-group 0.5.3, virtual-network 0.10.2, dns-resolver 0.5.8.
targetScope = 'resourceGroup'

param location string
param tags object
param names object
param avd_vnet_prefix string
param avd_subnets object
param p2s_pool string
param onprem_compute_prefixes array
param admin_source_prefixes array
param azl_spoke_prefix string
param log_analytics_workspace_id string
param enable_dns_private_resolver bool
param dns_resolver_inbound_ip string

var diagnosticSettings = [
  {
    workspaceResourceId: log_analytics_workspace_id
  }
]

// Shortpath (managed networks) listener sources: the P2S pool and the narrowed on-prem client ranges (design §4.6)
var shortpathSources = concat([p2s_pool], onprem_compute_prefixes)
var smbSources = concat([avd_subnets.hosts, azl_spoke_prefix], onprem_compute_prefixes)

// ---------------------------------------------------------------------------------------------------------------------
// NSGs — design §4.6
// ---------------------------------------------------------------------------------------------------------------------
module nsgHosts 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'dep-nsg-hosts'
  params: {
    name: names.nsg_hosts
    location: location
    tags: tags
    diagnosticSettings: diagnosticSettings
    securityRules: [
      {
        name: 'AllowShortpathManagedInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourceAddressPrefixes: shortpathSources
          sourcePortRange: '*'
          destinationAddressPrefix: avd_subnets.hosts
          destinationPortRange: '3390'
          description: 'RDP Shortpath for managed networks from the presenter P2S pool and on-prem clients'
        }
      }
      {
        name: 'AllowAdminRdpInbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefixes: admin_source_prefixes
          sourcePortRange: '*'
          destinationAddressPrefix: avd_subnets.hosts
          destinationPortRange: '3389'
          description: 'Admin RDP from the shared Bastion subnet and the lab jump subnet'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'AllowAvdServiceOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'WindowsVirtualDesktop'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowEntraOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureActiveDirectory'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowMonitorOutbound'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureMonitor'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowStorageOutbound'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Storage'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowFrontDoorOutbound'
        properties: {
          priority: 140
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureFrontDoor.Frontend'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowShortpathTurnOutbound'
        properties: {
          priority: 150
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Udp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'WindowsVirtualDesktop'
          destinationPortRange: '3478'
        }
      }
      {
        name: 'AllowShortpathStunOutbound'
        properties: {
          priority: 160
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Udp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '49152-65535'
        }
      }
      {
        name: 'AllowSmbToPrivateEndpointOutbound'
        properties: {
          priority: 170
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: avd_subnets.pe
          destinationPortRange: '445'
        }
      }
      {
        // D-029: the FSLogix share is reached on its public endpoint, so SMB must be allowed to the Storage service tag
        name: 'AllowSmbToStorageOutbound'
        properties: {
          priority: 175
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Storage'
          destinationPortRange: '445'
        }
      }
      {
        name: 'AllowKmsOutbound'
        properties: {
          priority: 180
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '1688'
        }
      }
      {
        name: 'AllowWebOutbound'
        properties: {
          priority: 190
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRanges: ['80', '443']
          description: 'Windows Update and certificate endpoints; tighten when a proxy appears (design §4.6)'
        }
      }
      {
        name: 'DenyInternetOutbound'
        properties: {
          priority: 4000
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
          description: 'VirtualNetwork (peered spokes, on-prem via gateway, Azure DNS) stays allowed by the default rules'
        }
      }
    ]
  }
}

module nsgPe 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'dep-nsg-pe'
  params: {
    name: names.nsg_pe
    location: location
    tags: tags
    diagnosticSettings: diagnosticSettings
    securityRules: [
      {
        name: 'AllowSmbInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefixes: smbSources
          sourcePortRange: '*'
          destinationAddressPrefix: avd_subnets.pe
          destinationPortRange: '445'
          description: 'SMB to the Azure Files private endpoint from all three realms'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

module nsgImgBuild 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'dep-nsg-imgbuild'
  params: {
    name: names.nsg_imgbuild
    location: location
    tags: tags
    diagnosticSettings: diagnosticSettings
    securityRules: [
      {
        name: 'AllowImageBuilderProxyInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: avd_subnets.imgbuild
          destinationPortRange: '60000-60001'
          description: 'Azure Image Builder private-link proxy requirement'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// VNet — design §4.1 (Azure-provided DNS; no custom DNS servers)
// ---------------------------------------------------------------------------------------------------------------------
// Explicit outbound path: every subnet has defaultOutboundAccess false and the spoke has no firewall or route table, so the host
// and image-build subnets egress through one NAT gateway (the AVD service, Entra ID, Azure Monitor, Storage and Windows activation
// are public endpoints). Native resources, no registry module.
resource natPip 'Microsoft.Network/publicIPAddresses@2025-05-01' = {
  name: names.pip_nat
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource natGw 'Microsoft.Network/natGateways@2025-05-01' = {
  name: names.nat_gateway
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 30
    publicIpAddresses: [{ id: natPip.id }]
  }
}

module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'dep-vnet'
  params: {
    name: names.spoke_vnet
    location: location
    tags: tags
    addressPrefixes: [avd_vnet_prefix]
    diagnosticSettings: diagnosticSettings
    subnets: [
      {
        name: names.subnet_hosts
        addressPrefix: avd_subnets.hosts
        networkSecurityGroupResourceId: nsgHosts.outputs.resourceId
        natGatewayResourceId: natGw.id
        defaultOutboundAccess: false
      }
      {
        name: names.subnet_pe
        addressPrefix: avd_subnets.pe
        networkSecurityGroupResourceId: nsgPe.outputs.resourceId
        privateEndpointNetworkPolicies: 'Enabled'
        defaultOutboundAccess: false
      }
      {
        name: names.subnet_imgbuild
        addressPrefix: avd_subnets.imgbuild
        networkSecurityGroupResourceId: nsgImgBuild.outputs.resourceId
        privateLinkServiceNetworkPolicies: 'Disabled'
        natGatewayResourceId: natGw.id
        defaultOutboundAccess: false
      }
      {
        name: names.subnet_dnsin
        addressPrefix: avd_subnets.dnsin
        delegation: 'Microsoft.Network/dnsResolvers'
        defaultOutboundAccess: false
      }
    ]
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// DNS Private Resolver inbound endpoint — design §4.5 option B; owner's P-07 decision flips enable_dns_private_resolver
// ---------------------------------------------------------------------------------------------------------------------
module dnsResolver 'br/public:avm/res/network/dns-resolver:0.5.8' = if (enable_dns_private_resolver) {
  name: 'dep-dnspr'
  params: {
    name: names.dns_resolver
    location: location
    tags: tags
    virtualNetworkResourceId: vnet.outputs.resourceId
    inboundEndpoints: [
      {
        name: names.dns_resolver_inbound
        subnetResourceId: vnet.outputs.subnetResourceIds[3]
        privateIpAllocationMethod: 'Static'
        privateIpAddress: dns_resolver_inbound_ip
      }
    ]
  }
}

output spoke_vnet_id string = vnet.outputs.resourceId
output subnet_hosts_id string = vnet.outputs.subnetResourceIds[0]
output subnet_pe_id string = vnet.outputs.subnetResourceIds[1]
output subnet_imgbuild_id string = vnet.outputs.subnetResourceIds[2]
output subnet_dnsin_id string = vnet.outputs.subnetResourceIds[3]
output dns_resolver_id string = enable_dns_private_resolver ? dnsResolver!.outputs.resourceId : ''
output dns_resolver_inbound_ip string = enable_dns_private_resolver ? dns_resolver_inbound_ip : ''
