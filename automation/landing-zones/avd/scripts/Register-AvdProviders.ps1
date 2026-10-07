#Requires -Version 7.0
<#
.SYNOPSIS
    Registers the resource providers the AVD landing zone and its realms need (design/avd/landing-zone.md section 2.2).
.DESCRIPTION
    Idempotent: already-registered providers are skipped. Without -Execute the script only reports the current state
    (-WhatIf default). Uses Az.Resources. Never touches any subscription other than -SubscriptionId.
.EXAMPLE
    .\Register-AvdProviders.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000
.EXAMPLE
    .\Register-AvdProviders.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId,
    [string[]]$Providers = @(
        'Microsoft.DesktopVirtualization', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage',
        'Microsoft.KeyVault', 'Microsoft.ManagedIdentity', 'Microsoft.Insights', 'Microsoft.OperationalInsights',
        'Microsoft.OperationsManagement', 'Microsoft.VirtualMachineImages', 'Microsoft.HybridCompute',
        'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity', 'Microsoft.Maintenance',
        'Microsoft.RecoveryServices', 'Microsoft.PolicyInsights', 'Microsoft.Authorization', 'Microsoft.Consumption'
    ),
    [switch]$Execute,
    [int]$WaitSeconds = 300
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LzAvd.Common.ps1')

if (-not $Execute) { $WhatIfPreference = $true }

foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzResourceProvider', 'Register-AzResourceProvider') {
    if (-not (Test-LzAvdCommand -Name $cmd)) { throw "Az.Resources/Az.Accounts cmdlet '$cmd' not available. Install-Module Az -Scope CurrentUser." }
}

$context = Get-AzContext
if (-not $context) { throw 'No Azure context. Connect-AzAccount first (your own sign-in; no stored credentials).' }
if ($context.Subscription.Id -ne $SubscriptionId) {
    [void](Set-AzContext -WhatIf:$false -Subscription $SubscriptionId)
}

$results = foreach ($provider in $Providers) {
    $state = (Get-AzResourceProvider -ProviderNamespace $provider | Select-Object -First 1).RegistrationState
    $action = 'none'
    if ($state -ne 'Registered') {
        if ($PSCmdlet.ShouldProcess("$provider in $SubscriptionId", 'Register resource provider')) {
            [void](Register-AzResourceProvider -ProviderNamespace $provider)
            $action = 'registered'
            $state = Invoke-LzAvdWithRetry -Activity "wait for $provider" -MaxSeconds $WaitSeconds -ScriptBlock {
                $s = (Get-AzResourceProvider -ProviderNamespace $provider | Select-Object -First 1).RegistrationState
                if ($s -ne 'Registered') { throw "$provider is $s" }
                $s
            }
        }
        else {
            $action = 'would register'
        }
    }
    [pscustomobject]@{ Provider = $provider; State = $state; Action = $action }
}

$results | Format-Table -AutoSize | Out-String | ForEach-Object { Write-LzAvdLog -Message $_ }
$results
