#Requires -Version 7.0
<#
.SYNOPSIS
    Forced session-host failure for one realm (outline §8 step 4; hybrid design §12). -WhatIf is the default; -Execute
    required; preflight demands a second host Available in the pool.
.DESCRIPTION
    Prints the UNDO command first, then the preflight: the host exists in the realm's pool, at least one OTHER host is
    Available and accepting sessions, no SessionHost fault is already active. With -Execute:
      azure  - Stop-AzVM (deallocate) of the Azure VM (the platform brings it back: Start VM on Connect / Restore-SessionHost)
      azl    - az stack-hci-vm stop of the Azure Local VM (Arc)
      hybrid - Stop-VM -TurnOff on the owner node over PowerShell remoting (hard power-off; the clustered role goes
               Offline, not Failed, so neither the cluster nor AVD restarts it - Restore-SessionHost does)
    Records a SessionHost fault lock and waits until the host shows Unavailable. Prints the FSLogix stale-handle hint.
.PARAMETER Realm
    azure | azl | hybrid
.PARAMETER HostName
    Session host short name (e.g. avd-hv01).
.PARAMETER ResourceGroupName
    VM resource group (azure: hosts RG; azl: the Azure Local VM RG) - default from the naming standard / environment file.
.PARAMETER VmName
    VM resource name for the azure and azl realms (default: derived from the host number, for example nic26-avd-az01 -> vm-iic-nic26-avd-az-eus-01). The session-host name is the computer name, not the VM resource name.
