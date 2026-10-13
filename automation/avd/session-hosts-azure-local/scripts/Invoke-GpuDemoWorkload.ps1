#Requires -Version 7.0
<#
.SYNOPSIS
    GPU beat a4b (option B, GPU as compute): installs and tests the short CUDA/AI demo job on the GPU session host through
    an Arc run command, with the host in drain mode for the change. Values from environment/avd/environment.yml
    (gpu_demo_workload, azl_session_hosts, subscription IDs).
.DESCRIPTION
    Stages:
      Inspect  read only: Arc agent status, session host status / AllowNewSession / sessions, GPU and disk in the guest.
      Install  drain the host (AllowNewSession false), run Install-GpuDemoWorkload.ps1 in the guest (Python + PyTorch
               CUDA machine-wide, gpu-demo.py, launcher, "NIC26 GPU demo" shortcut), then restore AllowNewSession.
      Test     run the job once in the guest (Install-GpuDemoWorkload.ps1 -Test 1, idempotent install skipped) and
               print the job output with the nvidia-smi utilisation samples; host drained for the run, then restored.
      All      Install then Test (one drain window).
    The NVIDIA driver is never changed. The run command is removed after each use. AllowNewSession is restored to the
    value it had before the run (true for a host in service). Plan only without -Execute.
    Learn: Run command on Azure Arc-enabled servers; Azure Virtual Desktop drain mode (Update-AzWvdSessionHost
    -AllowNewSession).
.PARAMETER EnvironmentFile
    Path to environment/avd/environment.yml.
.PARAMETER Stage
    Inspect, Install, Test or All.
.PARAMETER Execute
    Apply. Without it only the plan is printed (Inspect always runs: it changes nothing but a transient run command).
.EXAMPLE
    .\Invoke-GpuDemoWorkload.ps1 -EnvironmentFile ..\..\..\..\environment\avd\environment.yml -Stage Inspect -Execute
    .\Invoke-GpuDemoWorkload.ps1 -EnvironmentFile ..\..\..\..\environment\avd\environment.yml -Stage All -Execute
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers inside a script that is gated as a whole (-Execute); they never run on their own.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentFile,
    [ValidateSet('Inspect', 'Install', 'Test', 'All')][string]$Stage = 'Inspect',
    [ValidateRange(5, 120)][int]$TimeoutMinutes = 60,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module powershell-yaml -ErrorAction Stop
Import-Module Az.ConnectedMachine, Az.DesktopVirtualization -ErrorAction Stop

$envData = Get-Content -LiteralPath $EnvironmentFile -Raw | ConvertFrom-Yaml
$w = $envData['gpu_demo_workload']
if ($null -eq $w) { throw 'environment file has no gpu_demo_workload section.' }
$azl = $envData['azl_session_hosts']
$azlSub = [string]$envData['subscription_id_azl']
$avdSub = [string]$envData['subscription_id_avd']
$machine = [string]$w['host']
$h = @($azl['hosts'] | Where-Object { [string]$_['name'] -eq $machine })[0]
if (-not $h) { throw "gpu_demo_workload.host $machine is not in azl_session_hosts.hosts" }
$computer = [string]$h['computer_name']
$rg = [string]$azl['resource_group']
$pool = [string]$azl['host_pool_name']
$poolRg = [string]$azl['host_pool_resource_group']
$installer = Join-Path $PSScriptRoot 'Install-GpuDemoWorkload.ps1'
$seconds = if ($w.ContainsKey('seconds')) { [int]$w['seconds'] } else { 30 }
$shortcut = if ($w.ContainsKey('shortcut_name')) { [string]$w['shortcut_name'] } else { 'NIC26 GPU demo' }

function L([string]$m) { Write-Information "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" }

function Get-SessionHost {
    @(Get-AzWvdSessionHost -SubscriptionId $avdSub -ResourceGroupName $poolRg -HostPoolName $pool) |
        Where-Object { ($_.Name -split '/')[-1] -like "$computer*" } | Select-Object -First 1
}
function Set-Drain([bool]$allow) {
    $shName = ($script:sh.Name -split '/')[-1]
    $null = Update-AzWvdSessionHost -SubscriptionId $avdSub -ResourceGroupName $poolRg -HostPoolName $pool -Name $shName -AllowNewSession:$allow
    L "$shName AllowNewSession -> $((Get-SessionHost).AllowNewSession)"
}
function Invoke-GuestScript([string]$name, [string]$source, [hashtable]$parameters, [int]$timeoutSeconds) {
    $arc = Get-AzConnectedMachine -SubscriptionId $azlSub -ResourceGroupName $rg -Name $machine
    $p = @($parameters.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = [string]$_.Value } })
    $created = $false
    try {
        $created = $true
        $rc = @{
            SubscriptionId = $azlSub; ResourceGroupName = $rg; MachineName = $machine; RunCommandName = $name; Location = $arc.Location
            SourceScript = $source; TimeoutInSecond = $timeoutSeconds
        }
        if ($p) { $rc.Parameter = $p }
        $null = New-AzConnectedMachineRunCommand @rc -Confirm:$false
        $deadline = (Get-Date).AddSeconds($timeoutSeconds + 120)
        do {
            Start-Sleep -Seconds 10
            $r = Get-AzConnectedMachineRunCommand -SubscriptionId $azlSub -ResourceGroupName $rg -MachineName $machine -Expand 'instanceView' |
                Where-Object { $_.Name -eq $name } | Select-Object -First 1
            $state = [string]$r.InstanceViewExecutionState
        } while ($state -notin 'Succeeded', 'Failed', 'Canceled', 'TimedOut' -and (Get-Date) -lt $deadline)
        [pscustomobject]@{ State = $state; ExitCode = $r.InstanceViewExitCode; Output = [string]$r.InstanceViewOutput; Error = [string]$r.InstanceViewError }
    }
    finally {
        if ($created) { Remove-AzConnectedMachineRunCommand -SubscriptionId $azlSub -ResourceGroupName $rg -MachineName $machine -RunCommandName $name -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
    }
}

