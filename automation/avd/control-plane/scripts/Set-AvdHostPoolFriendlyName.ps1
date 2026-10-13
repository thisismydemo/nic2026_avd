#Requires -Version 7.0
<#
.SYNOPSIS
    Sets the friendly name of an Azure Virtual Desktop host pool (idempotent).
.DESCRIPTION
    Reads the host pool, compares its friendly name with -FriendlyName and patches only the friendlyName property when
    they differ. Nothing else on the host pool changes, so this is the safe way to bring a running host pool in line with
    the host_pools.<key>.friendly_name value in the environment file without re-applying the whole control plane
    (main.bicep sets the same property on a full deployment). Without -Execute the script reports what it would change.

    Uses Azure CLI (az rest) under the operator's own sign-in; no credentials are stored or passed.
    Learn: https://learn.microsoft.com/azure/virtual-desktop/customize-feed-for-virtual-desktop-users
.PARAMETER SubscriptionId
    Subscription containing the host pool.
.PARAMETER ResourceGroupName
    Resource group containing the host pool (the control-plane resource group).
.PARAMETER HostPoolName
    Name of the host pool.
.PARAMETER FriendlyName
    The friendly name to set (environment file: host_pools.<key>.friendly_name).
.PARAMETER ApiVersion
    Microsoft.DesktopVirtualization API version. Defaults to 2024-04-03.
.PARAMETER Execute
    Apply the change. Without this switch the script only reports.
.EXAMPLE
    ./Set-AvdHostPoolFriendlyName.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-example-avd -HostPoolName vdpool-example-azure -FriendlyName 'Azure desktop pool' -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $HostPoolName,

    [Parameter(Mandatory)]
    [ValidateLength(1, 64)]
    [string] $FriendlyName,

    [ValidatePattern('^\d{4}-\d{2}-\d{2}(-preview)?$')]
    [string] $ApiVersion = '2024-04-03',

    [switch] $Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required. Sign in with az login first (your own sign-in).'
}

$uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName`?api-version=$ApiVersion"

$raw = az rest --method get --url $uri --only-show-errors 2>&1
if ($LASTEXITCODE -ne 0) { throw "Reading host pool '$HostPoolName' failed: $raw" }
$current = [string](($raw | Out-String | ConvertFrom-Json).properties.friendlyName)

if ($current -ceq $FriendlyName) {
    [pscustomobject]@{ HostPool = $HostPoolName; FriendlyName = $current; Result = 'no change' }
    return
}

if (-not $Execute) {
    [pscustomobject]@{ HostPool = $HostPoolName; FriendlyName = $current; Result = "would set '$FriendlyName' (run with -Execute)" }
    return
}

$body = @{ properties = @{ friendlyName = $FriendlyName } } | ConvertTo-Json -Compress
$tmp = New-TemporaryFile
try {
    Set-Content -LiteralPath $tmp -Value $body -Encoding utf8NoBOM
    $out = az rest --method patch --url $uri --body "@$tmp" --headers 'Content-Type=application/json' --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Updating host pool '$HostPoolName' failed: $out" }
}
finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

$after = [string]((az rest --method get --url $uri --only-show-errors | Out-String | ConvertFrom-Json).properties.friendlyName)
[pscustomobject]@{ HostPool = $HostPoolName; FriendlyName = $after; Result = $(if ($after -ceq $FriendlyName) { "set (was '$current')" } else { 'MISMATCH after update' }) }
