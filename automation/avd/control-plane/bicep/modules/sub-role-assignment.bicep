// Gap-fill: subscription-scope role assignment for the AVD first-party service principal (scaling plan / Start VM on Connect).
targetScope = 'subscription'

param avd_service_principal_object_id string

var powerOnOffContributorRoleId = '40c5ff49-9181-41f8-ae61-143b0e78555e' // Desktop Virtualization Power On Off Contributor

resource powerOnOffContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, avd_service_principal_object_id, powerOnOffContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', powerOnOffContributorRoleId)
    principalId: avd_service_principal_object_id
    principalType: 'ServicePrincipal'
  }
}
