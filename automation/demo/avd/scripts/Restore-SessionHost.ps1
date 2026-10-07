#Requires -Version 7.0
<#
.SYNOPSIS
    Brings a failed session host back (reverse of Stop-SessionHost) and tells the presenter who did it. -WhatIf default.
.DESCRIPTION
    Reads the SessionHost fault lock (or -Realm/-HostName), prints the plan, and with -Execute:
      azure  - Start-AzVM
      azl    - az stack-hci-vm start
      hybrid - Start-ClusterGroup on the cluster: the clustered VM role was Offline (an administrator turned the VM
               off), so the cluster did not restart it and AVD never would. The script says this explicitly on screen.
    Waits until the host is Available again (AVD agent re-registers with its stored registration; no token needed),
    then clears the fault lock. Idempotent.
.PARAMETER Realm
    azure | azl | hybrid (default: from the lock).
.PARAMETER HostName
    Session host short name (default: from the lock).
.PARAMETER ResourceGroupName
    VM resource group (default: from the lock / naming standard).
.PARAMETER VmName
    VM resource name for the azure and azl realms (default: from the lock, else derived from the host number, for example nic26-avd-az01 -> vm-iic-nic26-avd-az-eus-01).
.PARAMETER ComputerName
    Hybrid: cluster or node to run Start-ClusterGroup on (default: from the lock / environment file).
.PARAMETER TimeoutMinutes
    Wait for Available (default 15).
.PARAMETER Execute
    Perform the restore.
.PARAMETER PassThru
    Return the result object.
.EXAMPLE
    ./Restore-SessionHost.ps1 -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
