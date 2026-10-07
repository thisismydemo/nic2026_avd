#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only on-stage view (outline §0 and §8 step 1): the workspace, the three host pools, every session host
    Available/Unavailable and the active sessions - through the screen-hygiene filter.
.DESCRIPTION
    Az.DesktopVirtualization reads only. -Count/-IntervalSeconds refresh the view during the failure beat.
.PARAMETER Count
    Refreshes (default 1).
.PARAMETER IntervalSeconds
    Seconds between refreshes (default 20).
.PARAMETER PassThru
    Return the snapshot object(s).
.EXAMPLE
    ./Show-AvdState.ps1 -Count 15 -IntervalSeconds 20
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter()]
    [ValidateRange(1, 1000)]
    [int] $Count = 1,

    [Parameter()]
    [ValidateRange(5, 3600)]
    [int] $IntervalSeconds = 20,

    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoCommon = Join-Path $PSScriptRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1'
if (-not (Get-Module -Name DemoCommon)) { Import-Module $demoCommon -Global }

$config = Get-DemoConfig -Scope 'avd'
Initialize-DemoScreenHygiene -Config $config
$names = Get-DemoAvdNameSet -Config $config
$friendly = @{}
foreach ($r in @('azure', 'azl', 'hybrid')) { $friendly[$r] = [string](Get-DemoConfigValue -Config $config -Key "host_pools.$r.friendly_name") }

$snapshots = for ($i = 1; $i -le $Count; $i++) {
    $workspace = $null
    try { $workspace = Get-DemoWorkspace -ResourceGroupName $names.HostPoolResourceGroup -Name $names.Workspace } catch { Write-Verbose "workspace: $($_.Exception.Message)" }
    $pools = foreach ($r in @('azure', 'azl', 'hybrid')) {
        $hp = $null
        $hosts = @()
        $sessions = @()
        try {
            $hp = Get-DemoHostPool -ResourceGroupName $names.HostPoolResourceGroup -Name $names.Realms[$r].HostPool
            $hosts = @(Get-DemoSessionHostList -ResourceGroupName $names.HostPoolResourceGroup -HostPoolName $names.Realms[$r].HostPool)
            $sessions = @(Get-DemoUserSessionList -ResourceGroupName $names.HostPoolResourceGroup -HostPoolName $names.Realms[$r].HostPool)
        }
        catch { Write-Verbose "pool $r : $($_.Exception.Message)" }
        [pscustomobject]@{ Realm = $r; Friendly = $friendly[$r]; HostPool = $names.Realms[$r].HostPool; Exists = ($null -ne $hp); Hosts = $hosts; Sessions = $sessions }
    }
    $locks = @(Get-DemoFaultLock -Scope 'avd')

    Write-DemoScreen -InputObject ('== AVD Anywhere - {0:HH:mm:ss} UTC ({1}/{2}) ==' -f [DateTime]::UtcNow, $i, $Count)
    Write-DemoScreen -InputObject ('workspace {0}: {1} app group(s)' -f $names.Workspace, $(if ($workspace) { $workspace.AppGroupCount } else { 'not found' }))
    foreach ($p in $pools) {
        $avail = @($p.Hosts | Where-Object { $_.Status -eq 'Available' }).Count
        Write-DemoScreen -InputObject ('-- {0} [{1}] {2}: {3} host(s), {4} Available, {5} active session(s) --' -f $p.Realm, $p.Friendly, $p.HostPool, $p.Hosts.Count, $avail, @($p.Sessions | Where-Object { $_.SessionState -eq 'Active' }).Count)
        if ($p.Hosts.Count -gt 0) { $p.Hosts | Format-Table -Property Name, Status, Sessions, AllowNewSession, LastHeartBeat -AutoSize | Out-String | Write-DemoScreen }
        if ($p.Sessions.Count -gt 0) { $p.Sessions | Format-Table -Property UserPrincipalName, SessionHost, SessionState -AutoSize | Out-String | Write-DemoScreen }
    }
    if ($locks.Count -gt 0) { Write-DemoScreen -InputObject ('ACTIVE FAULT: ' + (@($locks | ForEach-Object { "$($_.Fault) on $($_.Target)" }) -join '; ')) }
    [pscustomobject]@{ Workspace = $workspace; Pools = $pools; FaultLocks = $locks }
    if ($i -lt $Count) { Start-DemoSleep -Seconds $IntervalSeconds }
}
if ($PassThru) { return $snapshots }
