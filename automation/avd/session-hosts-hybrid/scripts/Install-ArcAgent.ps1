#Requires -Version 7.0
<#
.SYNOPSIS
Connects Hybrid VMs to Azure Arc through PowerShell Direct.
.DESCRIPTION
Checks Entra join status inside each guest, connects the pre-installed Arc agent with the onboarding service
principal, and verifies its status. The four secrets are resolved in memory with Resolve-NIC26KeyVaultRef
(NIC26.Automation imported) and passed to the guest only as arguments of the PowerShell Direct call; guest errors are
replaced by a fixed message so no secret can leak through an exception. Note that azcmagent takes the service-principal
secret on its command line inside the guest, so command-line process auditing (event 4688) or Sysmon on the guest would
record it; the secret is the onboarding principal's, which has only the Azure Connected Machine Onboarding role on the
Arc resource group. Without -Execute, returns a plan and resolves no secret.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER VmName
Names of the VMs to onboard.
.PARAMETER TenantId
Microsoft Entra tenant ID.
.PARAMETER SubscriptionId
Azure subscription ID.
.PARAMETER ArcResourceGroup
Resource group for the Arc machines.
.PARAMETER Location
Azure location for the Arc machines.
.PARAMETER ComputerName
Hyper-V host (cluster node) that currently runs the VMs. PowerShell Direct only reaches VMs on the host it starts from, so a script run on the jump server must name the node here; the guest calls are then made through Invoke-Command -ComputerName <node>. Omit it when running on that node itself.
.PARAMETER Tags
Tags to pass to azcmagent; keys and values must not contain commas or equals signs.
.PARAMETER LocalAdminUsernameRef
Key Vault reference for the guest administrator user name.
.PARAMETER LocalAdminPasswordRef
Key Vault reference for the guest administrator password.
.PARAMETER OnboardingClientIdRef
Key Vault reference for the onboarding service principal client id.
.PARAMETER OnboardingSecretRef
Key Vault reference for the onboarding service principal secret.
.PARAMETER SetExtensionAllowList
Set the agent extension allow-list after connecting.
.PARAMETER ExtensionAllowList
Extension identifiers to allow when -SetExtensionAllowList is given.
.PARAMETER Execute
Perform the onboarding instead of returning a plan.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'LocalAdminPasswordRef', Justification = 'A keyvault:// reference (a name), not a password; the value is resolved in memory.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The value was just resolved from Key Vault in memory and must become a SecureString/PSCredential for the downstream API.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string[]]$VmName,

    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ArcResourceGroup,

    [Parameter(Mandatory)]
    [string]$Location,

    [string]$ComputerName,

    [Parameter(Mandatory)]
    [hashtable]$Tags,

    [Parameter(Mandatory)]
    [ValidatePattern('^keyvault://')]
    [string]$LocalAdminUsernameRef,

    [Parameter(Mandatory)]
    [ValidatePattern('^keyvault://')]
    [string]$LocalAdminPasswordRef,

    [Parameter(Mandatory)]
    [ValidatePattern('^keyvault://')]
    [string]$OnboardingClientIdRef,

    [Parameter(Mandatory)]
    [ValidatePattern('^keyvault://')]
    [string]$OnboardingSecretRef,

    [switch]$SetExtensionAllowList,

    [string[]]$ExtensionAllowList,

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($key in $Tags.Keys) {
    if ([string]::IsNullOrWhiteSpace([string]$key) -or
        [string]$key -match '[,=]' -or
        [string]$Tags[$key] -match '[,=]') {
        throw 'Tag keys and values must not contain commas or equals signs.'
    }
}
if ($SetExtensionAllowList -and (-not $ExtensionAllowList -or
        @($ExtensionAllowList | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -match ',' }).Count -gt 0)) {
    throw 'A nonempty extension allow-list without commas is required.'
}

if (-not $Execute) {
    foreach ($vm in $VmName) {
        [pscustomobject]@{ VmName = $vm; Joined = $false; ArcStatus = 'Planned' }
    }
    return
}

if (-not (Get-Command Resolve-NIC26KeyVaultRef -ErrorAction SilentlyContinue)) {
    throw 'Resolve-NIC26KeyVaultRef is required (import NIC26.Automation).'
}

