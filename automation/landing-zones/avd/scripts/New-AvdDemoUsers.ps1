#Requires -Version 7.0
<#
.SYNOPSIS
    Creates the cloud-only demo users (design/avd/landing-zone.md section 5.2) with generated passwords that go
    straight into the operations Key Vault. Runs on the Windows jump server. -WhatIf is the default.
.DESCRIPTION
    For each name in -Users a user <name>@<Domain> is created through Microsoft Graph if it does not exist. The
    password is generated in memory (CSPRNG, 24 characters), handed to Graph once and written to the vault as
    <SecretNamePrefix>-avd-demo-user-<name>-username / -password (90-day expiry, five tags). It is never printed,
    logged, returned or written to disk. Existing users are left untouched unless -ResetPassword is given.
.EXAMPLE
    .\New-AvdDemoUsers.ps1                      # every value from the environment file (what-if)
.EXAMPLE
    .\New-AvdDemoUsers.ps1 -Users user1,user2 -Execute   # explicit parameters override the environment file
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$TenantId,
    [string]$Domain,
    [string]$KeyVaultName,
    [string]$SecretNamePrefix,
    [string[]]$Users,
    [string]$UsageLocation,
    [string]$OwnerEmail,
    [string]$NamingToken,
    [string]$UsersGroupName,
    [int]$SecretExpiryDays = 90,
    [switch]$ResetPassword,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LzAvd.Common.ps1')

# Every parameter left out comes from the AVD environment file (tenant_id, demo_user_domain, key_vault_id, secret_name_prefix, owner_email,
# demo_user_usage_location, demo_users, token); nothing is typed into this script.
if (-not ($TenantId -and $Domain -and $KeyVaultName -and $SecretNamePrefix -and $UsageLocation -and $NamingToken -and $Users)) {
    $envDefaults = Get-LzAvdEntraDefault
    if (-not $TenantId) { $TenantId = $envDefaults.TenantId }
    if (-not $Domain) { $Domain = $envDefaults.Domain }
    if (-not $KeyVaultName) { $KeyVaultName = $envDefaults.KeyVaultName }
    if (-not $SecretNamePrefix) { $SecretNamePrefix = $envDefaults.SecretNamePrefix }
    if (-not $OwnerEmail) { $OwnerEmail = $envDefaults.OwnerEmail }
    if (-not $UsageLocation) { $UsageLocation = $envDefaults.UsageLocation }
    if (-not $NamingToken) { $NamingToken = $envDefaults.NamingToken }
    if (-not $Users) { $Users = $envDefaults.DemoUsers }
    if (-not $UsersGroupName) { $UsersGroupName = $envDefaults.UsersGroupName }
}
foreach ($required in 'TenantId', 'Domain', 'KeyVaultName', 'SecretNamePrefix', 'UsageLocation', 'NamingToken', 'Users') {
    if (-not (Get-Variable -Name $required -ValueOnly)) { throw "$required is not set: pass -$required or set the matching key in the environment file (demo_user_usage_location for -UsageLocation)." }
}

if (-not $Execute) { $WhatIfPreference = $true }
if ($Execute) { Assert-LzAvdWindowsHost }

foreach ($cmd in 'Connect-MgGraph', 'Get-MgUser', 'New-MgUser', 'Update-MgUser', 'Set-AzKeyVaultSecret') {
    if (-not (Test-LzAvdCommand -Name $cmd)) { throw "Cmdlet '$cmd' not available (Microsoft.Graph.Users, Microsoft.Graph.Authentication, Az.KeyVault)." }
}

$graphScopes = @('User.ReadWrite.All')
if ($UsersGroupName) { $graphScopes += 'GroupMember.ReadWrite.All'; foreach ($cmd in 'Get-MgGroup', 'Get-MgGroupMember', 'New-MgGroupMember') { if (-not (Test-LzAvdCommand -Name $cmd)) { throw "Cmdlet '$cmd' not available (Microsoft.Graph.Groups)." } } }
Connect-MgGraph -TenantId $TenantId -Scopes $graphScopes -NoWelcome

# The union group holds the FSLogix share role. Entra Kerberos does not expand nested groups, so the users are direct members (conflict A7).
$unionGroup = $null
$unionMemberIds = @()
if ($UsersGroupName) {
    $unionGroup = Get-MgGroup -Filter "displayName eq '$UsersGroupName'" -Top 1
    if (-not $unionGroup) { throw "Group '$UsersGroupName' not found; create it with New-AvdEntraGroups.ps1 first." }
    $unionMemberIds = @(Get-MgGroupMember -GroupId $unionGroup.Id -All | Select-Object -ExpandProperty Id)
}
$tags = @{ owner = $OwnerEmail; project = $NamingToken; 'rotation-days' = "$SecretExpiryDays"; 'managed-by' = 'script'; lifecycle = 'temporary' }
$expires = (Get-Date).ToUniversalTime().AddDays($SecretExpiryDays)

$summary = foreach ($name in $Users) {
    $upn = "$name@$Domain"
    $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" -Top 1 -ErrorAction SilentlyContinue
    $action = 'exists'
    if ($existing -and -not $ResetPassword) {
        Write-LzAvdLog -Message "User exists: $upn (no change; use -ResetPassword to rotate)."
    }
    elseif ($PSCmdlet.ShouldProcess($upn, $(if ($existing) { 'Reset password and store in Key Vault' } else { 'Create cloud-only user and store password in Key Vault' }))) {
        $passwordChars = New-LzAvdRandomPassword -Length 24 -Confirm:$false
        try {
            $profile = @{ Password = [string]::new($passwordChars); ForceChangePasswordNextSignIn = $false }
            if ($existing) {
                Update-MgUser -UserId $existing.Id -PasswordProfile $profile
                $action = 'password reset'
            }
            else {
                $displayName = (Get-Culture).TextInfo.ToTitleCase($name)
                [void](New-MgUser -AccountEnabled:$true -DisplayName $displayName -MailNickname $name -UserPrincipalName $upn -UsageLocation $UsageLocation -PasswordProfile $profile)
                $action = 'created'
            }
            $profile.Password = $null
            $profile = $null
            [void](Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "$SecretNamePrefix-avd-demo-user-$name-username" -SecretValue (ConvertTo-LzAvdSecureString -Characters $upn.ToCharArray()) -Expires $expires -ContentType 'username' -Tag $tags)
            [void](Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "$SecretNamePrefix-avd-demo-user-$name-password" -SecretValue (ConvertTo-LzAvdSecureString -Characters $passwordChars) -Expires $expires -ContentType 'password' -Tag $tags)
        }
        finally {
            Clear-LzAvdCharArray -Characters $passwordChars -Confirm:$false
        }
        Write-LzAvdLog -Message "$upn $action; credentials stored in $KeyVaultName (values not shown)."
    }
    else {
        $action = 'would create'
    }
    if ($unionGroup) {
        $current = Get-MgUser -Filter "userPrincipalName eq '$upn'" -Top 1 -ErrorAction SilentlyContinue
        if ($current -and $unionMemberIds -notcontains $current.Id) {
            if ($PSCmdlet.ShouldProcess("$upn -> $UsersGroupName", 'Add direct group member')) {
                New-MgGroupMember -GroupId $unionGroup.Id -DirectoryObjectId $current.Id
                Write-LzAvdLog -Message "$upn added to $UsersGroupName."
            }
        }
    }
    [pscustomobject]@{ User = $upn; Action = $action; SecretNames = @("$SecretNamePrefix-avd-demo-user-$name-username", "$SecretNamePrefix-avd-demo-user-$name-password") }
}

$summary
