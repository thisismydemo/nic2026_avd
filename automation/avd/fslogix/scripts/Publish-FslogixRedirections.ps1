<#
.SYNOPSIS
Plans or publishes the shared FSLogix redirections XML to the profiles share.
.DESCRIPTION
Validates the XML (well-formed, FSLogix root element, no UNC path, no user name) before anything is copied. Changes nothing
without -Execute. A destination file with different content is never replaced without -Overwrite; identical content is left alone.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER ProfileShareUnc
UNC root of the profiles share (the file goes to <share>\redirections\redirections.xml).
.PARAMETER RedirectionsPath
The source XML (default: ..\redirections.xml).
.PARAMETER Overwrite
Allow replacing a destination file whose content differs.
.PARAMETER UsersGroupObjectId
Optional object id of the Entra users group. The share root gives that group Modify on the root folder only, so the redirections
folder inherits nothing for users; FSLogix needs them to read the XML. When given, the folder gets Read and execute for the group
(this folder, subfolders and files). Applied with -Execute, read back with icacls.
.PARAMETER Execute
Copy the file.
#>
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UsersGroupObjectId', Justification = 'Read inside the $grantUsersRead script block.')]
param(
    [Parameter(Mandatory)][string]$ProfileShareUnc,
    [string]$RedirectionsPath = (Join-Path $PSScriptRoot '..\redirections.xml'),
    [switch]$Overwrite,
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')][string]$UsersGroupObjectId = '',
    [switch]$Execute
)
Set-StrictMode -Version Latest
if (-not (Get-Module -Name FslogixCommon)) { Import-Module (Join-Path $PSScriptRoot 'FslogixCommon.psm1') }
if ($ProfileShareUnc -cnotmatch '^\\\\[^\\]+\\[^\\]+$') {
    throw 'ProfileShareUnc must be a UNC share root without a trailing backslash.'
}
$content = Get-Content -LiteralPath $RedirectionsPath -Raw -ErrorAction Stop
if ($content -match '\\\\' -or $content -match '(?i)(?:user(name)?|principal)\s*=') {
    throw 'Redirections XML must not contain a UNC path or user name.'
}
try {
    $xml = [xml]$content
    if ($xml.DocumentElement.LocalName -ne 'FrxProfileFolderRedirection') {
        throw 'Unexpected redirections XML root element.'
    }
}
catch {
    throw "Invalid redirections XML: $($_.Exception.Message)"
}
$directory = $ProfileShareUnc + '\redirections'
$destination = $directory + '\redirections.xml'
# Users need Read on the folder and the file; the root ACL (Modify, this folder only) does not propagate to them.
$grantUsersRead = {
    if ([string]::IsNullOrEmpty($UsersGroupObjectId)) { return }
    $sid = ConvertTo-EntraGroupSid $UsersGroupObjectId
    Write-Information "icacls $directory /grant:r *$($sid):(OI)(CI)RX" -InformationAction Continue
    if ($Execute -and $PSCmdlet.ShouldProcess($directory, 'Grant the users group Read and execute on the redirections folder')) {
        $null = (Get-Module FslogixCommon).Invoke({ param($arguments) Invoke-FslogixIcacls -Arguments $arguments }, (, [string[]]@($directory, '/grant:r', "*$($sid):(OI)(CI)RX")))
    }
}
if (Test-Path -LiteralPath $destination) {
    $sourceHash = (Get-FileHash -LiteralPath $RedirectionsPath -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($sourceHash -ne $targetHash -and -not $Overwrite) {
        throw 'Destination differs; specify -Overwrite to replace it.'
    }
    if ($sourceHash -eq $targetHash) { & $grantUsersRead; return $destination }
}
Write-Information "Publish redirections to $destination" -InformationAction Continue
if ($Execute -and $PSCmdlet.ShouldProcess($destination, 'Publish redirections XML')) {
    if (-not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop
    }
    Copy-Item -LiteralPath $RedirectionsPath -Destination $destination -Force -ErrorAction Stop
}
& $grantUsersRead
$destination
