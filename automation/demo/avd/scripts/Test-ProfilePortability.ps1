#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only evidence for the profile-portability beat (outline §8 step 3, §6.4 option A): the user's FSLogix
    container(s) in the share, last write, open handles, and the host pools the user signed in to. No file contents.
.DESCRIPTION
    Lists the user's folder(s) in the profiles and ODFC shares (metadata only: name, size, last modified), open SMB
    handles on them (a stale handle after a hard power-off), active sessions in the three host pools, and the sign-in
    history from AVD Insights (WVDConnections, last -LookbackHours) grouped by host pool. Everything through the
    screen-hygiene filter.
.PARAMETER UserPrincipalName
    The demo user.
.PARAMETER StorageAccountName
    FSLogix storage account (default: st<org><token>fslogix<region>01).
.PARAMETER LookbackHours
    Sign-in history window (default 24).
.PARAMETER SkipInsights
    Skip the Log Analytics query.
.PARAMETER PassThru
    Return the evidence object.
.EXAMPLE
    ./Test-ProfilePortability.ps1 -UserPrincipalName user1@contoso.com
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[^@\s]+@[^@\s]+$')]
    [string] $UserPrincipalName,

    [Parameter()]
    [string] $StorageAccountName,

    [Parameter()]
    [ValidateRange(1, 720)]
    [int] $LookbackHours = 24,

    [switch] $SkipInsights,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoCommon = Join-Path $PSScriptRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1'
if (-not (Get-Module -Name DemoCommon)) { Import-Module $demoCommon -Global }

$config = Get-DemoConfig -Scope 'avd'
Initialize-DemoScreenHygiene -Config $config
Add-DemoHiddenTerm -Term (($UserPrincipalName -split '@')[1])
$names = Get-DemoAvdNameSet -Config $config
if (-not $StorageAccountName) {
    $StorageAccountName = New-NIC26ResourceName -Type st -Purpose 'fslogix' -Org (Get-DemoConfigValue -Config $config -Key 'org') -Token (Get-DemoConfigValue -Config $config -Key 'token') -Region (Get-DemoConfigValue -Config $config -Key 'location_short')
}
$shares = @{
    profiles = [string](Get-DemoConfigValue -Config $config -Key 'share_names.profiles')
    odfc     = [string](Get-DemoConfigValue -Config $config -Key 'share_names.odfc')
}
$userPart = ($UserPrincipalName -split '@')[0]

# containers (metadata only)
$containers = foreach ($kind in $shares.Keys) {
    $share = $shares[$kind]
    if (-not $share) { continue }
    $folders = @(Get-DemoFileShareItemList -StorageAccountName $StorageAccountName -ShareName $share | Where-Object { $_.IsDirectory -and $_.Name -like "*$userPart*" })
    foreach ($folder in $folders) {
        $files = @(Get-DemoFileShareItemList -StorageAccountName $StorageAccountName -ShareName $share -Path $folder.Name | Where-Object { -not $_.IsDirectory -and $_.Name -like '*.vhd*' })
        $handles = @()
        try { $handles = @(Get-DemoFileHandleList -StorageAccountName $StorageAccountName -ShareName $share -Path $folder.Name) } catch { Write-Verbose "handle listing failed: $($_.Exception.Message)" }
        foreach ($f in $files) {
            [pscustomobject]@{ Share = $kind; Folder = $folder.Name; Container = $f.Name; SizeGB = [math]::Round(($f.Length / 1GB), 2); LastModified = $f.LastModified; OpenHandles = $handles.Count }
        }
    }
}
$containers = @($containers)

# active sessions
$sessions = foreach ($r in @('azure', 'azl', 'hybrid')) {
    try { Get-DemoUserSessionList -ResourceGroupName $names.HostPoolResourceGroup -HostPoolName $names.Realms[$r].HostPool | Where-Object { $_.UserPrincipalName -eq $UserPrincipalName } | ForEach-Object { $_ | Add-Member -NotePropertyName Realm -NotePropertyValue $r -PassThru } }
    catch { Write-Verbose "session query failed for $r : $($_.Exception.Message)" }
}
$sessions = @($sessions)

# sign-in history
$history = @()
$wsId = [string](Get-DemoConfigValue -Config $config -Key 'log_analytics_workspace_id')
if (-not $SkipInsights -and $wsId) {
    $query = "WVDConnections | where TimeGenerated > ago({0}h) | where UserName =~ '{1}' | where State == 'Connected' | summarize LastConnected = max(TimeGenerated), Connections = count() by HostPool = tostring(split(_ResourceId, '/')[-1]), SessionHostName" -f $LookbackHours, $UserPrincipalName
    try { $history = @(Invoke-DemoLogQuery -WorkspaceId $wsId -Query $query -TimespanHours $LookbackHours) }
    catch { Write-Verbose "insights query failed: $($_.Exception.Message)" }
}

Write-DemoScreen -InputObject ('== Profile portability evidence for {0} ==' -f $userPart)
Write-DemoScreen -InputObject '-- FSLogix containers (metadata only) --' -Raw
if ($containers.Count -gt 0) { $containers | Format-Table -Property Share, Container, SizeGB, LastModified, OpenHandles -AutoSize | Out-String | Write-DemoScreen } else { Write-DemoScreen -InputObject 'no container found yet (the first sign-in creates it)' -Raw }
Write-DemoScreen -InputObject '-- Active sessions --' -Raw
if ($sessions.Count -gt 0) { $sessions | Format-Table -Property Realm, SessionHost, SessionState -AutoSize | Out-String | Write-DemoScreen } else { Write-DemoScreen -InputObject 'none' -Raw }
Write-DemoScreen -InputObject ('-- Host pools signed in to (last {0} h, AVD Insights) --' -f $LookbackHours) -Raw
if ($history.Count -gt 0) { $history | Format-Table -Property HostPool, SessionHostName, Connections, LastConnected -AutoSize | Out-String | Write-DemoScreen } else { Write-DemoScreen -InputObject $(if ($SkipInsights) { 'skipped' } elseif (-not $wsId) { 'log_analytics_workspace_id empty' } else { 'no connections in the window' }) -Raw }
$realmsSeen = @($history | ForEach-Object { $_.HostPool } | Sort-Object -Unique)
Write-DemoScreen -InputObject ('one profile, {0} container(s), seen in {1} host pool(s): {2}' -f $containers.Count, $realmsSeen.Count, ($realmsSeen -join ', '))
if ($PassThru) { return [pscustomobject]@{ User = $UserPrincipalName; Containers = $containers; Sessions = $sessions; History = $history; HostPoolsSeen = $realmsSeen } }
