#Requires -Version 7.0
<#
.SYNOPSIS
Applies (or checks) the FSLogix host configuration on the session hosts of one realm through Run Command, from
environment/avd/environment.yml (fslogix_realms).
.DESCRIPTION
One configuration profile for every realm (fslogix-settings.json): the script sends FslogixCommon.psm1,
Set-FslogixHostConfig.ps1, Test-FslogixHostConfig.ps1 and the settings file to each host inside a Run Command
script (Azure VMs: Invoke-AzVMRunCommand; Azure Local VMs and Hybrid hosts: Arc machine Run Command), writes them to
%ProgramData%\nic26\fslogix and runs Set-FslogixHostConfig.ps1 -Execute with the realm's share paths (or only
Test-FslogixHostConfig.ps1 with -CheckOnly). The share paths, mode and optional Cloud Cache providers come from the
realm entry; no secret is involved. The Arc Run Command is removed after each host. Idempotent (the host script
changes only values that differ).
.PARAMETER EnvironmentFile
Path to environment/avd/environment.yml.
.PARAMETER Realm
azure, azl or hybrid.
.PARAMETER CheckOnly
Run the read-only drift test instead of applying.
.PARAMETER Execute
Run. Without it the script prints the plan.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$EnvironmentFile,
    [Parameter(Mandatory)][ValidateSet('azure', 'azl', 'hybrid')][string]$Realm,
    [switch]$CheckOnly,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module powershell-yaml -ErrorAction Stop

$envData = Get-Content -LiteralPath $EnvironmentFile -Raw | ConvertFrom-Yaml
$cfg = $envData['fslogix_realms'][$Realm]
if ($null -eq $cfg) { throw "fslogix_realms.$Realm is missing in the environment file." }
$subs = @{ avd = [string]$envData['subscription_id_avd']; azl = [string]$envData['subscription_id_azl'] }

$root = Split-Path $PSScriptRoot -Parent
$payload = [ordered]@{
    'FslogixCommon.psm1'         = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'FslogixCommon.psm1') -Raw
    'Set-FslogixHostConfig.ps1'  = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Set-FslogixHostConfig.ps1') -Raw
    'Test-FslogixHostConfig.ps1' = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Test-FslogixHostConfig.ps1') -Raw
    'fslogix-settings.json'      = Get-Content -LiteralPath (Join-Path $root 'fslogix-settings.json') -Raw
}
$writes = foreach ($name in $payload.Keys) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload[$name]))
    "[IO.File]::WriteAllBytes((Join-Path `$dir '$name'), [Convert]::FromBase64String('$b64'))"
}
$providers = @($cfg['cloud_cache_providers'] | Where-Object { $_ })
$providerArg = if ($providers.Count -gt 0) { " -CloudCacheProviderUnc @('" + ($providers -join "','") + "')" } else { '' }
$common = "-SettingsPath (Join-Path `$dir 'fslogix-settings.json') -ProfileShareUnc '$($cfg['profile_unc'])' -OdfcShareUnc '$($cfg['odfc_unc'])' -Mode $($cfg['mode'])$providerArg"
$run = if ($CheckOnly) {
    "& (Join-Path `$dir 'Test-FslogixHostConfig.ps1') $common -PassThru | Where-Object Action -ne 'none' | ForEach-Object { 'DRIFT ' + `$_.Area + ' ' + `$_.Name }; 'CHECKED'"
}
else {
    "& (Join-Path `$dir 'Set-FslogixHostConfig.ps1') $common -Execute -Confirm:`$false *>&1 | Select-Object -Last 3; 'APPLIED'"
}
$guestScript = @"
`$ErrorActionPreference = 'Stop'
`$dir = Join-Path `$env:ProgramData 'nic26\fslogix'
`$null = New-Item -ItemType Directory -Path `$dir -Force
$($writes -join "`n")
$run
"@

foreach ($h in @($cfg['hosts'])) {
    $kind = [string]$h['kind']
    $name = [string]$h['name']
    if (-not $Execute) { [pscustomobject]@{ Realm = $Realm; Host = $name; Kind = $kind; Action = $(if ($CheckOnly) { 'check' } else { 'apply' }); Status = 'Planned' }; continue }
    if (-not $PSCmdlet.ShouldProcess($name, 'FSLogix host configuration')) { continue }
    $sub = $subs[[string]$h['subscription']]
    if ($kind -eq 'azure-vm') {
        $null = Set-AzContext -SubscriptionId $sub -Tenant (Get-AzContext).Tenant.Id -WhatIf:$false
        $power = ((Get-AzVM -ResourceGroupName $h['resource_group'] -Name $name -Status).Statuses | Where-Object Code -Like 'PowerState/*').Code
        if ($power -ne 'PowerState/running') {
            [pscustomobject]@{ Realm = $Realm; Host = $name; Kind = $kind; Status = 'Skipped'; Detail = "$power (start it and re-run)" }
            continue
        }
        $r = Invoke-AzVMRunCommand -ResourceGroupName $h['resource_group'] -VMName $name -CommandId RunPowerShellScript -ScriptString $guestScript
        $out = ($r.Value | ForEach-Object Message) -join "`n"
    }
    else {
        $arc = Get-AzConnectedMachine -SubscriptionId $sub -ResourceGroupName $h['resource_group'] -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $arc -or $arc.Status -ne 'Connected') {
            [pscustomobject]@{ Realm = $Realm; Host = $name; Kind = $kind; Status = 'Skipped'; Detail = 'Arc machine missing or not Connected' }
            continue
        }
        $rc = 'nic26-fslogix-config'
        try {
            $null = New-AzConnectedMachineRunCommand -SubscriptionId $sub -ResourceGroupName $h['resource_group'] -MachineName $name -RunCommandName $rc -Location $arc.Location -SourceScript $guestScript -TimeoutInSecond 600
            $res = Get-AzConnectedMachineRunCommand -SubscriptionId $sub -ResourceGroupName $h['resource_group'] -MachineName $name -Expand instanceView | Where-Object Name -EQ $rc | Select-Object -First 1
            $out = [string]$res.InstanceViewOutput + [string]$res.InstanceViewError
        }
        finally {
            Remove-AzConnectedMachineRunCommand -SubscriptionId $sub -ResourceGroupName $h['resource_group'] -MachineName $name -RunCommandName $rc -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
    }
    $ok = $out -match $(if ($CheckOnly) { 'CHECKED' } else { 'APPLIED' })
    $drift = @([regex]::Matches($out, 'DRIFT [^\r\n]+') | ForEach-Object Value)
    [pscustomobject]@{ Realm = $Realm; Host = $name; Kind = $kind; Status = $(if ($ok -and $drift.Count -eq 0) { 'OK' } elseif ($ok) { 'Drift' } else { 'Failed' }); Detail = ($drift -join '; ') + $(if (-not $ok) { ($out -split "`n" | Select-Object -Last 3) -join ' ' }) }
}
