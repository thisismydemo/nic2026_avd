<#
.SYNOPSIS
Checks FSLogix host registry settings without modifying the host.
.DESCRIPTION
Read-only. Returns the plan rows and throws when any value differs from the requested configuration unless -PassThru is given.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER SettingsPath
The shared settings JSON (default: ..\fslogix-settings.json).
.PARAMETER ProfileShareUnc
UNC root of the profiles share (no trailing backslash).
.PARAMETER OdfcShareUnc
UNC root of the Office data (ODFC) share (no trailing backslash).
.PARAMETER Mode
Production (default) or Rehearsal; check with the same mode that was applied.
.PARAMETER RegistryRoot
Registry root; HKLM: for a real host, a HKCU: path for tests.
.PARAMETER PassThru
Return the rows without throwing on drift.
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path $PSScriptRoot '..\fslogix-settings.json'),
    [Parameter(Mandatory)][string]$ProfileShareUnc,
    [Parameter(Mandatory)][string]$OdfcShareUnc,
    [ValidateSet('Production', 'Rehearsal')][string]$Mode = 'Production',
    [string]$RegistryRoot = 'HKLM:',
    [switch]$PassThru
)
Set-StrictMode -Version Latest
if (-not (Get-Module -Name FslogixCommon)) { Import-Module (Join-Path $PSScriptRoot 'FslogixCommon.psm1') }
$rows = @(Get-FslogixSettingPlan -SettingsPath $SettingsPath -ProfileShareUnc $ProfileShareUnc `
        -OdfcShareUnc $OdfcShareUnc -Mode $Mode -RegistryRoot $RegistryRoot)
$rows
if (-not $PassThru -and @($rows | Where-Object Action -NE 'none').Count -gt 0) {
    throw 'FSLogix host registry settings differ from the requested configuration.'
}
