#Requires -Version 7.0
<#
.SYNOPSIS
    Routes a demo user to another realm (outline §8 steps 2-3): moves the user between the realm groups that are
    assigned to each realm's desktop application group. -WhatIf is the default; fully reversible.
.DESCRIPTION
    Group mode (default, how the lab assigns app groups): the user is added to grp-...-avd-<target> and removed from
    the other realm groups (Microsoft Graph). Direct mode: the 'Desktop Virtualization User' role is assigned on the
    target realm's application group and removed from the other two (Az RBAC). Idempotent: a user already routed to
    the target and nowhere else is reported as "no change". The UNDO command (same script with the previous realm,
    or -RemoveOnly when the user had none) is printed first.
.PARAMETER UserPrincipalName
    The demo user.
.PARAMETER TargetRealm
    azure | azl | hybrid
.PARAMETER RemoveOnly
    Remove the user from every realm instead (undo of a first assignment).
.PARAMETER Mode
    Group | Direct
.PARAMETER Execute
    Apply the change.
.PARAMETER PassThru
    Return { User, PreviousRealms, TargetRealm, Changed }.
.EXAMPLE
    ./Switch-UserHostPool.ps1 -UserPrincipalName user1@contoso.com -TargetRealm azl -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[^@\s]+@[^@\s]+$')]
    [string] $UserPrincipalName,

    [Parameter()]
    [ValidateSet('azure', 'azl', 'hybrid')]
    [string] $TargetRealm,

    [switch] $RemoveOnly,

    [Parameter()]
    [ValidateSet('Group', 'Direct')]
    [string] $Mode = 'Group',

    [switch] $Execute,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoCommon = Join-Path $PSScriptRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1'
if (-not (Get-Module -Name DemoCommon)) { Import-Module $demoCommon -Global }

if (-not $TargetRealm -and -not $RemoveOnly) { throw 'Give -TargetRealm azure|azl|hybrid, or -RemoveOnly.' }
if ($TargetRealm -and $RemoveOnly) { throw '-TargetRealm and -RemoveOnly are exclusive.' }

$config = Get-DemoConfig -Scope 'avd'
Initialize-DemoScreenHygiene -Config $config
Add-DemoHiddenTerm -Term (($UserPrincipalName -split '@')[1])
$names = Get-DemoAvdNameSet -Config $config
$realms = @('azure', 'azl', 'hybrid')

# current routing
$current = @()
$userId = ''
$groupIds = @{}
if ($Mode -eq 'Group') {
    $userId = Get-DemoUserId -UserPrincipalName $UserPrincipalName
    foreach ($r in $realms) {
        $groupName = $names.Realms[$r].Group
        if (-not $groupName) { throw "No entra_groups.avd_$r in the environment file." }
        $groupIds[$r] = Get-DemoGroupId -DisplayName $groupName
        if ($userId -in @(Get-DemoGroupMemberIdList -GroupId $groupIds[$r])) { $current += $r }
    }
}
else {
    foreach ($r in $realms) {
        if ($UserPrincipalName -in @(Get-DemoAppGroupAssignmentList -ResourceGroupName $names.HostPoolResourceGroup -AppGroupName $names.Realms[$r].AppGroup)) { $current += $r }
    }
}

$undo = if ($current.Count -gt 0) { ('{0} -UserPrincipalName {1} -TargetRealm {2} -Mode {3} -Execute' -f (Join-Path $PSScriptRoot 'Switch-UserHostPool.ps1'), $UserPrincipalName, $current[0], $Mode) } else { ('{0} -UserPrincipalName {1} -RemoveOnly -Mode {2} -Execute' -f (Join-Path $PSScriptRoot 'Switch-UserHostPool.ps1'), $UserPrincipalName, $Mode) }
Write-DemoUndo -Command $undo

$toAdd = @()
$toRemove = @()
if ($RemoveOnly) { $toRemove = $current }
else {
    if ($TargetRealm -notin $current) { $toAdd = @($TargetRealm) }
    $toRemove = @($current | Where-Object { $_ -ne $TargetRealm })
}
$result = [pscustomobject]@{ User = $UserPrincipalName; Mode = $Mode; PreviousRealms = $current; TargetRealm = $(if ($RemoveOnly) { '' } else { $TargetRealm }); Added = $toAdd; Removed = $toRemove; Changed = $false }

Write-DemoScreen -InputObject ('user currently routed to: {0}' -f $(if ($current.Count -gt 0) { $current -join ', ' } else { 'no realm' }))
$planLines = @($toRemove | ForEach-Object { "remove from $_ ($(if ($Mode -eq 'Group') { $names.Realms[$_].Group } else { $names.Realms[$_].AppGroup }))" }) + @($toAdd | ForEach-Object { "add to $_ ($(if ($Mode -eq 'Group') { $names.Realms[$_].Group } else { $names.Realms[$_].AppGroup }))" })
if ($planLines.Count -eq 0) {
    Write-DemoScreen -InputObject 'No change: the user is already routed exactly as requested.' -Raw
    if ($PassThru) { return $result }
    return
}
if (-not $Execute) {
    Write-DemoPlan -Lines $planLines -ScriptName 'Switch-UserHostPool.ps1'
    if ($PassThru) { return $result }
    return
}

# Add first, then remove: if the add fails the user keeps the old route instead of being left with none.
foreach ($r in $toAdd) {
    if ($PSCmdlet.ShouldProcess($UserPrincipalName, "add to realm $r")) {
        if ($Mode -eq 'Group') { Add-DemoGroupMember -GroupId $groupIds[$r] -UserId $userId }
        else { Add-DemoAppGroupAssignment -ResourceGroupName $names.HostPoolResourceGroup -AppGroupName $names.Realms[$r].AppGroup -UserPrincipalName $UserPrincipalName }
        $result.Changed = $true
    }
}
foreach ($r in $toRemove) {
    if ($PSCmdlet.ShouldProcess($UserPrincipalName, "remove from realm $r")) {
        if ($Mode -eq 'Group') { Remove-DemoGroupMember -GroupId $groupIds[$r] -UserId $userId }
        else { Remove-DemoAppGroupAssignment -ResourceGroupName $names.HostPoolResourceGroup -AppGroupName $names.Realms[$r].AppGroup -UserPrincipalName $UserPrincipalName }
        $result.Changed = $true
    }
}
Write-DemoScreen -InputObject ('Routed {0} -> {1}. Group/role changes take effect at the next Windows App feed refresh (sign out, refresh, sign in).' -f $UserPrincipalName, $(if ($RemoveOnly) { 'no realm' } else { $TargetRealm }))
Write-DemoUndo -Command $undo
if ($PassThru) { return $result }
