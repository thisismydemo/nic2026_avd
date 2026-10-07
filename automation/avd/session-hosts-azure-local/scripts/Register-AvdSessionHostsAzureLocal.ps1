#Requires -Version 7.0
<#
.SYNOPSIS
Registers connected Azure Local Arc VMs with an AVD host pool.
.DESCRIPTION
Generates a fresh registration token per machine and supplies it only as an Arc Run Command protected parameter (K-7).
The Run Command is always removed afterwards. Only its execution state and exit code are read, never its output.
Without -Execute the script reports the intended work and does not request a token. The script never restarts a guest;
after MSI exit code 3010 a reboot is recommended once the host reports Available.
.PARAMETER SubscriptionId
Subscription of the Arc machines and the host pool.
.PARAMETER ResourceGroupName
Resource group of the Arc machines.
.PARAMETER HostPoolResourceGroup
Resource group of the host pool.
.PARAMETER HostPoolName
Host pool the machines join.
.PARAMETER MachineName
Arc machine names, processed in order; the first failure stops the run.
.PARAMETER TokenScriptPath
Path to the control-plane New-AvdRegistrationToken.ps1.
.PARAMETER ExpirationHours
Token lifetime in hours.
.PARAMETER WaitMinutes
How long to wait for the run command and then for the host to report Available.
.PARAMETER Execute
Perform the registration; otherwise nothing changes.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$HostPoolResourceGroup,
    [Parameter(Mandatory)][string]$HostPoolName,
    [Parameter(Mandatory)][string[]]$MachineName,
    [Parameter(Mandatory)][string]$TokenScriptPath,
    [ValidateRange(1, 24)][int]$ExpirationHours = 2,
    [ValidateRange(1, 1440)][int]$WaitMinutes = 20,
    # Name of the Azure run command created on each machine (removed again after the run); change it to avoid collisions.
    [ValidatePattern('^[A-Za-z0-9._-]{1,64}$')][string]$RunCommandName = 'register-avd-agent',
    # Microsoft download links for the AVD Agent and Bootloader; override to pin a version or use an internal mirror.
    [ValidatePattern('^https://')][string]$AgentUri = 'https://go.microsoft.com/fwlink/?linkid=2310011',
    [ValidatePattern('^https://')][string]$BootloaderUri = 'https://go.microsoft.com/fwlink/?linkid=2311028',
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


$installer = @'
param($RegistrationToken, $AgentUri, $BootloaderUri)
$ErrorActionPreference = 'Stop'
$agentPath = Join-Path $env:TEMP ("avd-agent-{0}.msi" -f [guid]::NewGuid())
$bootloaderPath = Join-Path $env:TEMP ("avd-bootloader-{0}.msi" -f [guid]::NewGuid())
try {
    Invoke-WebRequest -Uri $AgentUri -OutFile $agentPath -UseBasicParsing | Out-Null
    Invoke-WebRequest -Uri $BootloaderUri -OutFile $bootloaderPath -UseBasicParsing | Out-Null
    $agent = Start-Process msiexec.exe -ArgumentList @('/i', ('"{0}"' -f $agentPath), '/quiet', '/norestart', "REGISTRATIONTOKEN=$RegistrationToken") -Wait -PassThru
    if (@(0, 3010) -notcontains $agent.ExitCode) { throw 'AVD Agent installation failed.' }
    $bootloader = Start-Process msiexec.exe -ArgumentList @('/i', ('"{0}"' -f $bootloaderPath), '/quiet', '/norestart') -Wait -PassThru
    if (@(0, 3010) -notcontains $bootloader.ExitCode) { throw 'AVD Bootloader installation failed.' }
}
finally {
    Remove-Item -LiteralPath $agentPath, $bootloaderPath -Force -ErrorAction SilentlyContinue
}
'@

if (-not $Execute) {
    foreach ($machine in $MachineName) {
        [pscustomobject]@{ MachineName = $machine; Registered = $false; Status = 'Planned'; RunCommandState = 'NotStarted' }
    }
    return
}

