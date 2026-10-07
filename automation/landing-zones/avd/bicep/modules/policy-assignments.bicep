// Gap-fill: subscription-scope policy assignments — design §2.4 (built-in definitions only).
// Why gap-fill: avm/ptn/authorization/policy-assignment 0.5.3 is a management-group-scoped template and cannot be
// deployed from a subscription-scoped main (P-06 assigns at subscription scope).
// Built-in ids come from builtin-ids.bicep (the single GUID file). DeployIfNotExists policies (diagnostics, AMA/DCR
// association) are a documented gap left to the Day-2 and session-host solutions.
targetScope = 'subscription'

import { builtInPolicies, builtInRoles } from 'builtin-ids.bicep'

param location string
param names object
param tags object

var governedTags = ['project', 'workload', 'environment', 'owner', 'lifecycle']

resource allowedLocations 'Microsoft.Authorization/policyAssignments@2025-01-01' = {
  name: names.asg_allowed_locations
  properties: {
    displayName: 'AVD lab: allowed locations'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', builtInPolicies.allowedLocations)
    enforcementMode: 'Default'
    parameters: {
      listOfAllowedLocations: {
        value: [location, 'global']
      }
    }
  }
}

resource requireTags 'Microsoft.Authorization/policyAssignments@2025-01-01' = [
  for tagName in governedTags: {
    name: '${names.asg_require_tags}-${tagName}'
    properties: {
      displayName: 'AVD lab: require tag ${tagName} on resource groups'
      policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', builtInPolicies.requireTagOnResourceGroups)
      enforcementMode: 'Default'
      parameters: {
        tagName: {
          value: tagName
        }
      }
    }
  }
]

resource inheritTags 'Microsoft.Authorization/policyAssignments@2025-01-01' = [
  for tagName in governedTags: {
    name: '${names.asg_inherit_tags}-${tagName}'
    location: location
    identity: {
      type: 'SystemAssigned'
    }
    properties: {
      displayName: 'AVD lab: inherit tag ${tagName} from the resource group'
      policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', builtInPolicies.inheritTagFromResourceGroupIfMissing)
      enforcementMode: 'Default'
      parameters: {
        tagName: {
          value: tagName
        }
      }
    }
  }
]

// Modify effect needs Tag Contributor on the assignment identity
resource inheritTagsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (tagName, i) in governedTags: {
    name: guid(subscription().id, names.asg_inherit_tags, tagName)
    properties: {
      principalId: inheritTags[i].identity.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles.tagContributor)
    }
  }
]

var storagePolicies = [
  builtInPolicies.storageAccountsDisablePublicNetworkAccess
  builtInPolicies.secureTransferToStorageAccounts
]

resource storageHygiene 'Microsoft.Authorization/policyAssignments@2025-01-01' = [
  for (definitionId, i) in storagePolicies: {
    name: '${names.asg_storage_hygiene}-${i + 1}'
    properties: {
      displayName: 'AVD lab: storage hygiene (${i + 1})'
      policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', definitionId)
      enforcementMode: 'Default'
      parameters: {
        effect: {
          value: 'Audit'
        }
      }
    }
  }
]

output assignment_count int = 1 + (2 * length(governedTags)) + length(storagePolicies)
output tags_governed array = governedTags
output tag_keys_present int = length(items(tags))
