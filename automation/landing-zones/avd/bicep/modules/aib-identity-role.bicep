// Gap-fill: AVM role-assignment modules support management-group/subscription/resource-group scopes only.
// AIB must assign the configured build-VM UAMI; grant Operator only on that exact identity resource.
targetScope = 'resourceGroup'
import { builtInRoles } from 'builtin-ids.bicep'
param identity_name string
param principal_id string
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  name: identity_name
}
var roleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles.managedIdentityOperator)
// Standard ARM deterministic assignment name. Reconcile any operational repair assignment before initial deployment.
var assignmentName = guid(identity.id, principal_id, roleId)
resource operatorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: assignmentName
  scope: identity
  properties: {
    roleDefinitionId: roleId
    principalId: principal_id
    principalType: 'ServicePrincipal'
    description: 'AIB assigns only its canonical build-VM identity.'
  }
}
