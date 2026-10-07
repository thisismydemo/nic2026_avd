#Requires -Version 7.0
<#
.SYNOPSIS
Enables Microsoft Entra single sign-on for Azure Virtual Desktop.
.DESCRIPTION
Enables Remote Desktop Protocol on the Windows Cloud Login service principal
and adds up to 10 Entra groups as target device groups (this hides the per-host
consent prompt). Changes are simulated unless -Execute is specified. Idempotent.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER TenantId
Microsoft Entra tenant ID.
.PARAMETER TargetDeviceGroupName
Optional display names (at most 10) of Entra groups whose devices should not see the
consent prompt. Names must be unique in the tenant. A dynamic device group containing session hosts is recommended.
.PARAMETER Execute
Permits changes. Without this switch, the script runs in WhatIf mode.
.EXAMPLE
./Set-AvdEntraSso.ps1 -TenantId '00000000-0000-0000-0000-000000000000' -TargetDeviceGroupName 'grp-<org>-<lab>-avd-devices' -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [string[]]$TargetDeviceGroupName = @(),

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Execute) { $WhatIfPreference = $true }

. (Join-Path $PSScriptRoot 'LzAvd.Common.ps1')

$requiredCommands = @{
    'Connect-MgGraph'                                                             = 'Microsoft.Graph.Authentication'
    'Get-MgServicePrincipal'                                                      = 'Microsoft.Graph.Applications'
    'Get-MgServicePrincipalRemoteDesktopSecurityConfiguration'                    = 'Microsoft.Graph.Applications'
    'Update-MgServicePrincipalRemoteDesktopSecurityConfiguration'                 = 'Microsoft.Graph.Applications'
    'Get-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup'   = 'Microsoft.Graph.Applications'
    'New-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup'   = 'Microsoft.Graph.Applications'
    'Get-MgGroup'                                                                 = 'Microsoft.Graph.Groups'
}
foreach ($commandName in $requiredCommands.Keys) {
    if (-not (Test-LzAvdCommand -Name $commandName)) {
        throw "Missing cmdlet $commandName. Install the $($requiredCommands[$commandName]) module from Microsoft Graph PowerShell SDK 2.40."
    }
}

$names = @($TargetDeviceGroupName | ForEach-Object { $_.Trim() } | Select-Object -Unique)
if ($TargetDeviceGroupName.Count -gt 10 -or $names.Count -gt 10) {
    throw 'Specify at most 10 target device group names.'
}
if (@($names | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw 'Target device group names cannot be blank.'
}

$null = Connect-MgGraph -TenantId $TenantId -Scopes @(
    'Application.Read.All'
    'Application-RemoteDesktopConfig.ReadWrite.All'
    'Group.Read.All'
) -NoWelcome

$appId = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'AvdMicrosoftAppIds.psd1')).WindowsCloudLogin
$servicePrincipals = @(Get-MgServicePrincipal -Filter "appId eq '$appId'")
if ($servicePrincipals.Count -eq 0) {
    throw 'Windows Cloud Login service principal not found. It appears after the Azure Virtual Desktop resource provider is registered.'
}
$servicePrincipalId = $servicePrincipals[0].Id

# Resolve every requested group before making any changes.
$groups = @(
    foreach ($name in $names) {
        $escapedName = $name.Replace("'", "''")
        $found = @(Get-MgGroup -Filter "displayName eq '$escapedName'" -ConsistencyLevel eventual -Top 2)
        if ($found.Count -eq 0) {
            throw "Target device group '$name' was not found."
        }
        if ($found.Count -gt 1) {
            throw "Target device group name '$name' is ambiguous (more than one group has this display name); use a unique name."
        }
        [pscustomobject]@{ Id = $found[0].Id; DisplayName = $found[0].DisplayName }
    }
)

# A missing configuration is expected before the protocol is first enabled.
$configuration = $null
try {
    $configuration = Get-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $servicePrincipalId
}
catch {
    if ($_.Exception.Message -notmatch '(?i)\b404\b|not found|Request_ResourceNotFound') {
        throw
    }
}

$existingGroups = @()
if ($null -ne $configuration) {
    try {
        $existingGroups = @(Get-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup -ServicePrincipalId $servicePrincipalId)
    }
    catch {
        if ($_.Exception.Message -notmatch '(?i)\b404\b|not found|Request_ResourceNotFound') {
            throw
        }
    }
}

$existingIds = @($existingGroups | ForEach-Object { $_.Id })
$groupsToAdd = @($groups | Where-Object { $_.Id -notin $existingIds } | Sort-Object -Property Id -Unique)
if (($existingGroups.Count + $groupsToAdd.Count) -gt 10) {
    throw 'Adding these groups would exceed the limit of 10 target device groups.'
}

if ($null -ne $configuration -and $configuration.IsRemoteDesktopProtocolEnabled -eq $true) {
    [pscustomobject]@{ Step = 'Enable Remote Desktop Protocol'; Status = 'No change'; Detail = 'Already enabled.' }
}
else {
    if ($PSCmdlet.ShouldProcess("Windows Cloud Login service principal $servicePrincipalId", 'Enable Remote Desktop Protocol')) {
        $null = Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $servicePrincipalId -IsRemoteDesktopProtocolEnabled
        [pscustomobject]@{ Step = 'Enable Remote Desktop Protocol'; Status = 'Updated'; Detail = 'Enabled.' }
    }
    else {
        [pscustomobject]@{ Step = 'Enable Remote Desktop Protocol'; Status = 'WhatIf'; Detail = 'Would enable Remote Desktop Protocol.' }
    }
}

foreach ($group in $groups) {
    if ($group.Id -in $existingIds) {
        [pscustomobject]@{ Step = 'Target device group'; Status = 'No change'; Detail = "$($group.DisplayName) ($($group.Id)) is already present." }
        continue
    }

    if ($PSCmdlet.ShouldProcess('Windows Cloud Login target device groups', "Add $($group.DisplayName) ($($group.Id))")) {
        $tdg = @{ id = $group.Id; displayName = $group.DisplayName }
        $null = New-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup -ServicePrincipalId $servicePrincipalId -BodyParameter $tdg
        [pscustomobject]@{ Step = 'Target device group'; Status = 'Added'; Detail = "$($group.DisplayName) ($($group.Id))" }
    }
    else {
        [pscustomobject]@{ Step = 'Target device group'; Status = 'WhatIf'; Detail = "Would add $($group.DisplayName) ($($group.Id))." }
    }
}
