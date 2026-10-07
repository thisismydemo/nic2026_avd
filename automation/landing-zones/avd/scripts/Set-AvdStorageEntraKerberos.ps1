#Requires -Version 7.0
<#
.SYNOPSIS
    Completes the cloud-only Entra Kerberos setup for the FSLogix storage account: the steps ARM/IaC cannot do
    (design/avd/landing-zone.md section 7.3; Learn "Enable Microsoft Entra Kerberos authentication for hybrid and
    cloud-only identities on Azure Files"). Idempotent; -WhatIf is the default.
.DESCRIPTION
    1. Verifies (or, with -Execute, enables) directoryServiceOptions = AADKERB and defaultSharePermission = None.
    2. Finds the auto-generated app "[Storage Account] <account>.file.core.windows.net".
    3. Grants tenant-wide admin consent (openid, profile, User.Read) to its service principal.
    4. Adds the mandatory cloud-only tag kdc_enable_cloud_group_sids to the application manifest.
    5. With -PrivateEndpoints only: adds the privatelink identifierUri (<account>.privatelink.file.core.windows.net) so Kerberos works through
       the private endpoint (Learn troubleshooting: error 1326 with private link).
    6. Lists Conditional Access policies that require MFA for all apps without excluding the storage app; with
       -ConditionalAccessPolicyNames and -Execute it adds the exclusion to those named policies only.
    Remaining manual/host steps are documented in README (CloudKerberosTicketRetrievalEnabled, NTFS ACLs).
.EXAMPLE
    .\Set-AvdStorageEntraKerberos.ps1 -TenantId <id> -SubscriptionId <id> -ResourceGroupName <storage-resource-group> -StorageAccountName <storage-account>
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$StorageAccountName,
    [string[]]$ConditionalAccessPolicyNames = @(),
    [string]$StorageDnsSuffix = 'file.core.windows.net',
    # Owner decision D-029: no private endpoints by default, so the privatelink identifier URI is only added on request.
    [switch]$PrivateEndpoints,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LzAvd.Common.ps1')

if (-not $Execute) { $WhatIfPreference = $true }

foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzStorageAccount', 'Set-AzStorageAccount', 'Connect-MgGraph', 'Get-MgApplication', 'Update-MgApplication', 'Get-MgServicePrincipal', 'Get-MgOauth2PermissionGrant', 'New-MgOauth2PermissionGrant', 'Get-MgIdentityConditionalAccessPolicy') {
    if (-not (Test-LzAvdCommand -Name $cmd)) { throw "Cmdlet '$cmd' not available (Az.Storage, Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns)." }
}

$findings = [System.Collections.Generic.List[object]]::new()
function Add-LzAvdFinding {
    param([string]$Step, [string]$Status, [string]$Detail)
    $findings.Add([pscustomobject]@{ Step = $Step; Status = $Status; Detail = $Detail })
    Write-LzAvdLog -Message "[$Status] $Step - $Detail"
}

# --- 1. Storage account identity source -------------------------------------------------------------------------------
$context = Get-AzContext
if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) { [void](Set-AzContext -WhatIf:$false -Subscription $SubscriptionId) }
$account = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
$auth = $account.AzureFilesIdentityBasedAuth
$directory = if ($auth) { $auth.DirectoryServiceOptions } else { 'None' }
$defaultPermission = if ($auth -and $auth.DefaultSharePermission) { $auth.DefaultSharePermission } else { 'None' }
if ($directory -eq 'AADKERB' -and $defaultPermission -eq 'None') {
    Add-LzAvdFinding -Step 'AADKERB' -Status 'ok' -Detail 'directoryServiceOptions=AADKERB, defaultSharePermission=None'
}
elseif ($PSCmdlet.ShouldProcess($StorageAccountName, 'Enable Entra Kerberos (AADKERB) with defaultSharePermission None')) {
    [void](Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -EnableAzureActiveDirectoryKerberosForFile $true -DefaultSharePermission 'None')
    Add-LzAvdFinding -Step 'AADKERB' -Status 'changed' -Detail 'enabled'
}
else {
    Add-LzAvdFinding -Step 'AADKERB' -Status 'would change' -Detail "current: $directory / $defaultPermission"
}

# --- 2. The generated application -----------------------------------------------------------------------------------
Connect-MgGraph -TenantId $TenantId -Scopes @('Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All', 'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess') -NoWelcome
$publicFqdn = "$StorageAccountName.$StorageDnsSuffix"
$privateFqdn = "$StorageAccountName.privatelink.$StorageDnsSuffix"
$appDisplayName = "[Storage Account] $publicFqdn"
$app = Get-MgApplication -Filter "displayName eq '$appDisplayName'" -Top 1
if (-not $app) {
    Add-LzAvdFinding -Step 'app' -Status 'missing' -Detail "No application '$appDisplayName' yet; it appears minutes after AADKERB is enabled. Re-run."
    $findings
    return
}
Add-LzAvdFinding -Step 'app' -Status 'ok' -Detail "application object $($app.Id)"
$storageSp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -Top 1
if (-not $storageSp) { throw "Service principal for appId $($app.AppId) not found." }

