#Requires -Version 5.1
<#
.SYNOPSIS
    Inside the GPU session host: installs a short CUDA/AI demo workload (Python + PyTorch with CUDA) machine-wide, with a
    "NIC26 GPU demo" shortcut on the public desktop and in the all-users Start menu. Optionally runs it once as a test
    and reports nvidia-smi utilisation while it runs. Idempotent.
.DESCRIPTION
    Runs in the guest, elevated (Arc run command as SYSTEM, or locally). Windows PowerShell 5.1 compatible: a session
    host has no PowerShell 7. Never touches the NVIDIA driver; it only reads nvidia-smi.
      1. Checks the NVIDIA GPU and nvidia-smi (the data center driver is installed by Install-GuestGpuDriver.ps1).
      2. Python (python.org installer, Python Software Foundation licence) machine-wide in Program Files, if the
         requested version is not there: HTTPS download, Authenticode signer must be the Python Software Foundation,
         silent all-users install without PATH change, py launcher or file associations.
      3. A virtual environment under -InstallRoot with PyTorch (BSD-3-Clause; the CUDA wheel bundles the NVIDIA CUDA
         runtime and cuDNN under NVIDIA's redistribution terms) from the PyTorch CUDA index; skipped when the version
         is already installed and CUDA is available.
      4. gpu-demo.py: trains a transformer feed-forward block (4096 x 16384, 8192 synthetic tokens per step) with
         fp16 mixed precision on the tensor cores for -Seconds seconds (default 30) and prints TFLOPS, tokens/s and
         the GPU utilisation and power from nvidia-smi each second. Nothing is downloaded at run time (no dataset,
         no model weights). GEMM-bound on purpose: a small CNN tried first left the L4 mostly idle (12 Oct test).
      5. NIC26-GPU-Demo.cmd (opens a second window with nvidia-smi and the live utilisation query, then runs the job)
         and the shortcut "NIC26 GPU demo" (public desktop + all-users Start menu).
      6. -Test 1: runs the job once headless and prints the nvidia-smi samples (max/average utilisation) as evidence.
    Users get read and execute on -InstallRoot (Program Files ACLs); nothing is written to user profiles.
.PARAMETER PythonVersion
    Python version, e.g. 3.12.10 (must match the installer at -PythonUrl).
.PARAMETER PythonUrl
    HTTPS URL of the python.org Windows amd64 installer.
.PARAMETER TorchVersion
    PyTorch version, e.g. 2.6.0.
.PARAMETER TorchIndexUrl
    PyTorch CUDA wheel index (CUDA build that the guest driver supports), e.g. https://download.pytorch.org/whl/cu124.
.PARAMETER InstallRoot
    Install folder (default C:\Program Files\NIC26\GpuDemo).
.PARAMETER Seconds
    Default duration of the demo job.
.PARAMETER Test
    1 runs the job once after the install and reports the nvidia-smi utilisation samples (default 0).
.EXAMPLE
    .\Install-GpuDemoWorkload.ps1 -PythonVersion 0.0.0 -PythonUrl https://example.invalid/python.exe -TorchVersion 0.0 -TorchIndexUrl https://example.invalid/whl -Test 1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$PythonVersion,
    [Parameter(Mandatory)][ValidatePattern('^https://')][string]$PythonUrl,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+(\.\d+)?$')][string]$TorchVersion,
    [Parameter(Mandatory)][ValidatePattern('^https://')][string]$TorchIndexUrl,
    [string]$InstallRoot = (Join-Path $env:ProgramFiles 'NIC26\GpuDemo'),
    [ValidateRange(10, 300)][int]$Seconds = 30,
    [string]$ShortcutName = 'NIC26 GPU demo',
    # 1 = run the job once after the install (an integer, not a switch: Arc run command passes parameters as name/value text)
    [ValidateRange(0, 1)][int]$Test = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step([string]$m) { Write-Output ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
function Invoke-Exe {
    # Windows PowerShell 5.1 turns any stderr line of a native program into a terminating error under
    # $ErrorActionPreference = 'Stop' (Python and pip write warnings there): run it with Continue, split the streams.
    param([Parameter(Mandatory)][string]$File, [string[]]$ArgList = @())
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $all = @(& $File @ArgList 2>&1) } finally { $ErrorActionPreference = $eap }
    $code = $LASTEXITCODE
    [pscustomobject]@{
        Code = $code
        Out  = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
        Err  = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    }
}

# 1. GPU and driver (read only)
$gpu = @(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\VEN_10DE*' -and $_.Status -eq 'OK' })
$smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
if ($gpu.Count -eq 0 -or -not (Test-Path -LiteralPath $smi)) { throw 'No working NVIDIA GPU / nvidia-smi in this VM (attach the GPU and install the guest driver first).' }
Write-Step ("GPU: " + ((& $smi '--query-gpu=name,driver_version,driver_model.current' '--format=csv,noheader') | Select-Object -First 1))

# 2. Python, machine-wide
$mm = ($PythonVersion -split '\.')[0..1] -join ''
$pyHome = Join-Path $env:ProgramFiles "Python$mm"
$pyExe = Join-Path $pyHome 'python.exe'
$pyOk = (Test-Path -LiteralPath $pyExe) -and ((Invoke-Exe $pyExe @('-c', 'import platform; print(platform.python_version())')).Out -join '' -eq $PythonVersion)
if ($pyOk) { Write-Step "Python $PythonVersion present ($pyHome)" }
elseif ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Install Python $PythonVersion machine-wide")) {
    $dl = Join-Path $env:ProgramData 'nic26\gpu-demo'
    New-Item -ItemType Directory -Force -Path $dl | Out-Null
    $exe = Join-Path $dl ([IO.Path]::GetFileName(([uri]$PythonUrl).AbsolutePath))
    if (-not (Test-Path -LiteralPath $exe)) { Invoke-WebRequest -Uri $PythonUrl -OutFile $exe -UseBasicParsing }
    $sig = Get-AuthenticodeSignature -FilePath $exe
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Python Software Foundation') { throw "Python installer signature check failed: $($sig.Status) $($sig.SignerCertificate.Subject)" }
    $pyArgs = @('/quiet', 'InstallAllUsers=1', "TargetDir=`"$pyHome`"", 'PrependPath=0', 'Include_launcher=0', 'InstallLauncherAllUsers=0',
        'AssociateFiles=0', 'Include_test=0', 'Include_doc=0', 'Shortcuts=0')
    $p = Start-Process -FilePath $exe -Wait -PassThru -ArgumentList $pyArgs
    if ($p.ExitCode -notin 0, 3010) { throw "Python installer exit code $($p.ExitCode)" }
    if (-not (Test-Path -LiteralPath $pyExe)) { throw "python.exe not found in $pyHome after the install" }
    Write-Step "Python $PythonVersion installed ($pyHome, exit $($p.ExitCode))"
}

# 3. venv + PyTorch (CUDA)
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
$venvPy = Join-Path $InstallRoot 'venv\Scripts\python.exe'
$check = "import torch; print(torch.__version__.split('+')[0], torch.cuda.is_available())"
$torchOk = $false
if (Test-Path -LiteralPath $venvPy) {
    $c = Invoke-Exe $venvPy @('-c', $check)
    $torchOk = ($c.Code -eq 0) -and (($c.Out -join '') -eq "$TorchVersion True")
}
if ($torchOk) { Write-Step "PyTorch $TorchVersion with CUDA present" }
elseif ($PSCmdlet.ShouldProcess($InstallRoot, "Install PyTorch $TorchVersion ($TorchIndexUrl)")) {
    if (-not (Test-Path -LiteralPath $venvPy)) { if ((Invoke-Exe $pyExe @('-m', 'venv', (Join-Path $InstallRoot 'venv'))).Code -ne 0) { throw 'venv creation failed' } }
    $null = Invoke-Exe $venvPy @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-cache-dir', '--quiet', '--upgrade', 'pip')
    $pip = Invoke-Exe $venvPy @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-cache-dir', '--quiet', "torch==$TorchVersion", '--index-url', $TorchIndexUrl)
    if ($pip.Code -ne 0) { throw "pip install torch failed: $(($pip.Err | Select-Object -Last 5) -join ' ')" }
    $c = Invoke-Exe $venvPy @('-c', $check)
    if (($c.Out -join '') -ne "$TorchVersion True") { throw "PyTorch check failed: '$($c.Out -join '')' (CUDA must be available)" }
    Write-Step "PyTorch $TorchVersion installed, CUDA available"
}
# NumPy (BSD-3-Clause): not needed by the job, but PyTorch warns on start without it - keep the demo window clean.
if ((Invoke-Exe $venvPy @('-c', 'import numpy')).Code -ne 0 -and $PSCmdlet.ShouldProcess($InstallRoot, 'Install NumPy')) {
    $pip = Invoke-Exe $venvPy @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-cache-dir', '--quiet', 'numpy')
    if ($pip.Code -ne 0) { throw "pip install numpy failed: $(($pip.Err | Select-Object -Last 5) -join ' ')" }
    Write-Step 'NumPy installed'
}

# 4. The workload
$demoPy = @'
"""NIC26 GPU demo: trains a transformer feed-forward block on synthetic tokens on the GPU (tensor cores, mixed
precision) and shows nvidia-smi utilisation and power each second. No download at run time."""
import argparse, subprocess, threading, time
import torch
import torch.nn as nn

p = argparse.ArgumentParser()
p.add_argument("--seconds", type=int, default=__SECONDS__)
a = p.parse_args()

SMI = r"C:\Windows\System32\nvidia-smi.exe"
samples, stop = [], threading.Event()

def sampler():
    # one long-running nvidia-smi (-lms 1000) instead of a process per sample
    q = subprocess.Popen([SMI, "--query-gpu=utilization.gpu,memory.used,power.draw,temperature.gpu",
                          "--format=csv,noheader,nounits", "-lms", "1000"], stdout=subprocess.PIPE, text=True)
    try:
        for line in q.stdout:
            if stop.is_set():
                break
            try:
                u, m, w, t = [x.strip() for x in line.split(",")]
                samples.append((time.time(), int(float(u)), int(float(m)), float(w), int(float(t))))
            except ValueError:
                pass
    finally:
        q.terminate()

assert torch.cuda.is_available(), "CUDA not available"
dev = torch.device("cuda")
print(f"GPU: {torch.cuda.get_device_name(0)} | PyTorch {torch.__version__} | CUDA {torch.version.cuda}")
D, H, TOKENS = 4096, 16384, 8192
model = nn.Sequential(nn.Linear(D, H), nn.GELU(), nn.Linear(H, D)).to(dev)
opt = torch.optim.SGD(model.parameters(), lr=1e-3, momentum=0.9)
scaler = torch.amp.GradScaler("cuda")
x = torch.randn(TOKENS, D, device=dev)
y = torch.randn(TOKENS, D, device=dev)
flops_step = 3 * 2 * 2 * TOKENS * D * H  # forward + backward (x3), two GEMMs, 2 FLOP per multiply-add

def step():
    with torch.autocast("cuda", dtype=torch.float16):
        loss = nn.functional.mse_loss(model(x), y)
    opt.zero_grad(set_to_none=True)
    scaler.scale(loss).backward(); scaler.step(opt); scaler.update()
    return loss

step(); torch.cuda.synchronize()  # warm-up (kernel selection)
th = threading.Thread(target=sampler, daemon=True); th.start()
print(f"Training a transformer feed-forward block ({D}x{H}, {TOKENS} tokens per step, fp16 tensor cores) for {a.seconds} s ...")
t0 = last = time.time(); n = n_last = 0
while time.time() - t0 < a.seconds:
    loss = step(); n += 1
    if n % 5 == 0:
        torch.cuda.synchronize()
        now = time.time()
        if now - last >= 2:
            tf = (n - n_last) * flops_step / (now - last) / 1e12; n_last = n; last = now
            s = samples[-1] if samples else (0, 0, 0, 0.0, 0)
            print(f"  t={now - t0:5.1f}s  {tf:5.1f} TFLOPS  {(tf * 1e12 / flops_step) * TOKENS:9.0f} tokens/s  loss {loss.item():.4f}"
                  f"  | nvidia-smi: GPU {s[1]:3d}%  mem {s[2]} MiB  {s[3]:.0f} W  {s[4]} C")
torch.cuda.synchronize(); el = time.time() - t0
stop.set(); time.sleep(1.2)
run = [s for s in samples if t0 + 1 <= s[0] <= t0 + el]
mx = max((s[1] for s in run), default=0); av = sum(s[1] for s in run) / len(run) if run else 0
pw = max((s[3] for s in run), default=0.0)
print(f"Done: {n} steps, {n * TOKENS} tokens in {el:.1f} s, {n * flops_step / el / 1e12:.1f} TFLOPS; "
      f"nvidia-smi GPU utilisation max {mx}% avg {av:.0f}%, power max {pw:.0f} W over {len(run)} samples")
'@
$demoPy = $demoPy.Replace('__SECONDS__', [string]$Seconds)
$cmd = @"
@echo off
title NIC26 GPU demo
start "nvidia-smi" cmd /k "$smi & $smi --query-gpu=timestamp,name,utilization.gpu,memory.used,power.draw --format=csv -l 1"
"%~dp0venv\Scripts\python.exe" "%~dp0gpu-demo.py" %*
echo.
pause
"@
if ($PSCmdlet.ShouldProcess($InstallRoot, 'Write gpu-demo.py, launcher and shortcuts')) {
    Set-Content -LiteralPath (Join-Path $InstallRoot 'gpu-demo.py') -Value $demoPy -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $InstallRoot 'NIC26-GPU-Demo.cmd') -Value $cmd -Encoding ASCII
    # 5. Shortcuts (public desktop + all-users Start menu)
    $shell = New-Object -ComObject WScript.Shell
    $places = @([Environment]::GetFolderPath('CommonDesktopDirectory'), (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'NIC26'))
    foreach ($dir in $places) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $lnk = $shell.CreateShortcut((Join-Path $dir "$ShortcutName.lnk"))
        $lnk.TargetPath = Join-Path $InstallRoot 'NIC26-GPU-Demo.cmd'
        $lnk.WorkingDirectory = $InstallRoot
        $lnk.Description = 'NIC26: short CUDA/AI job on the NVIDIA L4 with live nvidia-smi utilisation'
        $lnk.IconLocation = "$env:SystemRoot\System32\imageres.dll,144"
        $lnk.Save()
    }
    Write-Step "Workload and shortcut '$ShortcutName' written ($InstallRoot; public desktop; Start menu\NIC26)"
}

# 6. Test run (headless) with nvidia-smi evidence
if ($Test -eq 1) {
    Write-Step "Test run ($Seconds s)"
    & $smi '--query-gpu=name,driver_version,driver_model.current,utilization.gpu,memory.used' '--format=csv'
    $run = Invoke-Exe $venvPy @((Join-Path $InstallRoot 'gpu-demo.py'), '--seconds', [string]$Seconds)
    $run.Out
    if ($run.Err) { 'stderr: ' + ($run.Err -join ' | ') }
    if ($run.Code -ne 0) { throw "gpu-demo.py exit code $($run.Code)" }
    & $smi '--query-gpu=utilization.gpu,memory.used' '--format=csv'
}
