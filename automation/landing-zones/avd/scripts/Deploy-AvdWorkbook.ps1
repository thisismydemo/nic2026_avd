#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
    Deploys the Azure Monitor workbook "AVD Anywhere (middle dot) three terminals" (owner, 14 Oct): the three host pools
    side by side over the Log Analytics workspace. Default is a plan (ARM what-if); -Execute deploys and reads back; -Remove deletes.
.DESCRIPTION
    Inputs (G5, nothing environment-specific in this file): environment/avd (+ shared) through Get-NIC26Config and the
    avd-control-plane names catalog:
      tenant_id, subscription_id_avd, log_analytics_workspace_id, host_pools.<realm>.friendly_name,
      computer_name_prefixes.<realm>, names.rg_control, names.hostpool_<realm>, tags
    Template: bicep/modules/workbook-avd-anywhere.bicep, content: workbooks/avd-anywhere.workbook.json (the module fills
    the workspace id and the terminal map). Each realm becomes one terminal: "<friendly_name> (middle dot) <realm label>", e.g.
    "Terminal B (middle dot) Azure Local"; the host pool name and the computer-name prefix decide which rows belong to it.
    The workbook lands in the control-plane resource group (AVD subscription), kind shared, with a deterministic name, so
    a re-run updates it in place. Tags: the control-plane tags (the environment project tag) plus workload, managed-by and purpose.
    Steps, printed as they run:
      1. What-if (plan) or deployment of the module (-Execute).
      2. Read-back: the workbook resource, its tags, and the portal path.
.PARAMETER RealmLabels
    The second half of each terminal label, per realm key (default azure=Azure, azl=Azure Local, hybrid=Hybrid).
.PARAMETER DisplayName
    The workbook name in the gallery (default: "AVD Anywhere (middle dot) three terminals").
.PARAMETER Remove
    Delete the workbook (after the event).
.PARAMETER Execute
    Make the change. Without it the script runs the what-if (or, with -Remove, prints what it would delete).
.EXAMPLE
    ./Deploy-AvdWorkbook.ps1            # what-if
.EXAMPLE
    ./Deploy-AvdWorkbook.ps1 -Execute   # deploy + read back
.EXAMPLE
    ./Deploy-AvdWorkbook.ps1 -Remove -Execute
#>
[CmdletBinding(SupportsShouldProcess)]
[OutputType([pscustomobject])]
param(
    [hashtable]$RealmLabels = @{ azure = 'Azure'; azl = 'Azure Local'; hybrid = 'Hybrid' },
    [string]$DisplayName = "AVD Anywhere $([char]0x00B7) three terminals",
    [switch]$Remove,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Execute) { $WhatIfPreference = $true }
function Step([string]$m) { Write-Information -MessageData "[avd-workbook] $m" -InformationAction Continue }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
Import-Module (Join-Path $repoRoot 'automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1') -Force
$config = Get-NIC26Config -Scope avd
$v = $config.values
$nc = Get-NIC26NamingContext -Config $config
$cp = ConvertTo-NIC26TfVars -Solution (Join-Path $repoRoot 'automation\avd\control-plane') -Config $config | ConvertFrom-Json -Depth 50
$sub = [string]$v['subscription_id_avd']
$lawId = [string]$v['log_analytics_workspace_id']
$rg = [string]$cp.names.rg_control
if (-not $sub -or -not $lawId -or -not $rg) { throw 'environment/avd needs subscription_id_avd and log_analytics_workspace_id; the control-plane catalog needs rg_control.' }

# Pin the context for this process only (tenant + AVD subscription).
$ctx = Get-AzContext
if (-not $ctx -or $ctx.Tenant.Id -ne [string]$v['tenant_id'] -or $ctx.Subscription.Id -ne $sub) {
    [void](Set-AzContext -Tenant ([string]$v['tenant_id']) -Subscription $sub -Scope Process -WhatIf:$false)
}

