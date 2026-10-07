#Requires -Version 7.0
<#
.SYNOPSIS
Registers deployed Azure VMs as AVD session hosts.
.DESCRIPTION
Generates a fresh registration token per VM and supplies it only as a protected managed Run Command parameter (K-7).
The Run Command is always removed afterwards. Only its execution state and exit code are read, never its output.
Without -Execute the script reports the intended work and does not request a token.
.PARAMETER SubscriptionId
Subscription of the VMs and the host pool.
.PARAMETER ResourceGroupName
Resource group of the VMs.
.PARAMETER HostPoolResourceGroup
Resource group of the host pool.
.PARAMETER HostPoolName
Host pool the VMs join.
.PARAMETER VmName
VM names, processed in order; the first failure stops the run.
.PARAMETER TokenScriptPath
Path to the control-plane New-AvdRegistrationToken.ps1.
.PARAMETER ExpirationHours
Token lifetime in hours.
.PARAMETER WaitMinutes
How long to wait for each host to report Available.
.PARAMETER RestartWhenAvailable
Restart each VM once its host reports Available.
.PARAMETER Execute
Perform the registration; otherwise nothing changes.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$HostPoolResourceGroup,
    [Parameter(Mandatory)][string]$HostPoolName,
    [Parameter(Mandatory)][string[]]$VmName,
    [Parameter(Mandatory)][string]$TokenScriptPath,
    [ValidateRange(1, 24)][int]$ExpirationHours = 2,
    [ValidateRange(1, 1440)][int]$WaitMinutes = 20,
    # Name of the Azure run command created on each machine (removed again after the run); change it to avoid collisions.
    [ValidatePattern('^[A-Za-z0-9._-]{1,64}$')][string]$RunCommandName = 'register-avd-agent',
    # Microsoft download links for the AVD Agent and Bootloader; override to pin a version or use an internal mirror.
    [ValidatePattern('^https://')][string]$AgentUri = 'https://go.microsoft.com/fwlink/?linkid=2310011',
    [ValidatePattern('^https://')][string]$BootloaderUri = 'https://go.microsoft.com/fwlink/?linkid=2311028',
    [switch]$RestartWhenAvailable,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


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

if (-not (Get-Command Start-SessionHostSleep -ErrorAction SilentlyContinue)) {
    # Seam so tests can skip the real wait.
    function Start-SessionHostSleep {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mockable wait wrapper; changes no system state.')]
        param([int]$Seconds)
        Start-Sleep -Seconds $Seconds
    }
}

if (-not $Execute) {
    foreach ($name in $VmName) {
        [pscustomobject]@{ VmName = $name; Registered = $false; Status = 'Planned'; RunCommandState = 'NotStarted' }
    }
    return
}

if (-not $PSCmdlet.ShouldProcess(($VmName -join ', '), 'Register AVD session hosts')) { return }
Set-AzContext -WhatIf:$false -SubscriptionId $SubscriptionId | Out-Null

foreach ($name in $VmName) {
    # Get-AzVM returns the model (Location, OSProfile) without -Status and the instance view (Statuses, ComputerName) with it.
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $name
    if ($null -eq $vm) { throw "VM $name does not exist." }
    $view = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $name -Status
    if (-not @($view.Statuses.Code).Contains('PowerState/running')) { throw "VM $name is not running." }

    $computerName = if ($vm.OSProfile -and $vm.OSProfile.ComputerName) { $vm.OSProfile.ComputerName } else { $name }
    $protectedParameters = $null
    $registration = $null
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
            $runCommand = @{
                ResourceGroupName  = $ResourceGroupName
                VMName             = $name
                RunCommandName     = $runCommandName
                Location           = $vm.Location
                SourceScript       = $installer
                ProtectedParameter = $protectedParameters
                Parameter          = @(
                    @{ Name = 'AgentUri'; Value = $AgentUri }
                    @{ Name = 'BootloaderUri'; Value = $BootloaderUri }
                )
                TimeoutInSecond    = 1200
            }
            Set-AzVMRunCommand @runCommand | Out-Null
            $runCommand = $null
        }
        finally {
            $protectedParameters[0].Value = $null
            $protectedParameters = $null
            $registration = $null
        }

        $result = Get-AzVMRunCommand -ResourceGroupName $ResourceGroupName `
            -VMName $name -RunCommandName $runCommandName -Expand InstanceView
        $state = [string]$result.InstanceView.ExecutionState
        $exitCode = $result.InstanceView.ExitCode
        Write-Information "VM $name run command state: $state; exit code: $exitCode."
        if ($state -ne 'Succeeded' -or $exitCode -ne 0) {
            throw "VM $name run command failed (state: $state; exit code: $exitCode)."
        }
    }
    finally {
        $protectedParameters = $null
        $registration = $null
        Remove-AzVMRunCommand -ResourceGroupName $ResourceGroupName `
            -VMName $name -RunCommandName $runCommandName -Confirm:$false | Out-Null
    }

    $waitForAvailable = {
        $deadline = [datetime]::UtcNow.AddMinutes($WaitMinutes)
        $maximumPolls = $WaitMinutes * 12
        for ($poll = 0; $poll -lt $maximumPolls -and [datetime]::UtcNow -lt $deadline; $poll++) {
            foreach ($hostEntry in @(Get-AzWvdSessionHost -ResourceGroupName $HostPoolResourceGroup -HostPoolName $HostPoolName)) {
                $candidates = @("$HostPoolName/$computerName", "$HostPoolName/$name")
                $isThisVm = @($candidates | Where-Object { $hostEntry.Name -eq $_ -or $hostEntry.Name -like "$_.*" }).Count -gt 0
                if ($isThisVm -and $hostEntry.Status -eq 'Available') { return $true }
            }
            Start-SessionHostSleep -Seconds 5
        }
        return $false
    }
    if (-not (& $waitForAvailable)) { throw "VM $name did not become Available within $WaitMinutes minute(s)." }

    if ($RestartWhenAvailable) {
        Restart-AzVM -ResourceGroupName $ResourceGroupName -Name $name -Confirm:$false | Out-Null
        # the restart finishes the reboot the MSI may have asked for; the host must report Available again
        if (-not (& $waitForAvailable)) { throw "VM $name did not become Available again after the restart within $WaitMinutes minute(s)." }
    }
    [pscustomobject]@{ VmName = $name; Registered = $true; Status = 'Available'; RunCommandState = $state }
}
