// lz-avd private DNS — design/avd/landing-zone.md §4.5 and decision P-11 (the lab owns privatelink.file.core.windows.net)
// Zone links carry the lab token (link_*); the zone name is Azure-fixed and exempt. AVM private-dns-zone 0.8.1.
targetScope = 'resourceGroup'

param tags object
param names object
param zone_name string
param spoke_vnet_id string
param azl_spoke_vnet_id string
param identity_spoke_vnet_id string
param hub_vnet_id string
param link_hub bool

var baseLinks = [
  {
    name: names.link_avd
    virtualNetworkResourceId: spoke_vnet_id
    registrationEnabled: false
  }
  {
    name: names.link_azl
    virtualNetworkResourceId: azl_spoke_vnet_id
    registrationEnabled: false
  }
  {
    name: names.link_identity
    virtualNetworkResourceId: identity_spoke_vnet_id
    registrationEnabled: false
  }
]

var hubLink = [
  {
    name: names.link_hub
    virtualNetworkResourceId: hub_vnet_id
    registrationEnabled: false
  }
]

module zone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'dep-pdns-file'
  params: {
    name: zone_name
    location: 'global'
    tags: tags
    virtualNetworkLinks: link_hub ? concat(baseLinks, hubLink) : baseLinks
  }
}

output zone_id string = zone.outputs.resourceId
