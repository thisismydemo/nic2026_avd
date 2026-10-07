#Requires -Version 7.0
<#
.SYNOPSIS
    Generates or revokes an Azure Virtual Desktop host-pool registration token.
.DESCRIPTION
    Generates a registration token at join time under the current operator's Azure sign-in and returns it to the caller
    in memory as a SecureString. Nothing is created or revoked unless -Execute is specified. The token lives 1 to 24
    hours (default 2). Design binding rule K-7: the token is never stored, never logged, never written to disk, a Key
    Vault, a file, a variables file or a transcript.

    WARNING: pass the SecureString directly to the extension's protected settings. Never export it as CLIXML, convert it
    back to plaintext for a file, or capture it in a transcript. Each operator generates their own token under their own
    sign-in.

    The Az cmdlets are called with -SubscriptionId, so the operator's Az context is never switched (a dry run has no side effect). Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md R-08, R-10).
.PARAMETER SubscriptionId
    Subscription containing the host pool.
.PARAMETER ResourceGroupName
    Resource group containing the host pool (the control-plane resource group; output hostpool_rg).
.PARAMETER HostPoolName
    Name of the host pool (output hostpool_names).
.PARAMETER ExpirationHours
    Token lifetime in hours, from 1 to 24. Defaults to 2.
.PARAMETER Revoke
    Remove the host pool's existing registration information instead of generating a token.
.PARAMETER Execute
    Apply the requested change. Without this switch the script runs as -WhatIf.
.EXAMPLE
    $r = .\New-AvdRegistrationToken.ps1 -SubscriptionId $sub -ResourceGroupName $rg -HostPoolName $pool -Execute
    # $r.Token is a SecureString; hand it to the session-host solution in memory.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The service returns the token as plain text; it is converted to a SecureString immediately and the plain text variable is cleared.')]
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
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

    [ValidateRange(1, 24)]
    [int] $ExpirationHours = 2,

    [switch] $Revoke,

    [switch] $Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Execute) {
    $WhatIfPreference = $true
}

foreach ($cmd in @(
        'Get-AzContext',
        'Get-AzWvdHostPool',
        'New-AzWvdRegistrationInfo',
        'Remove-AzWvdRegistrationInfo'
    )) {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
        throw "Required Azure command '$cmd' is unavailable. Install-Module Az.Accounts, Az.DesktopVirtualization -Scope CurrentUser."
    }
}

$context = Get-AzContext
if (-not $context) {
    throw 'No Azure context. Connect-AzAccount first (your own sign-in; no stored credentials).'
}

try {
    $hostPool = Get-AzWvdHostPool -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -Name $HostPoolName
}
catch {
    throw "Could not verify host pool '$HostPoolName' in resource group '$ResourceGroupName'. Check that it exists and that you have access."
}

if (-not $hostPool) {
    throw "Host pool '$HostPoolName' was not found in resource group '$ResourceGroupName'."
}

if ($Revoke) {
    if ($PSCmdlet.ShouldProcess($HostPoolName, 'Remove registration information')) {
        $null = Remove-AzWvdRegistrationInfo -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName
        [pscustomobject]@{
            HostPoolName = $HostPoolName
            Revoked      = $true
        }
    }
}
else {
    $expiry = (Get-Date).ToUniversalTime().AddHours($ExpirationHours)

    if ($PSCmdlet.ShouldProcess($HostPoolName, 'Generate registration token')) {
        $plainTextToken = (New-AzWvdRegistrationInfo `
                -SubscriptionId $SubscriptionId `
                -ResourceGroupName $ResourceGroupName `
                -HostPoolName $HostPoolName `
                -ExpirationTime $expiry.ToString('o')).Token

        if ([string]::IsNullOrEmpty($plainTextToken)) {
            throw "The service returned no registration token for host pool '$HostPoolName'."
        }

        try {
            $secureToken = ConvertTo-SecureString -String $plainTextToken -AsPlainText -Force
        }
        finally {
            $plainTextToken = $null
        }

        Write-Information "Registration token generated for host pool '$HostPoolName'; expires at $($expiry.ToString('o'))."

        [pscustomobject]@{
            HostPoolName      = $HostPoolName
            ResourceGroupName = $ResourceGroupName
            ExpirationTimeUtc = $expiry
            Token             = $secureToken
        }
    }
}
