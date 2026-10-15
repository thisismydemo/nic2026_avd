#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.DesktopVirtualization, powershell-yaml
<#
.SYNOPSIS
    Sets the names users see in the Windows App feed (owner, 14 Oct): the workspace name and, per host pool, the desktop
    application group's name and the desktop's name (instead of the default "SessionDesktop"). Idempotent; default is a
    plan, -Execute applies.
.DESCRIPTION
    Inputs (G5): environment/avd/environment.yml - subscription_id_avd, tenant_id, workspace_friendly_name,
    host_pools.<key>.desktop_name (and friendly_name). The workspace is the one the host pools' application groups are
    registered in; each pool's desktop application group is found by its host pool. Learn: customize the feed,
    https://learn.microsoft.com/azure/virtual-desktop/customize-feed-for-virtual-desktop-users
.PARAMETER EnvironmentFile
    The AVD environment file (default: <repo>/environment/avd/environment.yml).
.PARAMETER Execute
    Apply the names. Without it the script prints current and wanted names.
#>
[CmdletBinding()]
param([string]$EnvironmentFile, [switch]$Execute)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
if (-not $EnvironmentFile) { $EnvironmentFile = Join-Path $repo 'environment\avd\environment.yml' }
$cfg = Get-Content -Raw -Path $EnvironmentFile | ConvertFrom-Yaml
$null = Set-AzContext -Tenant $cfg.tenant_id -Subscription $cfg.subscription_id_avd -Scope Process -WhatIf:$false
$ags = @(Get-AzWvdApplicationGroup -SubscriptionId $cfg.subscription_id_avd | Where-Object ApplicationGroupType -eq 'Desktop')
$rows = foreach ($key in $cfg.host_pools.Keys) {
    $want = [string]$cfg.host_pools[$key].desktop_name
    if (-not $want) { continue }
    $ag = $ags | Where-Object { ($_.HostPoolArmPath -split '/')[-1] -like "*-$key-*" } | Select-Object -First 1
    if (-not $ag) { Write-Warning "No desktop application group for host pool key '$key'."; continue }
    $rg = ($ag.Id -split '/')[4]
    $desk = Get-AzWvdDesktop -ResourceGroupName $rg -ApplicationGroupName $ag.Name | Select-Object -First 1
    $deskName = ($desk.Name -split '/')[-1]
    if ($Execute) {
        if ($desk.FriendlyName -cne $want) { $null = Update-AzWvdDesktop -ResourceGroupName $rg -ApplicationGroupName $ag.Name -Name $deskName -FriendlyName $want }
        if ($ag.FriendlyName -cne $want) { $null = Update-AzWvdApplicationGroup -ResourceGroupName $rg -Name $ag.Name -FriendlyName $want }
    }
    [pscustomobject]@{ Pool = ($ag.HostPoolArmPath -split '/')[-1]; AppGroup = $ag.Name; Desktop = $deskName; Was = $desk.FriendlyName; Now = $(if ($Execute) { (Get-AzWvdDesktop -ResourceGroupName $rg -ApplicationGroupName $ag.Name -Name $deskName).FriendlyName } else { "(plan) $want" }) }
}
$rows | Format-Table -AutoSize | Out-String -Width 220
$wsName = ($ags[0].WorkspaceArmPath -split '/')[-1]; $wsRg = ($ags[0].WorkspaceArmPath -split '/')[4]
if ($wsName -and $cfg.workspace_friendly_name) {
    $ws = Get-AzWvdWorkspace -ResourceGroupName $wsRg -Name $wsName
    if ($Execute -and $ws.FriendlyName -cne $cfg.workspace_friendly_name) { $null = Update-AzWvdWorkspace -ResourceGroupName $wsRg -Name $wsName -FriendlyName $cfg.workspace_friendly_name }
    "workspace $wsName : was '$($ws.FriendlyName)' -> $(if ($Execute) { "'" + (Get-AzWvdWorkspace -ResourceGroupName $wsRg -Name $wsName).FriendlyName + "'" } else { "(plan) '$($cfg.workspace_friendly_name)'" })"
}
