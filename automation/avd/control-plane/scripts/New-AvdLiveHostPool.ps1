#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.DesktopVirtualization, powershell-yaml
<#
.SYNOPSIS
    Live demo (owner, 14 Oct): creates a host pool, its desktop application group and the workspace registration, the same
    objects the portal's "Create a host pool" wizard creates, next to the pre-deployed pools. -Remove deletes them again.
.DESCRIPTION
    Inputs (G5, nothing lab-specific in this file): environment/avd/environment.yml
      subscription_id_avd, live_host_pool { name, app_group_name, workspace_name, resource_group, type, load_balancer,
      max_session_limit, friendly_name, tags }
    Steps, each idempotent and printed as it runs (the presenter talks over them):
      1. Host pool (Pooled, the configured load balancer and session limit), in the workspace's region.
      2. Desktop application group for the pool.
      3. The application group added to the workspace's references (existing references kept).
    The pool gets no user assignment, so it never appears in a feed, and no session hosts. Runs as the signed-in account
    (the presenter on stage; a managed identity or service principal in a pipeline). Default is a plan; -Execute creates.
.PARAMETER EnvironmentFile
    The AVD environment file (default: <repo>/environment/avd/environment.yml).
.PARAMETER Remove
    Delete the live pool and its application group and remove the reference from the workspace (after the event).
.PARAMETER Execute
    Make the changes. Without it the script prints what it would do.
.EXAMPLE
    ./New-AvdLiveHostPool.ps1 -Execute
.EXAMPLE
    ./New-AvdLiveHostPool.ps1 -Remove -Execute
#>
[CmdletBinding()]
param(
    [string]$EnvironmentFile,
    [switch]$Remove,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
if (-not $EnvironmentFile) { $EnvironmentFile = Join-Path $repo 'environment\avd\environment.yml' }
$env = Get-Content -Raw -Path $EnvironmentFile | ConvertFrom-Yaml
$c = $env.live_host_pool
if (-not $c) { throw "live_host_pool is missing in $EnvironmentFile" }
function Step([string]$m) { Write-Information -MessageData "[live-host-pool] $m" -InformationAction Continue }

$null = Set-AzContext -Subscription $env.subscription_id_avd -Scope Process -WhatIf:$false
$ws = Get-AzWvdWorkspace -ResourceGroupName $c.resource_group -Name $c.workspace_name
$sub = $env.subscription_id_avd
$agId = "/subscriptions/$sub/resourceGroups/$($c.resource_group)/providers/Microsoft.DesktopVirtualization/applicationGroups/$($c.app_group_name)"
$refs = @($ws.ApplicationGroupReference | Where-Object { $_ })

if ($Remove) {
    Step "Remove: $($c.app_group_name) from $($c.workspace_name), then the application group and $($c.name)"
    if (-not $Execute) { Step 'Plan only. Run with -Execute to delete.'; return }
    $keep = @($refs | Where-Object { $_ -ne $agId })
    if ($keep.Count -ne $refs.Count) { $null = Update-AzWvdWorkspace -ResourceGroupName $c.resource_group -Name $c.workspace_name -ApplicationGroupReference $keep }
    if (Get-AzWvdApplicationGroup -ResourceGroupName $c.resource_group -Name $c.app_group_name -ErrorAction SilentlyContinue) { Remove-AzWvdApplicationGroup -ResourceGroupName $c.resource_group -Name $c.app_group_name }
    if (Get-AzWvdHostPool -ResourceGroupName $c.resource_group -Name $c.name -ErrorAction SilentlyContinue) { Remove-AzWvdHostPool -ResourceGroupName $c.resource_group -Name $c.name -Force }
    Step 'Removed.'
    return
}

Step "1. Host pool $($c.name): $($c.type), $($c.load_balancer), up to $($c.max_session_limit) sessions per host, region $($ws.Location)"
Step "2. Desktop application group $($c.app_group_name)"
Step "3. Register it in workspace $($c.workspace_name) ($($refs.Count) groups there now)"
if (-not $Execute) { Step 'Plan only. Run with -Execute to create.'; return }

$tags = @{}; foreach ($k in $c.tags.Keys) { $tags[$k] = [string]$c.tags[$k] }
$hp = Get-AzWvdHostPool -ResourceGroupName $c.resource_group -Name $c.name -ErrorAction SilentlyContinue
if (-not $hp) {
    $hp = New-AzWvdHostPool -ResourceGroupName $c.resource_group -Name $c.name -Location $ws.Location -HostPoolType $c.type -LoadBalancerType $c.load_balancer `
        -MaxSessionLimit ([int]$c.max_session_limit) -PreferredAppGroupType Desktop -FriendlyName $c.friendly_name -Tag $tags
}
Step "   host pool: $($hp.Id)"
$ag = Get-AzWvdApplicationGroup -ResourceGroupName $c.resource_group -Name $c.app_group_name -ErrorAction SilentlyContinue
if (-not $ag) {
    $ag = New-AzWvdApplicationGroup -ResourceGroupName $c.resource_group -Name $c.app_group_name -Location $ws.Location -HostPoolArmPath $hp.Id `
        -ApplicationGroupType Desktop -FriendlyName $c.friendly_name -Tag $tags
}
Step "   application group: $($ag.Id)"
if ($refs -notcontains $ag.Id) { $null = Update-AzWvdWorkspace -ResourceGroupName $c.resource_group -Name $c.workspace_name -ApplicationGroupReference (@($refs) + $ag.Id) }
Step "   workspace $($c.workspace_name) now references $(@((Get-AzWvdWorkspace -ResourceGroupName $c.resource_group -Name $c.workspace_name).ApplicationGroupReference).Count) application groups"
Step 'Done. Next: add session hosts to it (portal: Session hosts > Add, or the session host scripts).'
