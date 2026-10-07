#Requires -Version 7.0
<#
.SYNOPSIS
Creates the two Conditional Access MFA policies for Azure Virtual Desktop.
.DESCRIPTION
Creates separate policies for the Azure Virtual Desktop service app and the Windows Cloud Login (session host SSO) app,
the structure Microsoft recommends (Learn: Enforce Microsoft Entra multifactor authentication for AVD using Conditional
Access). Existing policies with the requested names are left unchanged. New policies are report-only by default.
Changes are simulated unless -Execute is specified. The app 'Azure Virtual Desktop Azure Resource Manager Provider' and
the Windows 365 app are never targeted.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER TenantId
Microsoft Entra tenant ID.
.PARAMETER UsersGroupName
Display name of the Entra group containing Azure Virtual Desktop users.
.PARAMETER NamePrefix
Prefix for the two policy names (<prefix>-mfa-service and <prefix>-mfa-sso).
.PARAMETER State
State for new policies. Defaults to enabledForReportingButNotEnforced; specify enabled explicitly to enforce them.
.PARAMETER SignInFrequencyHours
Periodic sign-in frequency, from 1 to 24 hours. Defaults to one hour.
.PARAMETER EveryTimeOnWindowsCloudLogin
Uses the everyTime interval for the Windows Cloud Login policy only (the only app that supports it).
.PARAMETER ExcludeGroupName
Display names of optional break-glass groups to exclude from both policies.
.PARAMETER ExtraTargetAppId
Optional additional application IDs for the Azure Virtual Desktop service policy only. The Azure Resource Manager
Provider app and Windows 365 are refused.
.PARAMETER Execute
Permits changes. Without this switch, the script runs in WhatIf mode.
.EXAMPLE
./New-AvdConditionalAccess.ps1 -TenantId '00000000-0000-0000-0000-000000000000' -UsersGroupName 'grp-<org>-<lab>-avd-users' -NamePrefix 'CA-<org>-<lab>' -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$UsersGroupName,

    [Parameter(Mandatory)]
    [string]$NamePrefix,

    [ValidateSet('enabledForReportingButNotEnforced', 'enabled')]
    [string]$State = 'enabledForReportingButNotEnforced',

    [ValidateRange(1, 24)]
    [int]$SignInFrequencyHours = 1,

    [switch]$EveryTimeOnWindowsCloudLogin,

    [string[]]$ExcludeGroupName = @(),

    [string[]]$ExtraTargetAppId = @(),

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Execute) { $WhatIfPreference = $true }

. (Join-Path $PSScriptRoot 'LzAvd.Common.ps1')

$requiredCommands = @{
    'Connect-MgGraph'                       = 'Microsoft.Graph.Authentication'
    'Get-MgGroup'                           = 'Microsoft.Graph.Groups'
    'Get-MgIdentityConditionalAccessPolicy' = 'Microsoft.Graph.Identity.SignIns'
    'New-MgIdentityConditionalAccessPolicy' = 'Microsoft.Graph.Identity.SignIns'
}
foreach ($commandName in $requiredCommands.Keys) {
    if (-not (Test-LzAvdCommand -Name $commandName)) {
        throw "Missing cmdlet $commandName. Install the $($requiredCommands[$commandName]) module from Microsoft Graph PowerShell SDK 2.40."
    }
}

if ([string]::IsNullOrWhiteSpace($UsersGroupName) -or [string]::IsNullOrWhiteSpace($NamePrefix)) {
    throw 'UsersGroupName and NamePrefix cannot be blank.'
}
if (@($ExcludeGroupName | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw 'ExcludeGroupName cannot contain a blank name.'
}

$appIds = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'AvdMicrosoftAppIds.psd1')
$avdAppId = $appIds.AzureVirtualDesktop
$cloudLoginAppId = $appIds.WindowsCloudLogin
$prohibitedAppIds = @($appIds.AzureVirtualDesktopArmProvider, $appIds.Windows365)
$additionalAppIds = @(
    foreach ($appId in $ExtraTargetAppId) {
        $parsedId = [guid]::Empty
        if (-not [guid]::TryParse($appId, [ref]$parsedId)) {
            throw "ExtraTargetAppId '$appId' is not a valid application ID."
        }
        $normalizedId = $parsedId.ToString()
        if ($normalizedId -in $prohibitedAppIds) {
            throw "ExtraTargetAppId '$normalizedId' is prohibited: do not target the Azure Virtual Desktop Azure Resource Manager Provider or Windows 365."
        }
        $normalizedId
    }
)
$additionalAppIds = @($additionalAppIds | Select-Object -Unique)

