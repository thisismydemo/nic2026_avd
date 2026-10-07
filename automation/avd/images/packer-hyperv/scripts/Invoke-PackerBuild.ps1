#Requires -Version 7.0
<#
.SYNOPSIS
Runs the Hyper-V Packer build and records the VHDX hash in a manifest.
.DESCRIPTION
Runs 'packer init', 'validate' and 'build' (in that order) in the template directory. The build password is resolved
in memory from a keyvault:// reference and set ONLY in the Packer child process environment as PKR_VAR_build_password;
it is never written to the variable file, an argument, the manifest or any output (Packer's own output is withheld
because plugins can echo rendered content). After the build the single produced VHDX is hashed (SHA-256) and a manifest
{build_id, vhdx_path, sha256, built_utc, packer_version} is written; an existing manifest is never overwritten.
Packer is not required for the plan: without -Execute nothing is called.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER PackerDirectory
Directory containing the Packer HCL files.
.PARAMETER VarFile
JSON variable file (must not contain a build password).
.PARAMETER BuildPasswordRef
keyvault:// reference of the build administrator password.
.PARAMETER BuildUsername
Build administrator user name; must equal build_username in the variable file.
.PARAMETER ManifestPath
New manifest file; must not exist.
.PARAMETER Execute
Run Packer; without it only the plan is printed.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'BuildPasswordRef', Justification = 'A keyvault:// reference (a name), not a password; the value is resolved in memory.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$PackerDirectory,
    [Parameter(Mandatory)][string]$VarFile,
    [Parameter(Mandatory)][ValidatePattern('^keyvault://')][string]$BuildPasswordRef,
    [Parameter(Mandatory)][string]$BuildUsername,
    [Parameter(Mandatory)][string]$ManifestPath,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Test-PackerInstalled -ErrorAction SilentlyContinue)) {
    function Test-PackerInstalled {
        <#
        .SYNOPSIS
        Tests whether packer is on PATH.
        .DESCRIPTION
        Seam so tests need no Packer installation.
        #>
        return $null -ne (Get-Command packer -ErrorAction SilentlyContinue)
    }
}

if (-not (Get-Command Invoke-PackerCommand -ErrorAction SilentlyContinue)) {
    function Invoke-PackerCommand {
        <#
        .SYNOPSIS
        Runs packer with an argument array and a child-only environment.
        .DESCRIPTION
        Returns ExitCode, StdOut and StdErr; the caller decides what may be shown.
        .PARAMETER Arguments
        Packer arguments.
        .PARAMETER WorkingDirectory
        Directory to run in.
        .PARAMETER Environment
        Variables set for the child process only.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Thin process wrapper; the calling script runs behind ShouldProcess and -Execute.')]
        param(
            [Parameter(Mandatory)][string[]]$Arguments,
            [Parameter(Mandatory)][string]$WorkingDirectory,
            [Parameter(Mandatory)][hashtable]$Environment
        )

        $start = [System.Diagnostics.ProcessStartInfo]::new()
        $start.FileName = 'packer'
        $start.WorkingDirectory = $WorkingDirectory
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in $Arguments) {
            [void]$start.ArgumentList.Add($argument)
        }
        # The child inherits this process environment: drop any PKR_VAR_* so only the supplied variables reach Packer.
        foreach ($inherited in @($start.Environment.Keys | Where-Object { $_ -like 'PKR_VAR_*' })) {
            [void]$start.Environment.Remove($inherited)
        }
        foreach ($key in $Environment.Keys) {
            $start.Environment[$key] = [string]$Environment[$key]
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $start
        try {
            [void]$process.Start()
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            return @{
                ExitCode = $process.ExitCode
                StdOut   = $stdoutTask.GetAwaiter().GetResult()
                StdErr   = $stderrTask.GetAwaiter().GetResult()
            }
        }
        finally {
            $process.Dispose()
        }
    }
}

if (-not $Execute) {
    Write-Output "Plan: packer init, validate and build in $PackerDirectory; hash the produced VHDX and write the new manifest $ManifestPath."
    return
}