# --- 3. Admin consent (openid profile User.Read on Microsoft Graph) -------------------------------------------------
$graphSp = Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Graph'" -Top 1
$requiredScopes = @('openid', 'profile', 'User.Read')
$grant = Get-MgOauth2PermissionGrant -Filter "clientId eq '$($storageSp.Id)' and consentType eq 'AllPrincipals'" | Where-Object { $_.ResourceId -eq $graphSp.Id } | Select-Object -First 1
$grantedScopes = if ($grant) { $grant.Scope -split ' ' } else { @() }
$missingScopes = @($requiredScopes | Where-Object { $grantedScopes -notcontains $_ })
if ($missingScopes.Count -eq 0) {
    Add-LzAvdFinding -Step 'admin-consent' -Status 'ok' -Detail ($grantedScopes -join ' ')
}
elseif ($PSCmdlet.ShouldProcess($appDisplayName, "Grant admin consent: $($requiredScopes -join ' ')")) {
    if ($grant) {
        Update-MgOauth2PermissionGrant -OAuth2PermissionGrantId $grant.Id -Scope (($grantedScopes + $missingScopes) -join ' ')
    }
    else {
        [void](New-MgOauth2PermissionGrant -ClientId $storageSp.Id -ConsentType 'AllPrincipals' -ResourceId $graphSp.Id -Scope ($requiredScopes -join ' '))
    }
    Add-LzAvdFinding -Step 'admin-consent' -Status 'changed' -Detail ($requiredScopes -join ' ')
}
else {
    Add-LzAvdFinding -Step 'admin-consent' -Status 'would change' -Detail "missing: $($missingScopes -join ' ')"
}

# --- 4. Cloud-only group SID tag ------------------------------------------------------------------------------------
$cloudTag = 'kdc_enable_cloud_group_sids'
$tags = @($app.Tags)
if ($tags -contains $cloudTag) {
    Add-LzAvdFinding -Step 'manifest-tag' -Status 'ok' -Detail $cloudTag
}
elseif ($PSCmdlet.ShouldProcess($appDisplayName, "Add application tag $cloudTag")) {
    Update-MgApplication -ApplicationId $app.Id -Tags ($tags + $cloudTag)
    Add-LzAvdFinding -Step 'manifest-tag' -Status 'changed' -Detail $cloudTag
}
else {
    Add-LzAvdFinding -Step 'manifest-tag' -Status 'would change' -Detail $cloudTag
}

# --- 5. Private link identifier URIs --------------------------------------------------------------------------------
$uris = @($app.IdentifierUris)
if (-not $PrivateEndpoints) {
    Add-LzAvdFinding -Step 'privatelink-uri' -Status 'skipped' -Detail 'private endpoints are not used (D-029); pass -PrivateEndpoints to add the privatelink identifier URI'
    $wanted = @()
}
else {
    $wanted = @($uris | Where-Object { $_ -like "*$publicFqdn*" -and $_ -notlike "*privatelink*" } | ForEach-Object { $_.Replace($publicFqdn, $privateFqdn) })
}
$missingUris = @($wanted | Where-Object { $uris -notcontains $_ })
if ($missingUris.Count -eq 0) {
    Add-LzAvdFinding -Step 'privatelink-uri' -Status 'ok' -Detail ($uris -join ', ')
}
elseif ($PSCmdlet.ShouldProcess($appDisplayName, "Add identifierUris: $($missingUris -join ', ')")) {
    Update-MgApplication -ApplicationId $app.Id -IdentifierUris ($uris + $missingUris)
    Add-LzAvdFinding -Step 'privatelink-uri' -Status 'changed' -Detail ($missingUris -join ', ')
}
else {
    Add-LzAvdFinding -Step 'privatelink-uri' -Status 'would change' -Detail ($missingUris -join ', ')
}

# --- 6. Conditional Access MFA exclusion ----------------------------------------------------------------------------
$policies = Get-MgIdentityConditionalAccessPolicy -All
foreach ($policy in $policies) {
    $requiresMfa = $policy.GrantControls -and ($policy.GrantControls.BuiltInControls -contains 'mfa' -or $policy.GrantControls.AuthenticationStrength)
    $allApps = $policy.Conditions.Applications.IncludeApplications -contains 'All'
    $excluded = $policy.Conditions.Applications.ExcludeApplications -contains $app.AppId
    if (-not ($requiresMfa -and $allApps) -or $excluded) { continue }
    if ($ConditionalAccessPolicyNames -contains $policy.DisplayName) {
        if ($PSCmdlet.ShouldProcess($policy.DisplayName, "Exclude $appDisplayName from the MFA policy")) {
            $apps = $policy.Conditions.Applications
            $exclude = @($apps.ExcludeApplications) + $app.AppId
            Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id -Conditions @{ applications = @{ includeApplications = $apps.IncludeApplications; excludeApplications = $exclude } }
            Add-LzAvdFinding -Step 'conditional-access' -Status 'changed' -Detail "$($policy.DisplayName): excluded"
        }
        else {
            Add-LzAvdFinding -Step 'conditional-access' -Status 'would change' -Detail "$($policy.DisplayName): would exclude the storage app"
        }
    }
    else {
        Add-LzAvdFinding -Step 'conditional-access' -Status 'action-needed' -Detail "'$($policy.DisplayName)' requires MFA for all apps and does not exclude '$appDisplayName' (state $($policy.State)); pass -ConditionalAccessPolicyNames to fix or edit it by hand."
    }
}
if (-not ($findings | Where-Object { $_.Step -eq 'conditional-access' })) {
    Add-LzAvdFinding -Step 'conditional-access' -Status 'ok' -Detail 'no all-apps MFA policy without the exclusion'
}

Add-LzAvdFinding -Step 'host-settings' -Status 'info' -Detail 'CloudKerberosTicketRetrievalEnabled=1 and LoadCredKeyFromProfile=1 are applied by the realm configuration step; NTFS ACLs via icacls from an Entra-joined admin host (design section 7.5).'
$findings
