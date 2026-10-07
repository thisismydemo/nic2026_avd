#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the lz-avd quality gates locally: PSScriptAnalyzer (shared settings when present) and the Pester 5 suites.
.DESCRIPTION
    Read-only; no Azure call. -SkipIac skips the Bicep/Terraform gates (they need az, terraform and internet).
.EXAMPLE
    .\Invoke-LzAvdTests.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipIac,
    [string]$ResultsPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$settings = Join-Path $root '..\..\shared\powershell\PSScriptAnalyzerSettings.psd1'

Import-Module PSScriptAnalyzer -ErrorAction Stop
$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -eq 5 } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) { throw 'Pester 5.x is required (Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser).' }
# a different Pester major already loaded in this session (e.g. by an analyzer run over test files) breaks Should
Get-Module Pester | Where-Object { $_.Version -ne $pester.Version } | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module Pester -RequiredVersion $pester.Version -Force

Write-Information -MessageData '=== PSScriptAnalyzer ===' -InformationAction Continue
$analyzerArgs = @{ Path = (Join-Path $root 'scripts'); Recurse = $true }
if (Test-Path $settings) { $analyzerArgs.Settings = $settings } else { $analyzerArgs.Severity = @('Error', 'Warning') }
$findings = @(Invoke-ScriptAnalyzer @analyzerArgs)
$findings | Format-Table Severity, ScriptName, Line, RuleName -AutoSize | Out-String | Write-Information -InformationAction Continue
$blocking = @($findings | Where-Object { $_.Severity -in 'Error', 'Warning' })

Write-Information -MessageData '=== Pester ===' -InformationAction Continue
$config = New-PesterConfiguration
$config.Run.Path = @((Join-Path $PSScriptRoot 'LzAvd.Scripts.Tests.ps1'), (Join-Path $PSScriptRoot 'LzAvd.Parity.Tests.ps1'), (Join-Path $PSScriptRoot 'LzAvd.Secrets.Tests.ps1')) + $(if ($SkipIac) { @() } else { @((Join-Path $PSScriptRoot 'LzAvd.Iac.Tests.ps1')) })
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
if ($ResultsPath) { $config.TestResult.Enabled = $true; $config.TestResult.OutputPath = $ResultsPath }
$result = Invoke-Pester -Configuration $config

[pscustomobject]@{
    AnalyzerFindings = $findings.Count
    AnalyzerBlocking = $blocking.Count
    PesterPassed     = $result.PassedCount
    PesterFailed     = $result.FailedCount
    PesterSkipped    = $result.SkippedCount
}
if ($blocking.Count -gt 0 -or $result.FailedCount -gt 0) { exit 1 }
