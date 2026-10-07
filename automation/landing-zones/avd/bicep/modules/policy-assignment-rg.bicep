// Gap-fill: resource-group-scope policy assignment "Network interfaces should not have public IPs" on the
// session-host RG (design §2.4). Same justification as policy-assignments.bicep (AVM ptn module is MG-scoped).
targetScope = 'resourceGroup'

import { builtInPolicies } from 'builtin-ids.bicep'

param name string

resource noPublicIp 'Microsoft.Authorization/policyAssignments@2025-01-01' = {
  name: name
  properties: {
    displayName: 'AVD lab: no public IPs on session hosts'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', builtInPolicies.networkInterfacesNoPublicIps)
    enforcementMode: 'Default'
  }
}

output assignment_id string = noPublicIp.id
