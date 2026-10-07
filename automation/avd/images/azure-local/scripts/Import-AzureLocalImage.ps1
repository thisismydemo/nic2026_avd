#Requires -Version 7.0
<#
.SYNOPSIS
Imports a gallery image version into Azure Local through a temporary managed disk.
.DESCRIPTION
Creates a managed disk from the gallery image version in the AVD subscription, grants a short-lived read-only SAS,
hands the SAS only to 'az stack-hci-vm image create', then (always) revokes access and deletes the disk. The SAS never
appears in any output: the CLI's output is captured and only fixed messages are surfaced. An existing Azure Local image
is never replaced. Without -Execute only the plan is printed and no Azure call is made.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER AvdSubscriptionId
Subscription holding the gallery image version and the temporary disk.
.PARAMETER AzlSubscriptionId
Subscription holding the Azure Local image resource.
.PARAMETER GalleryImageVersionId
Resource ID of the source gallery image version.
.PARAMETER ImageName
New Azure Local image name (^img-[a-z0-9-]+$, no 'windows': Azure rejects such names).
.PARAMETER CustomLocationId
Azure Local custom location resource ID.
.PARAMETER ImageResourceGroup
Resource group of the Azure Local image resource.
.PARAMETER Location
Region of the temporary disk and of the Azure Local image resource.
.PARAMETER TempDiskResourceGroup
Resource group of the temporary disk.
.PARAMETER TempDiskName
Name of the temporary disk.
.PARAMETER StoragePathId
Optional Azure Local storage path resource ID.
.PARAMETER SasDurationSeconds
Lifetime of the read-only disk SAS.
.PARAMETER Execute
Perform the import; without it only a plan is printed.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$AvdSubscriptionId,
    [Parameter(Mandatory)][string]$AzlSubscriptionId,
    [Parameter(Mandatory)][string]$GalleryImageVersionId,
    [Parameter(Mandatory)][string]$ImageName,
    [Parameter(Mandatory)][string]$CustomLocationId,
    [Parameter(Mandatory)][string]$ImageResourceGroup,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$TempDiskResourceGroup,
    [Parameter(Mandatory)][string]$TempDiskName,
    [string]$StoragePathId = '',
    [ValidateRange(600, 14400)][int]$SasDurationSeconds = 3600,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($ImageName -cnotmatch '^img-[a-z0-9-]+$' -or $ImageName -match '(?i)windows') {
    throw 'ImageName must match ^img-[a-z0-9-]+$ and must not contain windows.'
}

if (-not (Get-Command Invoke-AzCli -ErrorAction SilentlyContinue)) {
    # Seam around the az executable; returns ExitCode / StdOut / StdErr so callers decide what may be shown.
    function Invoke-AzCli {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Thin process wrapper; the calling script runs behind ShouldProcess and -Execute.')]
        param([Parameter(Mandatory)][string[]]$Arguments)

        $start = [System.Diagnostics.ProcessStartInfo]::new()
        $start.FileName = 'az'
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in $Arguments) {
            [void]$start.ArgumentList.Add($argument)
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $start
        try {
            [void]$process.Start()
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            return @{
                ExitCode = $process.ExitCode
                StdOut   = $stdoutTask.GetAwaiter().GetResult()
                StdErr   = $stderrTask.GetAwaiter().GetResult()
            }
        }
        finally {
            $process.Dispose()
        }
    }
}

if (-not $Execute) {
    Write-Output "Plan: import gallery image version $GalleryImageVersionId as Azure Local image $ImageName; create, grant read access to, revoke access from and remove the temporary disk $TempDiskName."
    return
}

if (-not $PSCmdlet.ShouldProcess($ImageName, 'Import Azure Local image using a temporary managed disk')) {
    return
}

$showArguments = @(
    'stack-hci-vm', 'image', 'show',
    '--subscription', $AzlSubscriptionId,
    '--resource-group', $ImageResourceGroup,
    '--name', $ImageName,
    '--query', 'id', '-o', 'tsv',
    '--only-show-errors'
)

# CLI output of the existence check is never surfaced.
try {
    $existing = Invoke-AzCli -Arguments $showArguments
}
catch {
    throw 'The Azure Local image existence check could not be completed.'
}
if ($existing.ExitCode -eq 0) {
    throw 'The Azure Local image already exists; replacement is not supported.'
}

# Never touch a disk this run did not create: refuse when the temporary disk name is already taken.
$null = Set-AzContext -WhatIf:$false -SubscriptionId $AvdSubscriptionId
$taken = Get-AzDisk -ResourceGroupName $TempDiskResourceGroup -DiskName $TempDiskName -ErrorAction SilentlyContinue
if ($null -ne $taken) {
    throw 'The temporary disk name is already in use; choose another name.'
}

$diskCreated = $false
$accessAttempted = $false
$sas = $null
try {
    $diskConfig = New-AzDiskConfig -Location $Location -CreateOption FromImage -GalleryImageReference @{ Id = $GalleryImageVersionId }
    $null = New-AzDisk -ResourceGroupName $TempDiskResourceGroup -DiskName $TempDiskName -Disk $diskConfig -Confirm:$false
    $diskCreated = $true

    $accessAttempted = $true
    $access = Grant-AzDiskAccess -ResourceGroupName $TempDiskResourceGroup -DiskName $TempDiskName -Access Read -DurationInSecond $SasDurationSeconds -Confirm:$false
    $sas = [string]$access.AccessSAS
    if ([string]::IsNullOrWhiteSpace($sas)) {
        throw 'Disk access did not return a SAS.'
    }

    $createArguments = @(
        'stack-hci-vm', 'image', 'create',
        '--subscription', $AzlSubscriptionId,
        '--resource-group', $ImageResourceGroup,
        '--custom-location', $CustomLocationId,
        '--location', $Location,
        '--name', $ImageName,
        '--os-type', 'Windows',
        '--image-path', $sas
    )
    if (-not [string]::IsNullOrWhiteSpace($StoragePathId)) {
        $createArguments += @('--storage-path-id', $StoragePathId)
    }
    $createArguments += '--only-show-errors'

    try {
        $created = Invoke-AzCli -Arguments $createArguments
        if ($created.ExitCode -ne 0) {
            throw 'Image creation failed.'
        }
    }
    catch {
        # Neither the CLI streams nor the exception text are surfaced: either could carry the SAS.
        throw 'The Azure Local image creation failed.'
    }
}
finally {
    $sas = $null
    $createArguments = $null
    if ($diskCreated) {
        try {
            if ($accessAttempted) {
                $null = Revoke-AzDiskAccess -ResourceGroupName $TempDiskResourceGroup -DiskName $TempDiskName -Confirm:$false
            }
        }
        finally {
            $null = Remove-AzDisk -ResourceGroupName $TempDiskResourceGroup -DiskName $TempDiskName -Force -Confirm:$false
        }
    }
}

try {
    $shown = Invoke-AzCli -Arguments $showArguments
    if ($shown.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$shown.StdOut)) {
        throw 'Image lookup failed.'
    }
    ([string]$shown.StdOut).Trim()
}
catch {
    throw 'The Azure Local image was created but its resource ID could not be retrieved.'
}
