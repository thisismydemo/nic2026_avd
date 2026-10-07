// lz-avd profile storage — design/avd/landing-zone.md §7.3, §7.5 (share RBAC), §7.9 (backup)
// Resource-group scope (rg-*-avd-stor). AVM storage-account 0.33.1 (private endpoint through its interface),
// AVM recovery-services/vault 0.13.2, gap-fill backup-fileshare.bicep for container registration + protected items.
targetScope = 'resourceGroup'

param location string
param tags object
param names object
param share_names object
param share_quota_gib int
param subnet_pe_id string
param privatelink_file_zone_id string
param enable_private_endpoints bool
param log_analytics_workspace_id string
param group_object_ids object
param enable_backup bool
param backup_policy object

var shareRoleAssignments = [
  {
    principalId: group_object_ids.avd_users
    principalType: 'Group'
    roleDefinitionIdOrName: 'Storage File Data SMB Share Contributor'
    description: 'FSLogix share-level permission for the union group (design §7.5)'
  }
  {
    principalId: group_object_ids.avd_admins
    principalType: 'Group'
    roleDefinitionIdOrName: 'Storage File Data SMB Share Elevated Contributor'
    description: 'NTFS/ACL management (design §7.5)'
  }
]

var shareList = [share_names.profiles, share_names.odfc]

// ---------------------------------------------------------------------------------------------------------------------
// Storage account — Premium FileStorage, Entra Kerberos (AADKERB), no shared keys, private endpoint only
// Microsoft.Storage/storageAccounts azureFilesIdentityBasedAuthentication.directoryServiceOptions = AADKERB;
// activeDirectoryProperties are optional for AADKERB (cloud-only identities need none). What ARM cannot do —
// admin consent on the generated app, the kdc_enable_cloud_group_sids tag, the privatelink identifierUri and the
// Conditional Access exclusion — is in scripts/Set-AvdStorageEntraKerberos.ps1.
// ---------------------------------------------------------------------------------------------------------------------
module storageAccount 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: 'dep-st-fslogix'
  params: {
    name: names.fslogix_sa
    location: location
    tags: tags
    kind: 'FileStorage'
    skuName: 'Premium_LRS'
    accessTier: 'Premium'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    // Azure Backup for Azure Files needs 'Allow storage account key access' on the source account (Learn: support matrix for Azure Files backup),
    // so shared-key access follows enable_backup. The FSLogix path itself stays Kerberos-only (authenticationMethods) with no default share permission.
    allowSharedKeyAccess: enable_backup
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: true
    // D-029: public endpoint by default (the rack's WAN address changes, so no IP rules); access is Kerberos plus share RBAC only.
    publicNetworkAccess: enable_private_endpoints ? 'Disabled' : 'Enabled'
    networkAcls: {
      defaultAction: enable_private_endpoints ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
    }
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'AADKERB'
      defaultSharePermission: 'None'
    }
    fileServices: {
      protocolSettings: {
        smb: {
          versions: 'SMB3.1.1'
          authenticationMethods: 'Kerberos'
          kerberosTicketEncryption: 'AES-256'
          channelEncryption: 'AES-128-GCM;AES-256-GCM'
        }
      }
      shareDeleteRetentionPolicy: {
        enabled: true
        days: 14
      }
      diagnosticSettings: [
        {
          workspaceResourceId: log_analytics_workspace_id
        }
      ]
      shares: [
        for shareName in shareList: {
          name: shareName
          shareQuota: share_quota_gib
          enabledProtocols: 'SMB'
          accessTier: 'Premium'
          roleAssignments: shareRoleAssignments
        }
      ]
    }
    privateEndpoints: !enable_private_endpoints ? [] : [
      {
        name: names.fslogix_pe
        service: 'file'
        subnetResourceId: subnet_pe_id
        tags: tags
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: privatelink_file_zone_id
            }
          ]
        }
      }
    ]
    diagnosticSettings: [
      {
        workspaceResourceId: log_analytics_workspace_id
      }
    ]
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Azure Files backup — snapshot tier, daily, 7 days (design §7.9)
// ---------------------------------------------------------------------------------------------------------------------
var backupTime = '2026-01-01T${backup_policy.schedule_time_utc}:00Z'

module recoveryVault 'br/public:avm/res/recovery-services/vault:0.13.2' = if (enable_backup) {
  name: 'dep-rsv'
  params: {
    name: names.recovery_vault
    location: location
    tags: tags
    publicNetworkAccess: 'Enabled'
    redundancySettings: {
      standardTierStorageRedundancy: 'LocallyRedundant'
    }
    backupPolicies: [
      {
        name: names.backup_policy
        properties: {
          backupManagementType: 'AzureStorage'
          workloadType: 'AzureFileShare'
          timeZone: 'UTC'
          schedulePolicy: {
            schedulePolicyType: 'SimpleSchedulePolicy'
            scheduleRunFrequency: 'Daily'
            scheduleRunTimes: [backupTime]
          }
          retentionPolicy: {
            retentionPolicyType: 'LongTermRetentionPolicy'
            dailySchedule: {
              retentionTimes: [backupTime]
              retentionDuration: {
                count: backup_policy.retention_days
                durationType: 'Days'
              }
            }
          }
        }
      }
    ]
    diagnosticSettings: [
      {
        workspaceResourceId: log_analytics_workspace_id
      }
    ]
  }
}

module backupShares 'backup-fileshare.bicep' = if (enable_backup) {
  name: 'dep-rsv-shares'
  params: {
    vault_name: names.recovery_vault
    policy_name: names.backup_policy
    storage_account_id: storageAccount.outputs.resourceId
    storage_account_name: storageAccount.outputs.name
    share_names: shareList
  }
  dependsOn: [recoveryVault]
}

output storage_account_id string = storageAccount.outputs.resourceId
output storage_account_name string = storageAccount.outputs.name
output fslogix_profile_unc string = '\\\\${storageAccount.outputs.name}.file.${environment().suffixes.storage}\\${share_names.profiles}'
output fslogix_odfc_unc string = '\\\\${storageAccount.outputs.name}.file.${environment().suffixes.storage}\\${share_names.odfc}'
output private_endpoint_id string = enable_private_endpoints ? storageAccount.outputs.privateEndpoints[0].resourceId : ''
output recovery_vault_id string = enable_backup ? recoveryVault!.outputs.resourceId : ''
