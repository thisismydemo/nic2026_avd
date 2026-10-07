<#
.SYNOPSIS
Plans or applies NTFS permissions on the profile and ODFC share roots.
.DESCRIPTION
Run from an Entra-joined admin host that can reach both shares under the operator's own Kerberos context (a storage-key mount
would set the ACLs under the wrong identity). Changes nothing without -Execute. Replaces the root ACLs: inheritance removed,
SYSTEM and the admins group Full control, the users group Modify on the root only, CREATOR OWNER Modify on subfolders and files,
Authenticated Users and built-in Users removed. After each write the ACL is read back and checked.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER ProfileShareUnc
UNC root of the profiles share.
.PARAMETER OdfcShareUnc
UNC root of the ODFC share.
.PARAMETER UsersGroupObjectId
Object id of the Entra users group (converted to its S-1-12-1 SID).
.PARAMETER AdminsGroupObjectId
Object id of the Entra admins group.
.PARAMETER Execute
Apply the ACL changes.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ProfileShareUnc,
    [Parameter(Mandatory)][string]$OdfcShareUnc,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')][string]$UsersGroupObjectId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')][string]$AdminsGroupObjectId,
    [switch]$Execute
)
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Share permission management requires Windows.' }
if (-not (Get-Module -Name FslogixCommon)) { Import-Module (Join-Path $PSScriptRoot 'FslogixCommon.psm1') }
$rows = @(Get-FslogixAclPlan -ProfileShareUnc $ProfileShareUnc -OdfcShareUnc $OdfcShareUnc `
        -UsersGroupObjectId $UsersGroupObjectId -AdminsGroupObjectId $AdminsGroupObjectId)
$module = Get-Module FslogixCommon
foreach ($row in $rows) {
    Write-Information "icacls $($row.Arguments -join ' ')" -InformationAction Continue
    if (-not $Execute) { continue }
    if (-not (Test-Path -LiteralPath $row.Root)) {
        throw "Share root $($row.Root) is unreachable. Mount it / sign in from an Entra-joined admin host using your Kerberos context."
    }
    if ($PSCmdlet.ShouldProcess($row.Root, 'Replace share-root NTFS permissions')) {
        $null = $module.Invoke({
                param($arguments)
                Invoke-FslogixIcacls -Arguments $arguments
            }, (, $row.Arguments))
        # Read the ACL back as SIDs (icacls prints names for well-known principals) and require EXACTLY the permitted set.
        $rules = @($module.Invoke({
                    param($root)
                    Get-FslogixAclRule -Path $root
                }, @($row.Root)))
        $problems = @(Test-FslogixAclRule -Rules $rules -UsersSid (ConvertTo-EntraGroupSid $UsersGroupObjectId) -AdminsSid (ConvertTo-EntraGroupSid $AdminsGroupObjectId))
        if ($problems.Count -gt 0) {
            throw "ACL readback for $($row.Root) does not match the permitted set: $($problems -join '; ')."
        }
    }
}
$rows
