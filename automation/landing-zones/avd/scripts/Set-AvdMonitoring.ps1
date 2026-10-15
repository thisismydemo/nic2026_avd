#Requires -Version 7.0
<#
.SYNOPSIS
    Applies the AVD monitoring layer on its own (T-6.2.4, D-054): the AVD Insights DCR and the three AVD log alerts
    (bicep/modules/monitoring.bicep, the same module lz-avd deploys) and the control-plane diagnostic settings
    (bicep/modules/control-plane-diagnostics.bicep), all pointing at environment/avd log_analytics_workspace_id. Reads back.
.DESCRIPTION
    Use it when the workspace changes or the monitoring must be re-applied without re-running the whole landing zone or
    the control plane (whose host-pool settings belong to the AVD build). Values: environment/avd (+ shared) through the
    NIC26 converters for lz-avd and avd-control-plane; nothing is hardcoded. Default -WhatIf (ARM what-if); -Execute
    deploys and reads back: DCR destination, alert scopes, diagnostic settings per control-plane resource.
.PARAMETER Execute
    Deploy. Without it only the what-if runs.
.EXAMPLE
    .\Set-AvdMonitoring.ps1            # what-if
    .\Set-AvdMonitoring.ps1 -Execute   # deploy + read back
#>
[CmdletBinding(SupportsShouldProcess)]
[OutputType([pscustomobject])]
param([switch]$Execute)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Execute) { $WhatIfPreference = $true }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
Import-Module (Join-Path $repoRoot 'automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1') -Force
$config = Get-NIC26Config -Scope avd
$lz = ConvertTo-NIC26TfVars -Solution (Join-Path $repoRoot 'automation\landing-zones\avd') -Config $config | ConvertFrom-Json -Depth 50
$cp = ConvertTo-NIC26TfVars -Solution (Join-Path $repoRoot 'automation\avd\control-plane') -Config $config | ConvertFrom-Json -Depth 50
$v = $config.values
$nc = Get-NIC26NamingContext -Config $config
$lawId = [string]$v['log_analytics_workspace_id']
$agId = [string]$v['action_group_id']
if (-not $lawId -or -not $agId) { throw 'environment/avd needs log_analytics_workspace_id and action_group_id.' }

$ctx = Get-AzContext
if (-not $ctx -or $ctx.Tenant.Id -ne [string]$v['tenant_id'] -or $ctx.Subscription.Id -ne [string]$lz.subscription_id_avd) {
    [void](Set-AzContext -Tenant ([string]$v['tenant_id']) -Subscription ([string]$lz.subscription_id_avd) -WhatIf:$false)
}
$tags = @{}; foreach ($p in $lz.tags.PSObject.Properties) { $tags[$p.Name] = [string]$p.Value }
$tags['workload'] = 'avd'; $tags['managed-by'] = 'bicep'
$names = @{}; foreach ($p in $lz.names.PSObject.Properties) { $names[$p.Name] = [string]$p.Value }
$cpNames = $cp.names
$hostPools = @($cpNames.PSObject.Properties | Where-Object { $_.Name -like 'hp_*' -or $_.Name -like 'vdpool_*' -or $_.Value -like 'vdpool-*' } | ForEach-Object { [string]$_.Value } | Sort-Object -Unique)
$workspaceName = @($cpNames.PSObject.Properties | Where-Object { $_.Value -like 'vdws-*' } | ForEach-Object { [string]$_.Value })[0]
$scalingPlans = @($cpNames.PSObject.Properties | Where-Object { $_.Value -like 'vdscaling-*' } | ForEach-Object { [string]$_.Value } | Sort-Object -Unique)
if (-not $workspaceName -or $hostPools.Count -eq 0) { throw 'Could not resolve the AVD workspace / host pool names from the avd-control-plane catalog.' }

