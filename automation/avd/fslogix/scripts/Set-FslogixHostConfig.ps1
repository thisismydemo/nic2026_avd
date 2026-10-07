<#
.SYNOPSIS
Plans or applies FSLogix host registry settings and Defender exclusions.
.DESCRIPTION
Changes nothing unless -Execute is supplied. Execute supports -WhatIf and -Confirm. Idempotent: values that already match are
left alone. One configuration profile (fslogix-settings.json) serves all three realms; the share paths come from the parameters.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER SettingsPath
The shared settings JSON (default: ..\fslogix-settings.json).
.PARAMETER ProfileShareUnc
UNC root of the profiles share (no trailing backslash).
.PARAMETER OdfcShareUnc
UNC root of the Office data (ODFC) share (no trailing backslash).
.PARAMETER Mode
Production (default) fails closed on a profile problem; Rehearsal turns the two PreventLogin settings off for diagnosis.
.PARAMETER RegistryRoot
Registry root; HKLM: for a real host, a HKCU: path for tests.
.PARAMETER SkipDefender
Do not touch Defender exclusions.
.PARAMETER Execute
Apply the plan.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SettingsPath = (Join-Path $PSScriptRoot '..\fslogix-settings.json'),
    [Parameter(Mandatory)][string]$ProfileShareUnc,
    [Parameter(Mandatory)][string]$OdfcShareUnc,
    [ValidateSet('Production', 'Rehearsal')][string]$Mode = 'Production',
    [string]$RegistryRoot = 'HKLM:',
    [switch]$SkipDefender,
    [switch]$Execute
)
Set-StrictMode -Version Latest
if (-not (Get-Module -Name FslogixCommon)) { Import-Module (Join-Path $PSScriptRoot 'FslogixCommon.psm1') }
$rows = @(Get-FslogixSettingPlan -SettingsPath $SettingsPath -ProfileShareUnc $ProfileShareUnc `
        -OdfcShareUnc $OdfcShareUnc -Mode $Mode -RegistryRoot $RegistryRoot)
if ($Execute) {
    if (-not $IsWindows) { throw 'Applying host configuration requires Windows.' }
    if ($RegistryRoot -ieq 'HKLM:') {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Applying HKLM settings requires elevation.'
        }
    }
}
foreach ($row in $rows) {
    Write-Information "$($row.Area) $($row.Name): $($row.Current) -> $($row.Desired) [$($row.Action)]" -InformationAction Continue
    if ($Execute -and $row.Action -eq 'set' -and $PSCmdlet.ShouldProcess("$($row.Path)\$($row.Name)", 'Set registry value')) {
        # New-Item -Force on an existing key would clear the values already written to it: create the key only when it is missing
        if (-not (Test-Path -LiteralPath $row.Path)) { $null = New-Item -Path $row.Path -Force }
        $null = New-ItemProperty -LiteralPath $row.Path -Name $row.Name -Value $row.Desired `
            -PropertyType $row.Type -Force -ErrorAction Stop
    }
}
if (-not $SkipDefender) {
    $raw = (Get-Content -LiteralPath $SettingsPath -Raw -ErrorAction Stop).
    Replace('{{profile_share_unc}}', $ProfileShareUnc.Replace('\', '\\')).
    Replace('{{odfc_share_unc}}', $OdfcShareUnc.Replace('\', '\\'))
    $defender = (ConvertFrom-Json -InputObject $raw -ErrorAction Stop).defender
    $module = Get-Module FslogixCommon
    $preference = $null
    if ($Execute -and -not $WhatIfPreference) {
        $preference = $module.Invoke({ Get-FslogixMpPreference })[0]
    }
    foreach ($kind in @('ExclusionPath', 'ExclusionProcess')) {
        $values = if ($kind -eq 'ExclusionPath') { $defender.paths } else { $defender.processes }
        foreach ($value in $values) {
            $existing = if ($null -eq $preference) { @() } else { @($preference.$kind) }
            if ($existing -contains $value) { continue }
            Write-Information "Defender $kind planned: $value" -InformationAction Continue
            if ($Execute -and $PSCmdlet.ShouldProcess($value, "Add Defender $kind")) {
                $null = $module.Invoke({
                        param($exclusionKind, $exclusionValue)
                        Add-FslogixMpExclusion -Kind $exclusionKind -Value $exclusionValue
                    }, @($kind, $value))
            }
        }
    }
}
$rows