if (-not $PSCmdlet.ShouldProcess(($MachineName -join ', '), 'Register AVD agents through Arc Run Command')) { return }
if (-not (Test-Path -LiteralPath $TokenScriptPath -PathType Leaf)) { throw 'Token script does not exist.' }
Set-AzContext -WhatIf:$false -SubscriptionId $SubscriptionId | Out-Null

foreach ($machine in $MachineName) {
    $arc = Get-AzConnectedMachine -Name $machine -ResourceGroupName $ResourceGroupName
    if ($null -eq $arc -or $arc.Status -ne 'Connected') { throw "Machine $machine is not Connected." }

    $protectedParameters = $null
    $registration = $null
    $created = $false
    $state = 'Unknown'
    try {
        $registration = & $TokenScriptPath -SubscriptionId $SubscriptionId `
            -ResourceGroupName $HostPoolResourceGroup -HostPoolName $HostPoolName `
            -ExpirationHours $ExpirationHours -Execute
        if ($null -eq $registration -or $registration.Token -isnot [securestring]) {
            throw 'The token script did not return a SecureString Token.'
        }
        $protectedParameters = @(
            @{ Name = 'RegistrationToken'; Value = [System.Net.NetworkCredential]::new('', $registration.Token).Password }
        )
        try {
            # A failed create can still have left the command on the service, so cleanup is armed first.
            $created = $true
            $runCommand = @{
                MachineName        = $machine
                ResourceGroupName  = $ResourceGroupName
                RunCommandName     = $runCommandName
                Location           = $arc.Location
                SourceScript       = $installer
                ProtectedParameter = $protectedParameters
                Parameter          = @(
                    @{ Name = 'AgentUri'; Value = $AgentUri }
                    @{ Name = 'BootloaderUri'; Value = $BootloaderUri }
                )
                TimeoutInSecond    = 1200
            }
            New-AzConnectedMachineRunCommand @runCommand -Confirm:$false | Out-Null
            $runCommand = $null
        }
        finally {
            $protectedParameters[0].Value = $null
            $protectedParameters = $null
            $registration = $null
        }

        $exitCode = $null
        $maximumPolls = $WaitMinutes * 12
        for ($poll = 0; $poll -lt $maximumPolls; $poll++) {
            $result = Get-AzConnectedMachineRunCommand -MachineName $machine -ResourceGroupName $ResourceGroupName `
                -RunCommandName $runCommandName -Expand 'instanceView'
            $state = [string]$result.InstanceViewExecutionState
            $exitCode = $result.InstanceViewExitCode
            if ($state -in @('Failed', 'Canceled', 'TimedOut')) { break }
            if ($state -eq 'Succeeded' -and $null -ne $exitCode) { break }
            Start-SessionHostSleep -Seconds 5
        }
        Write-Information "Machine $machine run command state: $state; exit code: $exitCode."
        if ($state -ne 'Succeeded' -or @(0, 3010) -notcontains [int]$exitCode) {
            throw "Machine $machine run command failed (state: $state; exit code: $exitCode)."
        }
    }
    finally {
        $protectedParameters = $null
        $registration = $null
        if ($created) {
            Remove-AzConnectedMachineRunCommand -MachineName $machine -ResourceGroupName $ResourceGroupName `
                -RunCommandName $runCommandName -Confirm:$false | Out-Null
        }
    }

    $available = $false
    $maximumPolls = $WaitMinutes * 12
    for ($poll = 0; $poll -lt $maximumPolls -and -not $available; $poll++) {
        foreach ($hostEntry in @(Get-AzWvdSessionHost -ResourceGroupName $HostPoolResourceGroup -HostPoolName $HostPoolName)) {
            if (($hostEntry.Name -eq "$HostPoolName/$machine" -or $hostEntry.Name -like "$HostPoolName/$machine.*") -and
                $hostEntry.Status -eq 'Available') { $available = $true; break }
        }
        if (-not $available) { Start-SessionHostSleep -Seconds 5 }
    }
    if (-not $available) { throw "Machine $machine did not become Available within $WaitMinutes minute(s)." }

    if ([int]$exitCode -eq 3010) {
        Write-Information "Machine $machine reported MSI exit code 3010: restart the guest when convenient."
    }
    [pscustomobject]@{ MachineName = $machine; Registered = $true; Status = 'Available'; RunCommandState = $state }
}