if (Test-Path -LiteralPath $ManifestPath) {
    throw 'The manifest already exists; overwriting is not supported.'
}
if (-not $PSCmdlet.ShouldProcess($ManifestPath, 'Build the image and write the artifact manifest')) {
    return
}
if (-not (Test-PackerInstalled)) {
    throw 'Packer is not installed or is not on PATH.'
}
if (-not (Get-Command Resolve-NIC26KeyVaultRef -ErrorAction SilentlyContinue)) {
    throw 'Resolve-NIC26KeyVaultRef is required to resolve the build password (import NIC26.Automation).'
}

$resolvedDirectory = (Resolve-Path -LiteralPath $PackerDirectory).Path
$resolvedVarFile = (Resolve-Path -LiteralPath $VarFile).Path
$variables = Get-Content -LiteralPath $resolvedVarFile -Raw | ConvertFrom-Json
if ($variables.build_username -cne $BuildUsername) {
    throw 'BuildUsername does not match the Packer variable file.'
}
if ($variables.PSObject.Properties.Name -contains 'build_password') {
    throw 'The variable file must not contain a build password.'
}
$outputDirectory = [string]$variables.output_directory
if (-not [System.IO.Path]::IsPathRooted($outputDirectory)) {
    $outputDirectory = Join-Path $resolvedDirectory $outputDirectory
}

$versionResult = Invoke-PackerCommand -Arguments @('version') -WorkingDirectory $resolvedDirectory -Environment @{}
$packerVersion = if ($versionResult.ExitCode -eq 0) { ([string]$versionResult.StdOut -split "`r?`n" | Select-Object -First 1).Trim() } else { 'unknown' }

$securePassword = Resolve-NIC26KeyVaultRef -Ref $BuildPasswordRef
if ($securePassword -isnot [System.Security.SecureString]) {
    throw 'The password resolver must return a SecureString.'
}

$pointer = [IntPtr]::Zero
$password = $null
$childEnvironment = @{}
try {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    $childEnvironment['PKR_VAR_build_password'] = $password

    # 'packer init' takes no -var-file; validate and build do.
    $steps = @(
        @{ Name = 'init'; Arguments = @('init', '.') }
        @{ Name = 'validate'; Arguments = @('validate', "-var-file=$resolvedVarFile", '.') }
        @{ Name = 'build'; Arguments = @('build', "-var-file=$resolvedVarFile", '.') }
    )
    foreach ($step in $steps) {
        try {
            $result = Invoke-PackerCommand -Arguments $step.Arguments -WorkingDirectory $resolvedDirectory -Environment $childEnvironment
            if ($result.ExitCode -ne 0) {
                throw 'Step failed.'
            }
        }
        catch {
            throw "Packer $($step.Name) failed; its output was withheld."
        }
    }
}
finally {
    $childEnvironment.Clear()
    $password = $null
    if ($pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

$vhdxFiles = @(Get-ChildItem -LiteralPath $outputDirectory -Filter '*.vhdx' -File -Recurse)
if ($vhdxFiles.Count -ne 1) {
    throw 'Expected exactly one VHDX in the Packer output directory.'
}

$artifact = [ordered]@{
    build_id       = [guid]::NewGuid().ToString()
    vhdx_path      = $vhdxFiles[0].FullName
    sha256         = (Get-FileHash -LiteralPath $vhdxFiles[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    built_utc      = [datetime]::UtcNow.ToString('o')
    packer_version = $packerVersion
}
# CreateNew protects against a manifest appearing while the build ran.
$stream = [System.IO.File]::Open($ManifestPath, [System.IO.FileMode]::CreateNew)
try {
    $writer = [System.IO.StreamWriter]::new($stream)
    try {
        $writer.Write(($artifact | ConvertTo-Json))
    }
    finally {
        $writer.Dispose()
    }
}
finally {
    $stream.Dispose()
}
$ManifestPath
