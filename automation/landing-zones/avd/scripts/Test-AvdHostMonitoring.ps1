#Requires -Version 7.0
<#
.SYNOPSIS
    READ-ONLY check of the AVD monitoring per session host (T-6.2.4): for every session host in the three host pools,
    the Azure Monitor Agent extension, the association with the AVD Insights DCR and fresh data in the Log Analytics workspace
    (Heartbeat and WVDAgentHealthStatus). Azure VMs, Azure Local VMs (Arc) and Hybrid hosts (Arc) are all covered.
.DESCRIPTION
    Session hosts come from the host pools (Get session hosts API, resourceId of each host). The AMA extension is read
    on Microsoft.Compute/virtualMachines or Microsoft.HybridCompute/machines; the association is any
    dataCollectionRuleAssociation on the machine that points at the AVD Insights DCR. Names and IDs come from the
    environment files through the converters. Changes nothing. The host-pool solutions (session-hosts-azure,
    session-hosts-azure-local, session-hosts-hybrid with enable_arc_extensions) create the AMA extension and the
    association; run this after each host build.
.PARAMETER FreshMinutes
    Data newer than this counts as fresh (default 30).
.EXAMPLE
    .\Test-AvdHostMonitoring.ps1
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param([int]$FreshMinutes = 30)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
Import-Module (Join-Path $repoRoot 'automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1') -Force
$config = Get-NIC26Config -Scope avd
$lz = ConvertTo-NIC26TfVars -Solution (Join-Path $repoRoot 'automation\landing-zones\avd') -Config $config | ConvertFrom-Json -Depth 50
$cp = ConvertTo-NIC26TfVars -Solution (Join-Path $repoRoot 'automation\avd\control-plane') -Config $config | ConvertFrom-Json -Depth 50
$sub = [string]$lz.subscription_id_avd
$lawId = [string]$config.values['log_analytics_workspace_id']
$dcrId = "/subscriptions/$sub/resourceGroups/$($lz.names.rg_mon)/providers/Microsoft.Insights/dataCollectionRules/$($lz.names.dcr_avd_insights)"
$ctx = Get-AzContext
if (-not $ctx -or $ctx.Tenant.Id -ne [string]$config.values['tenant_id']) { [void](Set-AzContext -Tenant ([string]$config.values['tenant_id']) -Subscription $sub) }

function Get-Json { param([string]$Path) $r = Invoke-AzRestMethod -Path $Path -Method GET; if ($r.StatusCode -ge 400) { return $null }; return ($r.Content | ConvertFrom-Json -Depth 50) }

# Fresh data per computer in the Log Analytics workspace (Heartbeat from AMA; WVDAgentHealthStatus from the host-pool diagnostics).
$law = Get-Json -Path "$($lawId)?api-version=2023-09-01"
$token = (Get-AzAccessToken -ResourceUrl 'https://api.loganalytics.io' -AsSecureString).Token
function Invoke-LawQuery {
    param([string]$Query)
    try { $b = @{ query = $Query } | ConvertTo-Json; return (Invoke-RestMethod -Method Post -Uri "https://api.loganalytics.io/v1/workspaces/$($law.properties.customerId)/query" -Authentication Bearer -Token $token -Body $b -ContentType 'application/json').tables[0].rows }
    catch { return @() } 
}
$hb = @{}; foreach ($row in @(Invoke-LawQuery "Heartbeat | where TimeGenerated > ago($($FreshMinutes)m) | summarize max(TimeGenerated) by Computer")) { $hb[([string]$row[0]).Split('.')[0].ToLowerInvariant()] = $row[1] }
$ah = @{}; foreach ($row in @(Invoke-LawQuery "WVDAgentHealthStatus | where TimeGenerated > ago($($FreshMinutes)m) | summarize arg_max(TimeGenerated, Status) by SessionHostName")) { $ah[([string]$row[0]).Split('.')[0].ToLowerInvariant()] = "$($row[2])" }

$rows = [System.Collections.Generic.List[object]]::new()
$pools = @($cp.names.PSObject.Properties | Where-Object { [string]$_.Value -like 'vdpool-*' } | ForEach-Object { [string]$_.Value })
foreach ($pool in $pools) {
    $hosts = Get-Json -Path "/subscriptions/$sub/resourceGroups/$($cp.names.rg_control)/providers/Microsoft.DesktopVirtualization/hostPools/$pool/sessionHosts?api-version=2024-04-03"
    if (-not $hosts -or @($hosts.value).Count -eq 0) { $rows.Add([pscustomobject]@{ pool = $pool; host = '(none registered)'; ama = '-'; dcr = '-'; heartbeat = '-'; agent = '-' }); continue }
    foreach ($h in @($hosts.value)) {
        $fqdn = ($h.name -split '/')[-1]; $short = $fqdn.Split('.')[0].ToLowerInvariant()
        $rid = [string]$h.properties.resourceId
        $ama = 'n/a'; $dcr = 'n/a'
        if ($rid) {
            # The extension name differs by builder (AzureMonitorAgent, AzureMonitorWindowsAgent); match on the type.
            $extPath = if ($rid -match '/Microsoft.Compute/virtualMachines/') { "$rid/extensions?api-version=2024-07-01" } else { "$rid/extensions?api-version=2024-07-10" }
            $list = Get-Json -Path $extPath
            $e = if ($list) { @($list.value | Where-Object { $_.properties.type -eq 'AzureMonitorWindowsAgent' }) | Select-Object -First 1 } else { $null }
            $ama = if ($e) { [string]$e.properties.provisioningState } else { 'missing' }
            $assoc = Get-Json -Path "$rid/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11"
            $dcr = if ($assoc -and @($assoc.value | Where-Object { $_.properties.dataCollectionRuleId -eq $dcrId }).Count -gt 0) { 'associated' } else { 'missing' }
        }
        $rows.Add([pscustomobject]@{ pool = $pool; host = $fqdn; ama = $ama; dcr = $dcr; heartbeat = $(if ($hb.ContainsKey($short)) { 'fresh' } else { 'none' }); agent = $(if ($ah.ContainsKey($short)) { $ah[$short] } else { 'none' }) })
    }
}
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Information -InformationAction Continue
return $rows
