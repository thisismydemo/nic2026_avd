// Gap-fill: the two Azure Image Builder custom roles — design §5.3 (Image Builder permissions).
// Why gap-fill: no AVM resource module publishes Microsoft.Authorization/roleDefinitions at subscription scope.
targetScope = 'subscription'

param names object

var rgImgId = subscriptionResourceId('Microsoft.Resources/resourceGroups', names.rg_img)
var rgNetId = subscriptionResourceId('Microsoft.Resources/resourceGroups', names.rg_net)

resource aibImageRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, names.role_aib_image)
  properties: {
    roleName: names.role_aib_image
    description: 'Azure Image Builder: read the gallery and definitions, write image versions and managed images (lab)'
    type: 'CustomRole'
    assignableScopes: [rgImgId]
    permissions: [
      {
        actions: [
          'Microsoft.Compute/galleries/read'
          'Microsoft.Compute/galleries/images/read'
          'Microsoft.Compute/galleries/images/versions/read'
          'Microsoft.Compute/galleries/images/versions/write'
          'Microsoft.Compute/images/read'
          'Microsoft.Compute/images/write'
          'Microsoft.Compute/images/delete'
        ]
        notActions: []
      }
    ]
  }
}

resource aibNetworkRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, names.role_aib_network)
  properties: {
    roleName: names.role_aib_network
    description: 'Azure Image Builder: join the image-build subnet of the AVD spoke (existing-VNet build)'
    type: 'CustomRole'
    assignableScopes: [rgNetId]
    permissions: [
      {
        actions: [
          'Microsoft.Network/virtualNetworks/read'
          'Microsoft.Network/virtualNetworks/subnets/join/action'
        ]
        notActions: []
      }
    ]
  }
}

output role_aib_image_id string = aibImageRole.id
output role_aib_network_id string = aibNetworkRole.id
