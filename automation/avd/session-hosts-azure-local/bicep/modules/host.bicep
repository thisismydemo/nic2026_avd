targetScope = 'resourceGroup'

// One AVD session host as an Azure Local VM: Arc machine (kind HCI) + NIC on a logical network + VM instance on an
// explicit storage path, then the identity join extension and (optionally) Azure Monitor Agent with a DCR association.
// API versions: VM-management resources use 2026-04-01-preview (the newest Microsoft.AzureStackHCI VM-management
// version; the cluster accepts 2025-09-01-preview, 2026-02-01-preview and 2026-04-01-preview). The registration token
// never enters this template (K-7).

param location string
param tags object
param vmName string

@maxLength(15)
param computerName string

param nicName string
param dcrAssocName string
param vcpu int
param memoryMB int
param customLocationId string
param logicalNetworkId string

@description('DNS servers of the logical network, repeated on the NIC: the cluster treats NIC DNS as immutable after creation, so a re-run must send the same list the NIC inherited (idempotent re-deploy).')
param dnsServers string[] = []

param imageId string

@description('Storage path (Microsoft.AzureStackHCI/storageContainers) resource ID that holds the VM files and disks.')
param storagePathId string

param dcrId string

@description('AD = JsonADDomainExtension into domainFqdn/domainOuPath (D-050, Azure Local realm); Entra = AADLoginForWindows; None = workgroup.')
@allowed([
  'AD'
  'Entra'
  'None'
])
param joinType string = 'AD'

param domainFqdn string = ''
param domainOuPath string = ''

@description('Number of GPU DDA devices to attach (0 = none). Set from the GPU track spec.')
@minValue(0)
param gpuDdaCount int = 0

param enableMonitoring bool

@secure()
param adminUsername string

@secure()
param adminPassword string

@secure()
param domainJoinUsername string = ''

@secure()
param domainJoinPassword string = ''

resource machine 'Microsoft.HybridCompute/machines@2025-01-13' = {
  name: vmName
  location: location
  kind: 'HCI'
  identity: {
    type: 'SystemAssigned'
  }
  tags: tags
}

resource nic 'Microsoft.AzureStackHCI/networkInterfaces@2026-04-01-preview' = {
  name: nicName
  location: location
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    dnsSettings: empty(dnsServers) ? null : {
      dnsServers: dnsServers
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: logicalNetworkId
          }
        }
      }
    ]
  }
  tags: tags
}

var gpus = [for i in range(0, gpuDdaCount): {
  assignmentType: 'GpuDDA'
}]

resource vmi 'Microsoft.AzureStackHCI/virtualMachineInstances@2026-04-01-preview' = {
  name: 'default'
  scope: machine
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    hardwareProfile: union({
      vmSize: 'Custom'
      processors: vcpu
      memoryMB: memoryMB
    }, gpuDdaCount > 0 ? { virtualMachineGPUs: gpus } : {})
    osProfile: {
      adminUsername: adminUsername
      adminPassword: adminPassword
      computerName: computerName
      windowsConfiguration: {
        provisionVMAgent: true
        provisionVMConfigAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        id: imageId
      }
      vmConfigStoragePathId: storagePathId
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// AD DS join (D-050): the same extension the portal's "Enable domain join" uses; Options 3 = join + create account
// (the account is prestaged or created in the delegated OU); Restart = true reboots the guest once.
resource adJoin 'Microsoft.HybridCompute/machines/extensions@2025-01-13' = if (joinType == 'AD') {
  parent: machine
  name: 'JsonADDomainExtension'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      name: domainFqdn
      OUPath: domainOuPath
      User: domainJoinUsername
      Restart: 'true'
      Options: '3'
    }
    protectedSettings: {
      Password: domainJoinPassword
    }
  }
  dependsOn: [
    vmi
  ]
}

resource entra 'Microsoft.HybridCompute/machines/extensions@2025-01-13' = if (joinType == 'Entra') {
  parent: machine
  name: 'AADLoginForWindows'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
    settings: {
      mdmId: ''
    }
  }
  dependsOn: [
    vmi
  ]
}

resource monitor 'Microsoft.HybridCompute/machines/extensions@2025-01-13' = if (enableMonitoring) {
  parent: machine
  name: 'AzureMonitorWindowsAgent'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
  dependsOn: [
    vmi
    adJoin
    entra
  ]
}

resource association 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = if (enableMonitoring) {
  name: dcrAssocName
  scope: machine
  properties: {
    dataCollectionRuleId: dcrId
  }
  dependsOn: [
    monitor
  ]
}

output machineId string = machine.id
output computerName string = computerName
output principalId string = machine.identity.?principalId ?? ''
