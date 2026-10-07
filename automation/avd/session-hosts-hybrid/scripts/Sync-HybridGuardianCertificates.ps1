#Requires -Version 7.0
<#
.SYNOPSIS
Exports or imports local Shielded VM guardian certificates.
.DESCRIPTION
A VM with a vTPM and a local key protector starts on the other node only if that node holds the VM's guardian
certificates. Run Export on one node, copy the folder to the other node over an administrator-controlled secure
channel, then run Import there; repeat in the opposite direction so both nodes can start VMs protected by either node's
local guardian. The whole 'Shielded VM Local Certificates' store is exported because the certificate names are not a
reliable per-VM ownership filter. The PFX password is a SecureString and is never printed.
Without -Execute, prints a plan and changes nothing.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER Direction
Export or Import.
.PARAMETER Path
Folder containing the PFX files.
.PARAMETER PfxPassword
SecureString protecting the exported PFX files.
.PARAMETER VmName
Optional informational VM name; it does not filter the shared guardian certificates.
.PARAMETER RemoveFilesAfterImport
Delete the imported PFX files after a successful import (they hold private keys; remove the exported copy on the source node too).
.PARAMETER Execute
Perform the operation.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Export', 'Import')]
    [string]$Direction,

    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter(Mandatory)]
    [securestring]$PfxPassword,

    [string]$VmName,
    [switch]$RemoveFilesAfterImport,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$store = 'Cert:\LocalMachine\Shielded VM Local Certificates'
if (-not $Execute) {
    [pscustomobject]@{
        Step   = $Direction
        Detail = "All guardian certificates: $store <-> $Path"
    }
    return
}

if ($Direction -eq 'Export') {
    # The PFX files hold guardian private keys: keep them off the shared CSV and remove them after the import.
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath -match '(?i)^[A-Z]:\\ClusterStorage(\\|$)') {
        throw 'Do not export private-key material to a cluster shared volume; use a local, access-restricted folder.'
    }
    $certificates = @(Get-ChildItem -LiteralPath $store)
    $destinations = @(
        foreach ($certificate in $certificates) {
            Join-Path $Path "$($certificate.Thumbprint).pfx"
        }
    )
    foreach ($destination in $destinations) {
        if (Test-Path -LiteralPath $destination) {
            throw 'Export refuses to overwrite an existing PFX file.'
        }
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Export guardian certificates')) {
        [void][IO.Directory]::CreateDirectory($Path)
        for ($index = 0; $index -lt $certificates.Count; $index++) {
            Export-PfxCertificate -Cert $certificates[$index] -FilePath $destinations[$index] -Password $PfxPassword | Out-Null
        }
    }
}
else {
    $files = @(Get-ChildItem -LiteralPath $Path -Filter '*.pfx' -File)
    if ($PSCmdlet.ShouldProcess($store, 'Import guardian certificates')) {
        foreach ($file in $files) {
            Import-PfxCertificate -FilePath $file.FullName -CertStoreLocation $store -Password $PfxPassword | Out-Null
            if ($RemoveFilesAfterImport) {
                Remove-Item -LiteralPath $file.FullName -Force
            }
        }
    }
}