$arcStatus = (Get-AzConnectedMachine -SubscriptionId $azlSub -ResourceGroupName $rg -Name $machine).Status
$script:sh = Get-SessionHost
if (-not $script:sh) { throw "No session host for $computer in $pool" }
$before = [bool]$script:sh.AllowNewSession
L "$machine ($computer): Arc $arcStatus; session host $($script:sh.Status), AllowNewSession $before, sessions $($script:sh.Session)"
if ($arcStatus -ne 'Connected') { throw "$machine Arc agent is $arcStatus, not Connected" }

if ($Stage -eq 'Inspect') {
    if (-not $Execute) { L 'PLAN read-only run command: GPU, driver model, free disk, Python/PyTorch presence'; return }
    $probe = @'
$smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
if (Test-Path $smi) { & $smi '--query-gpu=name,driver_version,driver_model.current,utilization.gpu,memory.used,memory.total' '--format=csv' } else { 'nvidia-smi missing' }
$c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"; "C: free {0:N1} GB of {1:N1} GB" -f ($c.FreeSpace/1GB), ($c.Size/1GB)
"Python dirs: " + ((Get-ChildItem $env:ProgramFiles -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue).Name -join ',')
"GpuDemo: " + (Test-Path (Join-Path $env:ProgramFiles 'NIC26\GpuDemo\venv\Scripts\python.exe'))
try { $r = Invoke-WebRequest -Uri 'https://download.pytorch.org/whl/cu124/torch/' -Method Head -UseBasicParsing -TimeoutSec 15; "pytorch index HTTP $($r.StatusCode)" } catch { "pytorch index: $($_.Exception.Message)" }
'@
    $r = Invoke-GuestScript 'nic26-gpu-demo-inspect' $probe @{} 300
    L "inspect: $($r.State) exit $($r.ExitCode)"; $r.Output; if ($r.Error) { "stderr: $($r.Error)" }
    return
}

$doInstall = $Stage -in 'Install', 'All'
$doTest = $Stage -in 'Test', 'All'
if (-not $Execute) {
    L "PLAN drain $computer (AllowNewSession false), $(if ($doInstall) { "install Python $($w['python_version']) + PyTorch $($w['torch_version']) ($($w['torch_index_url'])) and '$shortcut'" }) $(if ($doTest) { "test run $seconds s with nvidia-smi samples" }), restore AllowNewSession $before"
    return
}
$source = Get-Content -LiteralPath $installer -Raw
$params = [ordered]@{ PythonVersion = $w['python_version']; PythonUrl = $w['python_url']; TorchVersion = $w['torch_version']; TorchIndexUrl = $w['torch_index_url']; Seconds = $seconds; ShortcutName = $shortcut }
$failed = $null
try {
    if ($before) { Set-Drain $false }
    if ($doInstall) {
        L 'install: run command nic26-gpu-demo-install'
        $r = Invoke-GuestScript 'nic26-gpu-demo-install' $source ([hashtable]$params) ($TimeoutMinutes * 60)
        L "install: $($r.State) exit $($r.ExitCode)"; $r.Output; if ($r.Error) { "stderr: $($r.Error)" }
        if ($r.State -ne 'Succeeded' -or [int]$r.ExitCode -ne 0) { throw "install run command $($r.State) exit $($r.ExitCode)" }
    }
    if ($doTest) {
        $tp = [hashtable]$params; $tp.Test = 1
        L 'test: run command nic26-gpu-demo-test'
        $r = Invoke-GuestScript 'nic26-gpu-demo-test' $source $tp 900
        L "test: $($r.State) exit $($r.ExitCode)"; $r.Output; if ($r.Error) { "stderr: $($r.Error)" }
        if ($r.State -ne 'Succeeded' -or [int]$r.ExitCode -ne 0) { throw "test run command $($r.State) exit $($r.ExitCode)" }
    }
}
catch { $failed = $_ }
finally { if ($before) { Set-Drain $true } }
if ($failed) { throw $failed }
