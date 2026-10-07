#Requires -Version 7.0
<#
.SYNOPSIS
Registers Arc-enabled machines with an AVD host pool.
.DESCRIPTION
Requests a short-lived registration token separately for each machine (K-7: never stored, never printed), installs
the AVD Hybrid Arc extension with the token in its protected settings, requires the extension to report Succeeded,
and polls until the AVD session host is Available (the service can take up to 15 minutes). Without -Execute, returns a
plan and requests no token.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER SubscriptionId
Azure subscription ID.
.PARAMETER ArcResourceGroup
Resource group containing the Arc machines.
.PARAMETER HostPoolResourceGroup
Resource group containing the AVD host pool.
.PARAMETER HostPoolName
AVD host pool name.
.PARAMETER MachineName
Arc machine names, processed in order; the first failure stops the run.
.PARAMETER TokenScriptPath
Path to the control-plane New-AvdRegistrationToken.ps1.
.PARAMETER ExpirationHours
Registration token lifetime in hours.
.PARAMETER WaitMinutes
Maximum time to wait for each session host.
.PARAMETER Execute
Perform the registration instead of returning a plan.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ArcResourceGroup,

    [Parameter(Mandatory)]
    [string]$HostPoolResourceGroup,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter(Mandatory)]
    [string[]]$MachineName,

    [Parameter(Mandatory)]
    [string]$TokenScriptPath,

    [ValidateRange(1, 24)]
    [int]$ExpirationHours = 2,

    [ValidateRange(1, 1440)]
    [int]$WaitMinutes = 20,

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Start-SessionHostSleep -ErrorAction SilentlyContinue)) {
    # Seam so tests can skip the real wait.
    function Start-SessionHostSleep {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mockable wait wrapper; changes no system state.')]
        param([int]$Seconds)
        Start-Sleep -Seconds $Seconds
    }
}

if (-not $Execute) {
    foreach ($machine in $MachineName) {
        [pscustomobject]@{ MachineName = $machine; Registered = $false; Status = 'Planned' }
    }
    return
}

$null = Set-AzContext -WhatIf:$false -SubscriptionId $SubscriptionId
foreach ($machine in $MachineName) {
    if (-not $PSCmdlet.ShouldProcess($machine, 'Register Arc machine with AVD')) {
        continue
    }
    $arcMachine = Get-AzConnectedMachine -Name $machine -ResourceGroupName $ArcResourceGroup
    if ($null -eq $arcMachine -or $arcMachine.Status -ne 'Connected') {
        throw "Arc machine $machine is not Connected."
    }

    $tokenResult = $null
    $plainToken = $null
    $protectedSetting = $null
    try {
        $tokenResult = & $TokenScriptPath -SubscriptionId $SubscriptionId `
            -ResourceGroupName $HostPoolResourceGroup -HostPoolName $HostPoolName `
            -ExpirationHours $ExpirationHours -Execute
        if ($null -eq $tokenResult -or $tokenResult.Token -isnot [securestring]) {
            throw 'Registration token script did not return a SecureString token.'
        }
        $plainToken = ConvertFrom-SecureString -SecureString $tokenResult.Token -AsPlainText
        $protectedSetting = @{ registrationToken = $plainToken }
        $extension = @{
            Name              = 'Microsoft.AzureVirtualDesktop.CloudDeviceExtension'
            ResourceGroupName = $ArcResourceGroup
            MachineName       = $machine
            Location          = $arcMachine.Location
            Publisher         = 'Microsoft.AzureVirtualDesktop'
            ExtensionType     = 'CloudDeviceExtension'
            ProtectedSetting  = $protectedSetting
        }
        $null = New-AzConnectedMachineExtension @extension
        $extension = $null
    }
    catch {
        # The exception text could carry request details; report a fixed message only.
        throw "AVD extension installation failed for machine $machine."
    }
    finally {
        if ($null -ne $protectedSetting) {
            $protectedSetting.Clear()
        }
        $plainToken = $null
        $tokenResult = $null
    }

    $installed = Get-AzConnectedMachineExtension -ResourceGroupName $ArcResourceGroup `
        -MachineName $machine -Name 'Microsoft.AzureVirtualDesktop.CloudDeviceExtension'
    if ($null -eq $installed -or $installed.ProvisioningState -ne 'Succeeded') {
        throw "AVD extension did not succeed for machine $machine."
    }

    $available = $false
    $maximumPolls = $WaitMinutes * 12
    for ($poll = 0; $poll -lt $maximumPolls -and -not $available; $poll++) {
        foreach ($hostEntry in @(Get-AzWvdSessionHost -HostPoolName $HostPoolName -ResourceGroupName $HostPoolResourceGroup)) {
            if ($null -ne $hostEntry -and
                ($hostEntry.Name -eq "$HostPoolName/$machine" -or $hostEntry.Name -like "$HostPoolName/$machine.*") -and
                $hostEntry.Status -eq 'Available') {
                $available = $true
                break
            }
        }
        if (-not $available) {
            Start-SessionHostSleep -Seconds 5
        }
    }
    if (-not $available) {
        throw "Session host $machine did not become Available within $WaitMinutes minute(s)."
    }
    [pscustomobject]@{ MachineName = $machine; Registered = $true; Status = 'Available' }
}
