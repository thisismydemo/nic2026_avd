// lz-avd images — design/avd/landing-zone.md §8.1 (gallery + definitions; AIB templates live in avd-images)
// Resource-group scope (rg-*-avd-img). AVM compute/gallery 0.9.5. Definitions come from the environment list
// images.image_definitions (schema-validated: name imgdef-*, publisher, offer, sku, os_type, hyper_v_generation,
// security_type, os_state).
targetScope = 'resourceGroup'

param location string
param tags object
param names object
param image_definitions array
param lab_operators_object_id string

module gallery 'br/public:avm/res/compute/gallery:0.9.5' = {
  name: 'dep-gallery'
  params: {
    name: names.gallery
    location: location
    tags: tags
    description: 'AVD images for the three realms (multi-session for Azure and Azure Local, single-session for Hybrid)'
    roleAssignments: [
      {
        principalId: lab_operators_object_id
        principalType: 'Group'
        roleDefinitionIdOrName: 'Reader'
      }
    ]
    images: [
      for def in image_definitions: {
        name: def.name
        identifier: {
          publisher: def.publisher
          offer: def.offer
          sku: def.sku
        }
        osType: def.os_type
        osState: def.os_state
        hyperVGeneration: def.hyper_v_generation
        securityType: def.security_type
        architecture: 'x64'
        tags: tags
      }
    ]
  }
}

output gallery_id string = gallery.outputs.resourceId
output image_definition_ids array = gallery.outputs.imageResourceIds