$deployments = @(
    @{ ResourceGroupName = $names['rg_mon']; Name = (New-NIC26ResourceName -Type dep -Purpose 'avd-monitoring-day2' -Org $nc.Org -Token $nc.Token); TemplateFile = (Join-Path $PSScriptRoot '..\bicep\modules\monitoring.bicep')
        TemplateParameterObject = @{ location = [string]$lz.location; tags = $tags; names = $names; log_analytics_workspace_id = $lawId; action_group_id = $agId } 
    }
    @{ ResourceGroupName = $names['rg_control']; Name = (New-NIC26ResourceName -Type dep -Purpose 'avd-diagnostics-day2' -Org $nc.Org -Token $nc.Token); TemplateFile = (Join-Path $PSScriptRoot '..\bicep\modules\control-plane-diagnostics.bicep')
        TemplateParameterObject = @{ log_analytics_workspace_id = $lawId; workspace_name = $workspaceName; host_pool_names = $hostPools; scaling_plan_names = $scalingPlans } 
    }
)
# A scheduled query rule's scope cannot be updated in place ("Scope can not be updated", 12 Oct): a rule that points at
# another workspace is deleted first and re-created by the deployment (same name, same query, new scope).
$monPath = "/subscriptions/$([string]$lz.subscription_id_avd)/resourceGroups/$($names['rg_mon'])/providers/Microsoft.Insights/scheduledQueryRules"
foreach ($k in 'alert_hostunavailable', 'alert_fslogixerror', 'alert_connfail') {
    $get = Invoke-AzRestMethod -Path "$monPath/$($names[$k])?api-version=2023-12-01" -Method GET
    if ($get.StatusCode -ne 200) { continue }
    $scopes = @(($get.Content | ConvertFrom-Json).properties.scopes)
    if ($scopes -notcontains $lawId -and $PSCmdlet.ShouldProcess($names[$k], 'delete to re-create on the new workspace scope')) {
        $del = Invoke-AzRestMethod -Path "$monPath/$($names[$k])?api-version=2023-12-01" -Method DELETE
        if ($del.StatusCode -ge 400) { throw "DELETE $($names[$k]) -> HTTP $($del.StatusCode)" }
    }
}
foreach ($d in $deployments) {
    if ($Execute) {
        $r = New-AzResourceGroupDeployment @d -WhatIf:$false
        if ($r.ProvisioningState -ne 'Succeeded') { throw "$($d.Name): $($r.ProvisioningState)" }
    }
    else { New-AzResourceGroupDeployment @d -WhatIf }
}

$rows = [System.Collections.Generic.List[object]]::new()
if ($Execute) {
    $sub = [string]$lz.subscription_id_avd
    $dcr = (Invoke-AzRestMethod -Path "/subscriptions/$sub/resourceGroups/$($names['rg_mon'])/providers/Microsoft.Insights/dataCollectionRules/$($names['dcr_avd_insights'])?api-version=2023-03-11").Content | ConvertFrom-Json
    $dest = @($dcr.properties.destinations.logAnalytics | ForEach-Object { $_.workspaceResourceId })
    $rows.Add([pscustomobject]@{ item = $names['dcr_avd_insights']; readBack = (($dest | ForEach-Object { ($_ -split '/')[-1] }) -join ','); ok = ($dest -contains $lawId) })
    foreach ($k in 'alert_hostunavailable', 'alert_fslogixerror', 'alert_connfail') {
        $a = (Invoke-AzRestMethod -Path "/subscriptions/$sub/resourceGroups/$($names['rg_mon'])/providers/Microsoft.Insights/scheduledQueryRules/$($names[$k])?api-version=2023-12-01").Content | ConvertFrom-Json
        $rows.Add([pscustomobject]@{ item = $names[$k]; readBack = "scope=$(($a.properties.scopes[0] -split '/')[-1]) enabled=$($a.properties.enabled)"; ok = ($a.properties.scopes -contains $lawId) })
    }
    foreach ($res in @(@{ t = 'workspaces'; n = $workspaceName }) + @($hostPools | ForEach-Object { @{ t = 'hostPools'; n = $_ } }) + @($scalingPlans | ForEach-Object { @{ t = 'scalingPlans'; n = $_ } })) {
        $id = "/subscriptions/$sub/resourceGroups/$($names['rg_control'])/providers/Microsoft.DesktopVirtualization/$($res.t)/$($res.n)"
        $ds = ((Invoke-AzRestMethod -Path "$id/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview").Content | ConvertFrom-Json).value
        $hit = @($ds | Where-Object { $_.properties.workspaceId -eq $lawId })
        $rows.Add([pscustomobject]@{ item = "$($res.n) diagnostics"; readBack = "$($hit.Count) setting(s) to $(($lawId -split '/')[-1])"; ok = ($hit.Count -ge 1) })
    }
    $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Information -InformationAction Continue
    if (@($rows | Where-Object { -not $_.ok }).Count -gt 0) { throw 'Read-back failed (see table).' }
}
return $rows
