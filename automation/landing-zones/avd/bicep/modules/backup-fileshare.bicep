// Gap-fill: Azure Files backup enrolment (protection container registration + protected items).
// Why gap-fill: AVM recovery-services/vault 0.13.2 exposes protectedItems but does not register the storage
// account's protection container, which Azure requires before an AzureFileShare protected item can be created.
targetScope = 'resourceGroup'

param vault_name string
param policy_name string
param storage_account_id string
param storage_account_name string
param share_names array

var containerName = 'StorageContainer;Storage;${resourceGroup().name};${storage_account_name}'

resource vault 'Microsoft.RecoveryServices/vaults@2025-02-01' existing = {
  name: vault_name

  resource policy 'backupPolicies' existing = {
    name: policy_name
  }
}

// The backup fabric is always named "Azure"; the container is addressed through it.
resource container 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers@2025-02-01' = {
  name: '${vault_name}/Azure/${containerName}'
  properties: {
    backupManagementType: 'AzureStorage'
    containerType: 'StorageContainer'
    sourceResourceId: storage_account_id
    friendlyName: storage_account_name
  }
}

resource protectedItems 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2025-02-01' = [
  for shareName in share_names: {
    parent: container
    name: 'AzureFileShare;${shareName}'
    properties: {
      protectedItemType: 'AzureFileShareProtectedItem'
      sourceResourceId: storage_account_id
      policyId: vault::policy.id
    }
  }
]

output container_name string = containerName
