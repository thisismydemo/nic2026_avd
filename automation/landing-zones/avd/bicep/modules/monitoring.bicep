// lz-avd monitoring — design/avd/landing-zone.md §9.2 (AVD Insights default DCR + three alert rules)
// Resource-group scope (rg-*-avd-mon). AVM insights/data-collection-rule 0.11.0, insights/scheduled-query-rule 0.6.0.
targetScope = 'resourceGroup'

param location string
param tags object
param names object
param log_analytics_workspace_id string
param action_group_id string

// AVD Insights default counter and event set (Enable Insights — Log Analytics settings). No VM Insights duplicates.
var perfCounters60s = [
  '\\LogicalDisk(C:)\\% Free Space'
  '\\LogicalDisk(C:)\\Avg. Disk Queue Length'
  '\\LogicalDisk(C:)\\Avg. Disk sec/Transfer'
  '\\LogicalDisk(C:)\\Current Disk Queue Length'
  '\\Memory\\Available Mbytes'
  '\\Memory\\Page Faults/sec'
  '\\Memory\\Pages/sec'
  '\\Memory\\% Committed Bytes In Use'
  '\\PhysicalDisk(*)\\Avg. Disk Queue Length'
  '\\PhysicalDisk(*)\\Avg. Disk sec/Read'
  '\\PhysicalDisk(*)\\Avg. Disk sec/Transfer'
  '\\PhysicalDisk(*)\\Avg. Disk sec/Write'
  '\\Processor Information(_Total)\\% Processor Time'
]

var perfCounters30s = [
  '\\Terminal Services(*)\\Active Sessions'
  '\\Terminal Services(*)\\Inactive Sessions'
  '\\Terminal Services(*)\\Total Sessions'
  '\\User Input Delay per Process(*)\\Max Input Delay'
  '\\User Input Delay per Session(*)\\Max Input Delay'
  '\\RemoteFX Network(*)\\Current TCP RTT'
  '\\RemoteFX Network(*)\\Current UDP Bandwidth'
]

var eventXPaths = [
  'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
  'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
  'System!*[System[(Level=2 or Level=3)]]'
  'Application!*[System[(Level=2 or Level=3)]]'
  'Microsoft-FSLogix-Apps/Operational!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
  'Microsoft-FSLogix-Apps/Admin!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
]

module dcr 'br/public:avm/res/insights/data-collection-rule:0.11.0' = {
  name: 'dep-dcr-avd-insights'
  params: {
    name: names.dcr_avd_insights
    location: location
    tags: tags
    dataCollectionRuleProperties: {
      kind: 'Windows'
      description: 'AVD Insights default counters and events for all three realms (Azure VMs and Arc machines)'
      dataSources: {
        performanceCounters: [
          {
            name: 'avdInsightsPerf60'
            streams: ['Microsoft-Perf']
            samplingFrequencyInSeconds: 60
            counterSpecifiers: perfCounters60s
          }
          {
            name: 'avdInsightsPerf30'
            streams: ['Microsoft-Perf']
            samplingFrequencyInSeconds: 30
            counterSpecifiers: perfCounters30s
          }
        ]
        windowsEventLogs: [
          {
            name: 'avdInsightsEvents'
            streams: ['Microsoft-Event']
            xPathQueries: eventXPaths
          }
        ]
      }
      destinations: {
        logAnalytics: [
          {
            name: 'lawLab'
            workspaceResourceId: log_analytics_workspace_id
          }
        ]
      }
      dataFlows: [
        {
          streams: ['Microsoft-Perf', 'Microsoft-Event']
          destinations: ['lawLab']
        }
      ]
    }
  }
}

// Alert rules — design §9.2 (scheduled query rules on the lab workspace, routed to the ops action group)
var alerts = [
  {
    name: names.alert_hostunavailable
    description: 'A session host has not reported Available for more than 10 minutes (silent hosts included: the look-back is one hour)'
    query: 'WVDAgentHealthStatus | where TimeGenerated > ago(1h) | summarize arg_max(TimeGenerated, *) by SessionHostName | where Status != "Available" or TimeGenerated < ago(10m)'
    severity: 2
    windowSize: 'PT1H'
  }
  {
    name: names.alert_fslogixerror
    description: 'FSLogix error events (profile attach or detach failures) from the Operational and Admin channels'
    query: 'Event | where EventLog in ("Microsoft-FSLogix-Apps/Operational", "Microsoft-FSLogix-Apps/Admin") | where EventLevelName == "Error"'
    severity: 1
    windowSize: 'PT15M'
  }
  {
    name: names.alert_connfail
    description: 'AVD connection failures reported by the service'
    query: 'WVDErrors | where ActivityType == "Connection"'
    severity: 2
    windowSize: 'PT15M'
  }
]

module alertRules 'br/public:avm/res/insights/scheduled-query-rule:0.6.0' = [
  for alert in alerts: {
    name: 'dep-${alert.name}'
    params: {
      name: alert.name
      location: location
      tags: tags
      kind: 'LogAlert'
      alertDescription: alert.description
      severity: alert.severity
      enabled: true
      autoMitigate: true
      evaluationFrequency: 'PT5M'
      windowSize: alert.windowSize
      scopes: [log_analytics_workspace_id]
      criterias: {
        allOf: [
          {
            query: alert.query
            timeAggregation: 'Count'
            operator: 'GreaterThan'
            threshold: 0
            failingPeriods: {
              numberOfEvaluationPeriods: 1
              minFailingPeriodsToAlert: 1
            }
          }
        ]
      }
      actions: {
        actionGroupResourceIds: [action_group_id]
      }
    }
  }
]

output dcr_id string = dcr.outputs.resourceId
output alert_rule_ids array = [for (alert, i) in alerts: alertRules[i].outputs.resourceId]
