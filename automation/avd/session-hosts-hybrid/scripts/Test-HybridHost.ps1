#Requires -Version 7.0
<#
.SYNOPSIS
Checks Arc and AVD readiness for the expected Hybrid hosts (read-only).
.DESCRIPTION
For each expected host: the Arc machine is Connected, the Azure Monitor Agent and the AVD Hybrid extension report
Succeeded, and the session host is Available. An Arc machine in the resource group that is not expected is reported as
'unexpected machine'. With -PassThru the rows are returned even when they carry problems; otherwise the script throws
when any row has a problem. Nothing is changed.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER EnvironmentFile
AVD environment file (default: <repo>\environment\avd\environment.yml). Every value left out (subscription, resource groups, host pool, machine or template names) is derived from it; explicit parameters override.
.PARAMETER ExpectedHostName
Names of the expected Arc machines / session hosts.
.PARAMETER SubscriptionId
Azure subscription ID.
.PARAMETER ArcResourceGroup
Resource group containing the Arc machines.
.PARAMETER HostPoolResourceGroup
Resource group containing the AVD host pool.
.PARAMETER HostPoolName
AVD host pool name.
.PARAMETER VmName
Optional VM name that must be one of the expected names.
.PARAMETER PassThru
Return the rows, including rows with problems.
#>
[CmdletBinding()]
param(
    # Path of the AVD environment file (default: <repo>\environment\avd\environment.yml); every value left out below comes from it.
    [string]$EnvironmentFile,

    [string[]]$ExpectedHostName,

    [string]$SubscriptionId,

    [string]$ArcResourceGroup,

    [string]$HostPoolResourceGroup,

    [string]$HostPoolName,

    [string]$VmName,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Values left out come from the AVD environment file (-EnvironmentFile, default: <repo>\environment\avd): subscription, resource
# groups, host pool and machine names are derived from it and the solution name catalogs. Explicit parameters override.
if (-not ($ExpectedHostName -and $SubscriptionId -and $ArcResourceGroup -and $HostPoolResourceGroup -and $HostPoolName)) {
    if (-not (Get-Command Get-NIC26AvdHostContext -ErrorAction SilentlyContinue)) {
        Import-Module (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\shared\powershell\NIC26.Automation\NIC26.Automation.psd1')).Path
    }
    $configArguments = @{ Scope = 'avd' }
    if ($EnvironmentFile) { $configArguments.Path = Split-Path -Path (Resolve-Path -LiteralPath $EnvironmentFile).Path -Parent }
    $hostContext = Get-NIC26AvdHostContext -Realm hybrid -Config (Get-NIC26Config @configArguments)
    if (-not $ExpectedHostName) { $ExpectedHostName = $hostContext.VmName }
    if (-not $SubscriptionId) { $SubscriptionId = $hostContext.SubscriptionId }
    if (-not $ArcResourceGroup) { $ArcResourceGroup = $hostContext.ArcResourceGroup }
    if (-not $HostPoolResourceGroup) { $HostPoolResourceGroup = $hostContext.HostPoolResourceGroup }
    if (-not $HostPoolName) { $HostPoolName = $hostContext.HostPoolName }
}
foreach ($required in 'ExpectedHostName', 'SubscriptionId', 'ArcResourceGroup', 'HostPoolResourceGroup', 'HostPoolName') {
    if (-not (Get-Variable -Name $required -ValueOnly)) { throw "$required is not set: pass -$required or set the values in the environment file." }
}
if ($VmName -and $VmName -notin $ExpectedHostName) {
    throw 'VmName must be included in ExpectedHostName.'
}

$null = Set-AzContext -WhatIf:$false -SubscriptionId $SubscriptionId
$machines = @(Get-AzConnectedMachine -ResourceGroupName $ArcResourceGroup | Where-Object { $null -ne $_ })
$hosts = @(Get-AzWvdSessionHost -HostPoolName $HostPoolName -ResourceGroupName $HostPoolResourceGroup | Where-Object { $null -ne $_ })
$rows = [System.Collections.Generic.List[object]]::new()

foreach ($name in $ExpectedHostName) {
    $problems = [System.Collections.Generic.List[string]]::new()
    $arc = Get-AzConnectedMachine -Name $name -ResourceGroupName $ArcResourceGroup
    $connected = $null -ne $arc -and $arc.Status -eq 'Connected'
    if (-not $connected) {
        $problems.Add('Arc machine not Connected')
    }

    $ama = Get-AzConnectedMachineExtension -ResourceGroupName $ArcResourceGroup -MachineName $name -Name 'AzureMonitorWindowsAgent'
    $amaSucceeded = $null -ne $ama -and $ama.ProvisioningState -eq 'Succeeded'
    if (-not $amaSucceeded) {
        $problems.Add('AMA extension not Succeeded')
    }

    $avd = Get-AzConnectedMachineExtension -ResourceGroupName $ArcResourceGroup -MachineName $name -Name 'Microsoft.AzureVirtualDesktop.CloudDeviceExtension'
    $avdSucceeded = $null -ne $avd -and $avd.ProvisioningState -eq 'Succeeded'
    if (-not $avdSucceeded) {
        $problems.Add('AVD extension not Succeeded')
    }

    $available = @($hosts | Where-Object {
            ($_.Name -eq "$HostPoolName/$name" -or $_.Name -like "$HostPoolName/$name.*") -and $_.Status -eq 'Available'
        }).Count -gt 0
    if (-not $available) {
        $problems.Add('session host not Available')
    }
    $rows.Add([pscustomobject]@{
            HostName              = $name
            ArcConnected          = $connected
            AmaSucceeded          = $amaSucceeded
            AvdExtensionSucceeded = $avdSucceeded
            SessionHostAvailable  = $available
            Problems              = [string[]]$problems.ToArray()
        })
}

foreach ($machine in $machines) {
    if ($machine.Name -notin $ExpectedHostName) {
        $rows.Add([pscustomobject]@{
                HostName              = $machine.Name
                ArcConnected          = $machine.Status -eq 'Connected'
                AmaSucceeded          = $false
                AvdExtensionSucceeded = $false
                SessionHostAvailable  = $false
                Problems              = [string[]]@('unexpected machine')
            })
    }
}

if (-not $PassThru -and @($rows | Where-Object { $_.Problems.Count -gt 0 }).Count -gt 0) {
    throw 'Hybrid host validation failed.'
}
$rows.ToArray()
