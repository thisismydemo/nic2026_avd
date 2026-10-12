#Requires -Version 7.0
<#
.SYNOPSIS
Sets and reads back the NTFS permissions on the root of the Azure Files FSLogix shares through the Files REST API.
.DESCRIPTION
Alternative to Set-FslogixSharePermissions.ps1 (icacls from an Entra-joined admin session) for operators without an
interactive Entra Kerberos session on a session host. Builds the design's root ACL (design/avd/landing-zone.md 7.5) as
SDDL with the Entra group SIDs (S-1-12-1-..., converted from the object IDs):
  SYSTEM and the admins group Full control (this folder, subfolders and files); the users group Modify on this folder
  only (create their own folder); CREATOR OWNER Modify on subfolders and files only; inheritance from above removed;
  Authenticated Users and Users absent.
It registers the descriptor with "Create Permission" and applies it to the share root with "Set Directory Properties"
(Files REST, x-ms-file-permission-key), authorised by a user-delegation-free service SAS that lives 15 minutes and
exists only in memory. Every change is read back ("Get Directory Properties" + "Get Permission") and compared.
Idempotent: the same descriptor is applied on every run. Without -Execute it prints the plan.
.PARAMETER SubscriptionId
Subscription of the storage account.
.PARAMETER ResourceGroupName
Resource group of the storage account.
.PARAMETER StorageAccountName
FSLogix storage account.
.PARAMETER ShareName
Shares to set (profile and ODFC).
.PARAMETER UsersGroupObjectId
Entra object ID of the FSLogix users group.
.PARAMETER AdminsGroupObjectId
Entra object ID of the FSLogix admins group.
.PARAMETER Execute
Apply.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers inside a script that is gated as a whole (-Execute or -WhatIf); they never run on their own.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$StorageAccountName,
    [Parameter(Mandatory)][string[]]$ShareName,
    [Parameter(Mandatory)][guid]$UsersGroupObjectId,
    [Parameter(Mandatory)][guid]$AdminsGroupObjectId,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -Name FslogixCommon)) { Import-Module (Join-Path $PSScriptRoot 'FslogixCommon.psm1') }

$usersSid = ConvertTo-EntraGroupSid -ObjectId $UsersGroupObjectId
$adminsSid = ConvertTo-EntraGroupSid -ObjectId $AdminsGroupObjectId
# Modify = 0x1301bf; FA = full access. P = protected (no inheritance from above), AI = auto-inherited.
$desired = "O:BAG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;$adminsSid)(A;;0x1301bf;;;$usersSid)(A;OICIIO;0x1301bf;;;CO)"
$version = '2024-11-04'

if (-not $Execute) {
    foreach ($share in $ShareName) { [pscustomobject]@{ Share = $share; Desired = $desired; Status = 'Planned' } }
    return
}

$null = Set-AzContext -SubscriptionId $SubscriptionId -Tenant (Get-AzContext).Tenant.Id -WhatIf:$false
$account = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
$context = $account.Context
$base = "https://$StorageAccountName.file.core.windows.net"

function Get-PermissionByKey([string]$Share, [string]$Key, [string]$Sas) {
    $body = Invoke-RestMethod -Method Get -Uri "$base/$Share`?restype=share&comp=filepermission&$Sas" `
        -Headers @{ 'x-ms-version' = $version; 'x-ms-file-permission-key' = $Key; 'x-ms-file-permission-format' = 'sddl' }
    return [string]$body.permission
}

function Set-ShareRoot([string]$share) {
    $sas = New-AzStorageShareSASToken -ShareName $share -Permission rwdl -ExpiryTime (Get-Date).AddMinutes(15) -Context $context
    $sas = $sas.TrimStart('?')
    try {
        # The share root does not report its permission key on Get Directory Properties, so the descriptor is
        # re-applied on every run (same result, idempotent) and read back through the key Set Directory Properties returns.
        if (-not $PSCmdlet.ShouldProcess("$StorageAccountName/$share", 'Set root NTFS permissions')) { return }
        $created = Invoke-WebRequest -Method Put -Uri "$base/$share`?restype=share&comp=filepermission&$sas" `
            -Headers @{ 'x-ms-version' = $version } -ContentType 'application/json' `
            -Body (@{ permission = $desired; format = 'sddl' } | ConvertTo-Json)
        $key = [string]$created.Headers['x-ms-file-permission-key']
        # A permission key that was just created can briefly answer ResourceNotFound: retry a few times.
        $set = $null
        for ($attempt = 1; $null -eq $set; $attempt++) {
            try {
                $set = Invoke-WebRequest -Method Put -Uri "$base/$share`?restype=directory&comp=properties&$sas" -Headers @{
                    'x-ms-version'               = $version
                    'x-ms-file-permission-key'   = $key
                    'x-ms-file-attributes'       = 'preserve'
                    'x-ms-file-creation-time'    = 'preserve'
                    'x-ms-file-last-write-time'  = 'preserve'
                }
            }
            catch {
                if ($attempt -ge 6) { throw }
                Start-Sleep -Seconds (5 * $attempt)
            }
        }
        $appliedKey = [string]$set.Headers['x-ms-file-permission-key']
        # The service appends an empty SACL marker (S:NO_ACCESS_CONTROL); compare owner, group and DACL.
        $read = (Get-PermissionByKey -Share $share -Key $appliedKey -Sas $sas) -replace 'S:NO_ACCESS_CONTROL$', ''
        if ($read -ne $desired) { throw "Read-back of the root permissions on $share differs from the requested descriptor ($read)." }
        [pscustomobject]@{ Share = $share; Status = 'Set' }
    }
    finally { $sas = $null }
}

# One function call per share keeps each share's SAS, key and responses in their own scope.
foreach ($share in $ShareName) { Set-ShareRoot -share $share }
