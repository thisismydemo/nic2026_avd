targetScope = 'resourceGroup'

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
param imageId string
param dcrId string
param entraJoinExtension bool
param enableMonitoring bool

@secure()
param adminUsername string

@secure()
param adminPassword string

resource machine 'Microsoft.HybridCompute/machines@2025-06-01' = {
  name: vmName
  location: location
  kind: 'HCI'
  identity: {
    type: 'SystemAssigned'
  }
  tags: tags
}

resource nic 'Microsoft.AzureStackHCI/networkInterfaces@2024-01-01' = {
  name: nicName
  location: location
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
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

resource vmi 'Microsoft.AzureStackHCI/virtualMachineInstances@2024-01-01' = {
  name: 'default'
  scope: machine
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    hardwareProfile: {
      vmSize: 'Custom'
      processors: vcpu
      memoryMB: memoryMB
    }
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

resource entra 'Microsoft.HybridCompute/machines/extensions@2025-06-01' = if (entraJoinExtension) {
  parent: machine
  name: 'AADLoginForWindows'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
  }
  dependsOn: [
    vmi
  ]
}

resource monitor 'Microsoft.HybridCompute/machines/extensions@2025-06-01' = if (enableMonitoring) {
  parent: machine
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
  dependsOn: [
    vmi
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
