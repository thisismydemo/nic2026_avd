// "AVD Anywhere · three terminals": one Azure Monitor workbook over the Log Analytics workspace that shows the three
// host pools side by side (owner, 14 Oct). Resource-group scope (the AVD control-plane resource group).
// The workbook content is workbooks/avd-anywhere.workbook.json; two tokens are filled here so the JSON carries nothing
// environment-specific: __WORKSPACE_ID__ (the workspace every query runs against) and __TERMINALS__ (a KQL datatable that maps
// host pool name and computer-name prefix to the terminal label). Deployed by scripts/Deploy-AvdWorkbook.ps1.
targetScope = 'resourceGroup'

@description('Azure region of the workbook resource.')
param location string = resourceGroup().location

@description('Tags (project=nic26 and the workload tags).')
param tags object

@description('Workbook name in the portal gallery.')
param display_name string = 'AVD Anywhere · three terminals'

@description('Resource id of the Log Analytics workspace the AVD diagnostics, AVD Insights DCR and hosts send to.')
param log_analytics_workspace_id string

@description('One entry per terminal: { pool: host pool name, prefix: computer-name prefix, label: terminal label }.')
param terminals array

// KQL single-quoted string literals; labels and names never contain a single quote (checked by the deploy script).
var terminalRows = join(map(terminals, t => '\'${toLower(t.pool)}\',\'${toLower(t.prefix)}\',\'${t.label}\''), ',')
var terminalTable = 'datatable(Pool:string, Prefix:string, Terminal:string)[${terminalRows}]'
var content = replace(replace(loadTextContent('../../workbooks/avd-anywhere.workbook.json'), '__TERMINALS__', terminalTable), '__WORKSPACE_ID__', log_analytics_workspace_id)

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'workbook-avd-anywhere-three-terminals')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: display_name
    category: 'workbook'
    sourceId: log_analytics_workspace_id
    serializedData: content
    version: 'Notebook/1.0'
  }
}

output workbook_id string = workbook.id
output workbook_name string = workbook.name