$null = Connect-MgGraph -TenantId $TenantId -Scopes @(
    'Policy.Read.All'
    'Policy.ReadWrite.ConditionalAccess'
    'Application.Read.All'
    'Group.Read.All'
) -NoWelcome

Write-Information -InformationAction Continue -MessageData 'Reminder: disable per-user MFA and turn off Security Defaults; Conditional Access cannot be used with Security Defaults.'

function Resolve-AvdGroup {
    param([Parameter(Mandatory)][string]$DisplayName)

    $escapedName = $DisplayName.Replace("'", "''")
    $found = @(Get-MgGroup -Filter "displayName eq '$escapedName'" -ConsistencyLevel eventual -Top 2)
    if ($found.Count -eq 0) {
        throw "Entra group '$DisplayName' was not found."
    }
    if ($found.Count -gt 1) {
        throw "Entra group name '$DisplayName' is ambiguous (more than one group has this display name); use a unique name."
    }
    return $found[0]
}

$usersGroup = Resolve-AvdGroup -DisplayName $UsersGroupName
$excludedIds = @(
    foreach ($name in $ExcludeGroupName) {
        (Resolve-AvdGroup -DisplayName $name).Id
    }
)
$excludedIds = @($excludedIds | Select-Object -Unique)
if ($usersGroup.Id -in $excludedIds) {
    throw 'The AVD users group cannot also be an excluded group.'
}

$existingPolicies = @(Get-MgIdentityConditionalAccessPolicy -All)
foreach ($policy in $existingPolicies) {
    if ($null -eq $policy.Conditions -or $null -eq $policy.Conditions.Applications) {
        continue
    }
    $includedApps = @($policy.Conditions.Applications.IncludeApplications)
    if ($policy.State -eq 'enabled' -and 'All' -in $includedApps) {
        Write-Warning "Enabled policy '$($policy.DisplayName)' includes All applications and applies to AVD sessions."
    }
    if ($cloudLoginAppId -in $includedApps -and
        $null -ne $policy.GrantControls -and
        'block' -in @($policy.GrantControls.BuiltInControls)) {
        Write-Warning "Policy '$($policy.DisplayName)' includes Windows Cloud Login with a block grant."
    }
}

$policyDefinitions = @(
    [pscustomobject]@{
        Name         = "$NamePrefix-mfa-service"
        Applications = @($avdAppId) + @($additionalAppIds | Where-Object { $_ -ne $avdAppId })
        EveryTime    = $false
    }
    [pscustomobject]@{
        Name         = "$NamePrefix-mfa-sso"
        Applications = @($cloudLoginAppId)
        EveryTime    = [bool]$EveryTimeOnWindowsCloudLogin
    }
)

foreach ($definition in $policyDefinitions) {
    if (@($existingPolicies | Where-Object { $_.DisplayName -eq $definition.Name }).Count -gt 0) {
        [pscustomobject]@{ Step = $definition.Name; Status = 'Exists'; Detail = 'No change; a policy with this display name already exists.' }
        continue
    }

    $frequency = @{
        isEnabled          = $true
        authenticationType = 'primaryAndSecondaryAuthentication'
    }
    if ($definition.EveryTime) {
        $frequency.frequencyInterval = 'everyTime'
    }
    else {
        $frequency.frequencyInterval = 'timeBased'
        $frequency.value = $SignInFrequencyHours
        $frequency.type = 'hours'
    }

    $body = @{
        displayName     = $definition.Name
        state           = $State
        conditions      = @{
            applications   = @{ includeApplications = @($definition.Applications) }
            users          = @{
                includeGroups = @($usersGroup.Id)
                excludeGroups = @($excludedIds)
            }
            clientAppTypes = @('browser', 'mobileAppsAndDesktopClients')
        }
        grantControls   = @{
            operator        = 'OR'
            builtInControls = @('mfa')
        }
        sessionControls = @{
            signInFrequency = $frequency
        }
    }

    if ($PSCmdlet.ShouldProcess($definition.Name, 'Create Conditional Access policy')) {
        $null = New-MgIdentityConditionalAccessPolicy -BodyParameter $body
        [pscustomobject]@{ Step = $definition.Name; Status = 'Created'; Detail = "State: $State." }
    }
    else {
        [pscustomobject]@{ Step = $definition.Name; Status = 'WhatIf'; Detail = "Would create policy with state $State." }
    }
}
