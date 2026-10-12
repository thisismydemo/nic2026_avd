// The already assigned host-pool identity performs power-management autoscale.
targetScope = 'subscription'
param principal_id string
var powerRole = '40c5ff49-9181-41f8-ae61-143b0e78555e'
resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principal_id, powerRole)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', powerRole)
    principalId: principal_id
    principalType: 'ServicePrincipal'
  }
}