# One terminal per realm in host_pools: host pool name, computer-name prefix, label.
$terminals = foreach ($realm in $v['host_pools'].Keys) {
    $pool = [string]$cp.names."hostpool_$realm"
    $prefix = [string]$v['computer_name_prefixes'][$realm]
    $label = '{0} {2} {1}' -f [string]$v['host_pools'][$realm]['friendly_name'], ($RealmLabels[$realm] ?? $realm), [char]0x00B7
    if (-not $pool -or -not $prefix) { throw "Realm '$realm': no host pool name (names.hostpool_$realm) or computer_name_prefixes.$realm." }
    if ("$pool$prefix$label".Contains("'")) { throw "Realm '$realm': a single quote in the pool, prefix or label breaks the KQL map." }
    [ordered]@{ pool = $pool; prefix = $prefix; label = $label }
}
$tags = @{}; foreach ($p in $cp.tags.PSObject.Properties) { $tags[$p.Name] = [string]$p.Value }
if ($nc.Project) { $tags['project'] = $nc.Project }; $tags['workload'] = 'avd'; $tags['managed-by'] = 'bicep'; $tags['purpose'] = 'monitoring-workbook'

$template = Join-Path $PSScriptRoot '..\bicep\modules\workbook-avd-anywhere.bicep'
$deployment = @{
    ResourceGroupName       = $rg
    Name                    = New-NIC26ResourceName -Type dep -Purpose 'avd-workbook' -Org $nc.Org -Token $nc.Token
    TemplateFile            = $template
    TemplateParameterObject = @{ tags = $tags; display_name = $DisplayName; log_analytics_workspace_id = $lawId; terminals = @($terminals) }
}
# Same name the module computes: guid(resourceGroup().id, 'workbook-avd-anywhere-three-terminals'), read from the
# deployment outputs after -Execute; for -Remove it is found by display name in the resource group.
$findWorkbook = {
    Get-AzResource -ResourceGroupName $rg -ResourceType 'Microsoft.Insights/workbooks' -ExpandProperties -ErrorAction SilentlyContinue |
        Where-Object { $_.Properties.displayName -eq $DisplayName }
}

Step "Workbook '$DisplayName' in $rg (subscription $sub), source: $(($lawId -split '/')[-1])"
foreach ($t in $terminals) { Step "   $($t.label): host pool $($t.pool), hosts $($t.prefix)*" }

if ($Remove) {
    $wb = @(& $findWorkbook)
    if ($wb.Count -eq 0) { Step 'Nothing to remove.'; return }
    foreach ($w in $wb) {
        if ($PSCmdlet.ShouldProcess($w.ResourceId, 'delete workbook')) { Remove-AzResource -ResourceId $w.ResourceId -Force -WhatIf:$false | Out-Null; Step "Removed $($w.ResourceId)" }
    }
    return
}

if (-not $Execute) {
    Step '1. What-if (plan only; run with -Execute to deploy).'
    New-AzResourceGroupDeployment @deployment -WhatIf
    return
}

Step '1. Deploying.'
$r = $null
if ($PSCmdlet.ShouldProcess($rg, 'deploy workbook-avd-anywhere.bicep')) {
    $r = New-AzResourceGroupDeployment @deployment -WhatIf:$false
    if ($r.ProvisioningState -ne 'Succeeded') { throw "$($deployment.Name): $($r.ProvisioningState)" }
}
$id = [string]$r.Outputs['workbook_id'].Value

Step '2. Read-back.'
$res = Get-AzResource -ResourceId $id -ExpandProperties
# The project tag is in the template; the merge keeps it on resources tagged by hand later as well.
if ($nc.Project -and $res.Tags['project'] -ne $nc.Project) { [void](Update-AzTag -ResourceId $id -Tag @{ project = $nc.Project } -Operation Merge -WhatIf:$false) }
$row = [pscustomobject]@{
    workbook    = $res.Properties.displayName
    id          = $id
    kind        = $res.Kind
    source      = ($res.Properties.sourceId -split '/')[-1]
    project_tag = (Get-AzResource -ResourceId $id).Tags['project']
    portal      = "https://portal.azure.com/#@$([string]$v['tenant_id'])/resource$id/overview"
    path        = "Resource group $rg > $DisplayName > Open Workbook; or Log Analytics workspace $(($lawId -split '/')[-1]) > Workbooks"
}
$row | Format-List | Out-String -Width 220 | Write-Information -InformationAction Continue
if ($row.source -ne ($lawId -split '/')[-1] -or ($nc.Project -and $row.project_tag -ne $nc.Project)) { throw 'Read-back failed: source or project tag is not as deployed.' }
return $row