if (-not (Get-Command Invoke-HybridGuest -ErrorAction SilentlyContinue)) {
    function Invoke-HybridGuest {
        <#
        .SYNOPSIS
        Runs a script block inside a guest over PowerShell Direct, optionally through the Hyper-V host.
        .DESCRIPTION
        PowerShell Direct only reaches VMs on the host it starts from, so with -ComputerName the call is made on that host.
        .PARAMETER VmName
        Guest VM name.
        .PARAMETER Credential
        Guest local administrator credential.
        .PARAMETER ScriptBlock
        Code to run in the guest.
        .PARAMETER ArgumentList
        Arguments for the script block.
        .PARAMETER ComputerName
        Hyper-V host that runs the VM; omit when already on it.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$VmName,
            [Parameter(Mandatory)][pscredential]$Credential,
            [Parameter(Mandatory)][scriptblock]$ScriptBlock,
            [object[]]$ArgumentList = @(),
            [string]$ComputerName
        )
        if ($ComputerName) {
            $hostCall = {
                param([string]$vm, [pscredential]$guestCredential, [string]$text, [object[]]$arguments)
                Invoke-Command -VMName $vm -Credential $guestCredential -ScriptBlock ([scriptblock]::Create($text)) -ArgumentList $arguments
            }
            return Invoke-Command -ComputerName $ComputerName -ScriptBlock $hostCall -ArgumentList $VmName, $Credential, $ScriptBlock.ToString(), $ArgumentList
        }
        return Invoke-Command -VMName $VmName -Credential $Credential -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    }
}

function ConvertTo-GuestPlainText {
    param([object]$Value)
    if ($Value -is [securestring]) {
        return ConvertFrom-SecureString -SecureString $Value -AsPlainText
    }
    return [string]$Value
}

$username = $null
$password = $null
$clientId = $null
$clientSecret = $null
$credential = $null
try {
    $username = ConvertTo-GuestPlainText (Resolve-NIC26KeyVaultRef -Ref $LocalAdminUsernameRef)
    $password = ConvertTo-GuestPlainText (Resolve-NIC26KeyVaultRef -Ref $LocalAdminPasswordRef)
    $clientId = ConvertTo-GuestPlainText (Resolve-NIC26KeyVaultRef -Ref $OnboardingClientIdRef)
    $clientSecret = ConvertTo-GuestPlainText (Resolve-NIC26KeyVaultRef -Ref $OnboardingSecretRef)
    $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
    $credential = [pscredential]::new($username, $securePassword)
    $tagList = (@($Tags.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $Tags[$_] })) -join ','
    $allowList = @($ExtensionAllowList) -join ','

    foreach ($vm in $VmName) {
        if (-not $PSCmdlet.ShouldProcess($vm, 'Connect guest to Azure Arc')) {
            continue
        }
        $guestArguments = $null
        try {
            $joined = Invoke-HybridGuest -VmName $vm -Credential $credential -ComputerName $ComputerName -ScriptBlock {
                $statusText = (& dsregcmd /status) -join "`n"
                return [bool]($statusText -match '(?im)^\s*AzureAdJoined\s*:\s*YES\s*$')
            } -ArgumentList @()
            if ($joined -ne $true) {
                throw 'Guest is not Entra joined.'
            }

            $guestArguments = @(
                $clientId, $clientSecret, $TenantId, $SubscriptionId,
                $ArcResourceGroup, $Location, $vm, $tagList,
                [bool]$SetExtensionAllowList, $allowList
            )
            $result = Invoke-HybridGuest -VmName $vm -Credential $credential -ComputerName $ComputerName -ScriptBlock {
                param(
                    $servicePrincipalId, $servicePrincipalSecret, $tenant,
                    $subscription, $resourceGroup, $location, $resourceName,
                    $tags, $setAllowList, $allowList
                )
                $agent = Join-Path $env:ProgramW6432 'AzureConnectedMachineAgent\azcmagent.exe'
                if (-not (Test-Path -LiteralPath $agent)) {
                    throw 'The Azure Connected Machine agent is not installed in the image.'
                }
                $connect = @(
                    'connect', '--service-principal-id', $servicePrincipalId,
                    '--service-principal-secret', $servicePrincipalSecret,
                    '--tenant-id', $tenant, '--subscription-id', $subscription,
                    '--resource-group', $resourceGroup, '--location', $location,
                    '--resource-name', $resourceName, '--tags', $tags
                )
                $null = & $agent @connect
                if ($LASTEXITCODE -ne 0) {
                    throw 'Arc connection failed.'
                }
                if ($setAllowList) {
                    $null = & $agent config set extensions.allowlist $allowList
                    if ($LASTEXITCODE -ne 0) {
                        throw 'Extension configuration failed.'
                    }
                }
                $show = (& $agent show --json) -join "`n"
                if ($LASTEXITCODE -ne 0) {
                    throw 'Arc status check failed.'
                }
                return [pscustomobject]@{ Status = ($show | ConvertFrom-Json).status }
            } -ArgumentList $guestArguments
            if ($result.Status -ne 'Connected') {
                throw 'Arc agent is not Connected.'
            }
            [pscustomobject]@{ VmName = $vm; Joined = $true; ArcStatus = $result.Status }
        }
        catch {
            throw "Hybrid Arc onboarding failed for VM '$vm'."
        }
        finally {
            if ($null -ne $guestArguments) {
                [array]::Clear($guestArguments, 0, $guestArguments.Length)
            }
        }
    }
}
finally {
    $username = $null
    $password = $null
    $clientId = $null
    $clientSecret = $null
    $credential = $null
}