[OutputType([pscustomobject])]
param(
    [Parameter()]
    [ValidateSet('', 'azure', 'azl', 'hybrid')]
    [string] $Realm = '',

    [Parameter()]
    [string] $HostName,

    [Parameter()]
    [string] $ResourceGroupName,

    [Parameter()]
    [string] $ComputerName,

    [Parameter()]
    [string] $VmName,

    [Parameter()]
    [ValidateRange(1, 120)]
    [int] $TimeoutMinutes = 15,

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

$lock = @(Get-DemoFaultLock -Scope 'avd' | Where-Object { $_.Fault -eq 'SessionHost' }) | Select-Object -First 1
if ($lock) {
    if (-not $HostName) { $HostName = $lock.Target }
    if (-not $Realm) { $Realm = [string]$lock.Detail.Realm }
    if (-not $ResourceGroupName) { $ResourceGroupName = [string]$lock.Detail.ResourceGroupName }
    if (-not $ComputerName) { $ComputerName = [string]$lock.Detail.ComputerName }
    if (-not $VmName -and $lock.Detail.PSObject.Properties['VmName']) { $VmName = [string]$lock.Detail.VmName }
}
if (-not $HostName -or -not $Realm) {
    Write-DemoScreen -InputObject 'Nothing to restore: no SessionHost fault lock and no -Realm/-HostName given.' -Raw
    if ($PassThru) { return [pscustomobject]@{ Restored = $false; Reason = 'no lock' } }
    return
}
$pool = $names.Realms[$Realm].HostPool
if (-not $ResourceGroupName -and $Realm -ne 'hybrid') { $ResourceGroupName = $(if ($Realm -eq 'azl') { $names.AzlHostsResourceGroup } else { $names.HostsResourceGroup }) }
if ($Realm -ne 'hybrid' -and -not $VmName) {
    # The session-host name is the computer name; the Azure and Azure Local VM resource names carry the standard prefix and region.
    $hostNumber = [regex]::Match($HostName, '(\d+)$')
    if (-not $hostNumber.Success) { throw "Cannot derive the VM resource name from '$HostName'; pass -VmName." }
    $VmName = & $names.VmName $Realm ([int]$hostNumber.Groups[1].Value)
}
if ($Realm -eq 'hybrid' -and -not $ComputerName) {
    $vm = @(Get-DemoConfigValue -Config $config -Key 'hybrid.vms' | Where-Object { (Get-DemoConfigValue -Config $_ -Key 'name') -eq $HostName }) | Select-Object -First 1
    if ($vm) { $ComputerName = [string](Get-DemoConfigValue -Config $vm -Key 'owner_node') }
    if (-not $ComputerName) { throw "No owner_node for '$HostName'; pass -ComputerName (cluster or node)." }
}

$method = switch ($Realm) {
    'azure' { "Start-AzVM $ResourceGroupName/$VmName" }
    'azl' { "az stack-hci-vm start $ResourceGroupName/$VmName" }
    'hybrid' { "Start-ClusterGroup '$HostName' via $ComputerName (operator/cluster restart - not AVD)" }
}
$planLines = @(
    "restore : $HostName in realm $Realm",
    "method  : $method",
    "wait    : host Available in $pool (<= $TimeoutMinutes min; the AVD agent re-registers by itself, no token)",
    'then    : clear the SessionHost fault lock'
)
if (-not $Execute) {
    Write-DemoPlan -Lines $planLines -ScriptName 'Restore-SessionHost.ps1'
    if ($PassThru) { return [pscustomobject]@{ Restored = $false; Reason = 'whatif'; Realm = $Realm; Host = $HostName } }
    return
}

if ($PSCmdlet.ShouldProcess("$Realm/$HostName", $method)) {
    switch ($Realm) {
        'azure' { Start-DemoAzureVM -ResourceGroupName $ResourceGroupName -Name $VmName }
        'azl' { Start-DemoArcVM -ResourceGroupName $ResourceGroupName -Name $VmName }
        'hybrid' {
            $group = Get-DemoClusterGroupState -ComputerName $ComputerName -Name $HostName
            if ($group.State -eq 'Online' -and $group.VMState -eq 'Running') {
                Write-DemoScreen -InputObject ('{0} is already Online on {1}.' -f $HostName, $group.OwnerNode)
            }
            else {
                Start-DemoClusterGroup -ComputerName $ComputerName -Name $HostName
            }
            Write-DemoScreen -InputObject '============================================================' -Raw
            Write-DemoScreen -InputObject 'SAY IT: AVD did NOT restart this VM. The clustered role was Offline because an administrator turned the VM off, so the cluster did not restart it either. The operator started it (Start-ClusterGroup). AVD Hybrid owns no VM lifecycle - the broker and FSLogix did their job; the VM came back because we started it.' -Raw
            Write-DemoScreen -InputObject '============================================================' -Raw
        }
    }
    Write-DemoScreen -InputObject ('Start issued for {0}. Waiting for AVD to show it Available (up to {1} min)...' -f $HostName, $TimeoutMinutes)
    $available = Wait-DemoCondition -TimeoutMinutes $TimeoutMinutes -IntervalSeconds 20 -Activity "$HostName Available" -Condition {
        @(Get-DemoSessionHostList -ResourceGroupName $names.HostPoolResourceGroup -HostPoolName $pool | Where-Object { $_.Name -eq $HostName -and $_.Status -eq 'Available' }).Count -eq 1
    }
    Get-DemoSessionHostList -ResourceGroupName $names.HostPoolResourceGroup -HostPoolName $pool | Format-Table -Property Name, Status, Sessions, AllowNewSession, LastHeartBeat -AutoSize | Out-String | Write-DemoScreen
    if ($available) {
        Remove-DemoFaultLock -Fault SessionHost
        Write-DemoScreen -InputObject 'Host Available again; fault lock cleared.' -Raw
    }
    else {
        Write-Warning 'The host is not Available yet; the fault lock stays until a re-run confirms it.'
    }
    if ($PassThru) { return [pscustomobject]@{ Restored = $available; Realm = $Realm; Host = $HostName; Method = $method } }
}