.PARAMETER ComputerName
    Remoting target for hybrid (default: the VM's owner node from the environment file).
.PARAMETER Execute
    Perform the failure.
.PARAMETER PassThru
    Return the plan/result object.
.EXAMPLE
    ./Stop-SessionHost.ps1 -Realm hybrid -HostName avd-hv01 -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [ValidateSet('azure', 'azl', 'hybrid')]
    [string] $Realm,

    [Parameter(Mandatory)]
    [string] $HostName,

    [Parameter()]
    [string] $ResourceGroupName,

    [Parameter()]
    [string] $ComputerName,

    [Parameter()]
    [string] $VmName,

    [switch] $Execute,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoCommon = Join-Path $PSScriptRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1'
if (-not (Get-Module -Name DemoCommon)) { Import-Module $demoCommon -Global }

$config = Get-DemoConfig -Scope 'avd'
Initialize-DemoScreenHygiene -Config $config
$names = Get-DemoAvdNameSet -Config $config
$pool = $names.Realms[$Realm].HostPool
if (-not $ResourceGroupName) {
    $ResourceGroupName = switch ($Realm) {
        'azure' { $names.HostsResourceGroup }
        'azl' { $names.AzlHostsResourceGroup }
        default { '' }
    }
}
if ($Realm -ne 'hybrid' -and -not $VmName) {
    # The session-host name is the computer name; the Azure and Azure Local VM resource names carry the standard prefix and region.
    $hostNumber = [regex]::Match($HostName, '(\d+)$')
    if (-not $hostNumber.Success) { throw "Cannot derive the VM resource name from '$HostName'; pass -VmName." }
    $VmName = & $names.VmName $Realm ([int]$hostNumber.Groups[1].Value)
}
if ($Realm -eq 'hybrid' -and -not $ComputerName) {
    $vm = @(Get-DemoConfigValue -Config $config -Key 'hybrid.vms' | Where-Object { (Get-DemoConfigValue -Config $_ -Key 'name') -eq $HostName }) | Select-Object -First 1
    if ($vm) { $ComputerName = [string](Get-DemoConfigValue -Config $vm -Key 'owner_node') }
    if (-not $ComputerName) { throw "No owner_node for '$HostName' in hybrid.vms; pass -ComputerName." }
}

Write-DemoUndo -Command ('{0} -Realm {1} -HostName {2} -Execute' -f (Join-Path $PSScriptRoot 'Restore-SessionHost.ps1'), $Realm, $HostName)

# preflight
$hosts = @(Get-DemoSessionHostList -ResourceGroupName $names.HostPoolResourceGroup -HostPoolName $pool)
$target = @($hosts | Where-Object { $_.Name -eq $HostName }) | Select-Object -First 1
$others = @($hosts | Where-Object { $_.Name -ne $HostName -and $_.Status -eq 'Available' -and $_.AllowNewSession })
$locks = @(Get-DemoFaultLock -Scope 'avd' | Where-Object { $_.Fault -eq 'SessionHost' })
$checks = @(
    New-DemoCheck -Section "preflight/$Realm" -Name "Host $HostName is in $pool" -Passed ($null -ne $target) -Detail $(if ($target) { "status $($target.Status), $($target.Sessions) session(s)" } else { 'not found' })
    New-DemoCheck -Section "preflight/$Realm" -Name 'A second host is Available and accepting sessions' -Passed ($others.Count -ge 1) -Detail $(if ($others.Count -ge 1) { (@($others | ForEach-Object { $_.Name }) -join ', ') } else { 'no other Available host -> the user would have nowhere to land' })
    New-DemoCheck -Section "preflight/$Realm" -Name 'No session-host fault already active' -Passed ($locks.Count -eq 0) -Detail $(if ($locks.Count -eq 0) { 'clean' } else { (@($locks | ForEach-Object { "$($_.Target) since $($_.StartedAt)" }) -join '; ') })
)
Write-DemoCheckTable -Check $checks -Title ('Session-host failure preflight: {0}/{1}' -f $Realm, $HostName)
if ((Get-DemoCheckExitCode -Check $checks) -ne 0) { throw 'REFUSED: the pool cannot absorb a host failure right now (see the table). Nothing was changed.' }

$method = switch ($Realm) {
    'azure' { "Stop-AzVM -Force (deallocate) $ResourceGroupName/$VmName" }
    'azl' { "az stack-hci-vm stop $ResourceGroupName/$VmName" }
    'hybrid' { "Stop-VM -TurnOff -Force '$HostName' on node $ComputerName (hard power-off)" }
}
$plan = [pscustomobject]@{ Fault = 'SessionHost'; Realm = $Realm; Host = $HostName; Method = $method; Executed = $false }
$planLines = @(
    "fault   : forced failure of $HostName in realm $Realm",
    "method  : $method",
    'expect  : session drops; host Unavailable in ~1-2 min; user reconnects and lands on the other host with the same FSLogix profile',
    $(if ($Realm -eq 'hybrid') { 'note    : AVD does NOT restart this VM; the operator does (Restore-SessionHost.ps1)' } else { 'note    : the platform owns the VM lifecycle in this realm' })
)
if (-not $Execute) {
    Write-DemoPlan -Lines $planLines -ScriptName 'Stop-SessionHost.ps1'
    if ($PassThru) { return $plan }
    return
}

if ($PSCmdlet.ShouldProcess("$Realm/$HostName", $method)) {
    # Lock first: a host that was stopped but never recorded would leave the Restore with nothing to read and let a second fault start.
    $null = New-DemoFaultLock -Fault SessionHost -Target $HostName -Scope 'avd' -Detail @{ Realm = $Realm; ResourceGroupName = $ResourceGroupName; VmName = $VmName; ComputerName = $ComputerName; Method = $method }
    try {
        switch ($Realm) {
            'azure' { Stop-DemoAzureVM -ResourceGroupName $ResourceGroupName -Name $VmName }
            'azl' { Stop-DemoArcVM -ResourceGroupName $ResourceGroupName -Name $VmName }
            'hybrid' { Stop-DemoHyperVVM -ComputerName $ComputerName -Name $HostName }
        }
    }
    catch {
        throw ("The stop outcome for {0} is unknown ({1}). The fault lock is KEPT. Restore it: {2} -Realm {3} -HostName {0} -Execute" -f $HostName, (($_.Exception.Message -replace '\s+', ' ')), (Join-Path $PSScriptRoot 'Restore-SessionHost.ps1'), $Realm)
    }
    $plan.Executed = $true
    Write-DemoScreen -InputObject ('{0} failed on purpose. Waiting for AVD to mark it Unavailable...' -f $HostName)
    $unavailable = Wait-DemoCondition -TimeoutMinutes 5 -IntervalSeconds 15 -Activity "$HostName Unavailable" -Condition {
        @(Get-DemoSessionHostList -ResourceGroupName $names.HostPoolResourceGroup -HostPoolName $pool | Where-Object { $_.Name -eq $HostName -and $_.Status -ne 'Available' }).Count -eq 1
    }
    Get-DemoSessionHostList -ResourceGroupName $names.HostPoolResourceGroup -HostPoolName $pool | Format-Table -Property Name, Status, Sessions, AllowNewSession, LastHeartBeat -AutoSize | Out-String | Write-DemoScreen
    if (-not $unavailable) { Write-Warning 'AVD has not marked the host Unavailable yet (heartbeat timeout is ~2 min); keep Show-AvdState.ps1 open.' }
    Write-DemoScreen -InputObject 'Now: user reconnects in Windows App -> lands on the other host, file and setting present. If sign-in is blocked by a stale profile handle: Close-AzStorageFileHandle -ShareName <profiles share> -Path <user folder> -CloseAll (see README).' -Raw
    Write-DemoUndo -Command ('{0} -Realm {1} -HostName {2} -Execute' -f (Join-Path $PSScriptRoot 'Restore-SessionHost.ps1'), $Realm, $HostName)
}
if ($PassThru) { return $plan }
