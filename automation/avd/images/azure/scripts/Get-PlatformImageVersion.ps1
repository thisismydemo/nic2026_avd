#Requires -Version 7.0
<#
.SYNOPSIS
Resolves an exact platform image version available in a region (read-only).
.DESCRIPTION
Azure Image Builder needs an exact source version, not the moving alias. This lists the versions of the image
(Get-AzVMImage), validates an optional requested version, and returns the highest exact version. Nothing is changed.
.PARAMETER Location
Azure region to query.
.PARAMETER Publisher
Platform image publisher.
.PARAMETER Offer
Platform image offer.
.PARAMETER Sku
Platform image SKU.
.PARAMETER Version
Optional exact version to validate. The moving alias 'latest' is refused.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter(Mandatory)]
    [string]$Publisher,

    [Parameter(Mandatory)]
    [string]$Offer,

    [Parameter(Mandatory)]
    [string]$Sku,

    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Version -and $Version -eq 'latest') {
    throw 'An exact image version is required; the moving alias latest is not accepted.'
}

$query = @{
    Location      = $Location
    PublisherName = $Publisher
    Offer         = $Offer
    Skus          = $Sku
}

$versions = @(
    foreach ($image in @(Get-AzVMImage @query)) {
        if ($image.Version -match '^\d+\.\d+\.\d+$' -and (-not $Version -or $image.Version -eq $Version)) {
            $image.Version
        }
    }
)
if ($versions.Count -eq 0) {
    throw 'No matching exact platform image version exists in the requested region.'
}

$versions | Sort-Object { [version]$_ } -Descending | Select-Object -First 1
