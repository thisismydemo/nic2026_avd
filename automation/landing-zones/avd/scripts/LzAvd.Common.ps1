#Requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for the lz-avd scripts (dot-sourced; not a module on purpose so each script stays self-contained).
.DESCRIPTION
    Wraps the NIC26.Automation module (Get-NIC26Config, converters, Write-NIC26Log, Invoke-NIC26WithRetry) when it is
    present and degrades to local equivalents when it is not, so authoring-time tests run without the module.
    Nothing here calls Azure.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LzAvdSolutionRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Split-Path -Parent $PSScriptRoot)
}

function Import-LzAvdAutomationModule {
    <#
    .SYNOPSIS
        Imports automation/shared/powershell/NIC26.Automation. Returns $true when loaded, $false when -Optional and absent.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [switch]$Optional
    )
    if (Get-Module -Name 'NIC26.Automation') { return $true }
    $candidate = Join-Path (Get-LzAvdSolutionRoot) '..\..\shared\powershell\NIC26.Automation\NIC26.Automation.psd1'
    if (Test-Path -Path $candidate) {
        Import-Module -Name $candidate -Force
        return $true
    }
    if (Get-Module -ListAvailable -Name 'NIC26.Automation') {
        Import-Module -Name 'NIC26.Automation'
        return $true
    }
    if ($Optional) { return $false }
    throw "NIC26.Automation was not found at '$candidate'. It is built by the shared-module owner (automation/CONTRACT.md section 1)."
}

function Write-LzAvdLog {
    <#
    .SYNOPSIS
        Logs through Write-NIC26Log when available, otherwise through the information/warning streams. Never logs values.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Verbose')][string]$Level = 'Info',
        [string]$Source = 'lz-avd'
    )
    if (Get-Command -Name 'Write-NIC26Log' -ErrorAction SilentlyContinue) {
        Write-NIC26Log -Message $Message -Level $Level -Source $Source
        return
    }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = "[$stamp] [$Source] [$Level] $Message"
    switch ($Level) {
        'Warning' { Write-Warning -Message $line }
        'Error' { Write-Error -Message $line -ErrorAction Continue }
        'Verbose' { Write-Verbose -Message $line }
        default { Write-Information -MessageData $line -InformationAction Continue }
    }
}

function Invoke-LzAvdWithRetry {
    <#
    .SYNOPSIS
        Bounded exponential backoff (default cap 300 s) for RBAC propagation and eventual consistency (contract section 7).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxSeconds = 300,
        [int]$InitialDelaySeconds = 5,
        [string]$Activity = 'operation'
    )
    if (Get-Command -Name 'Invoke-NIC26WithRetry' -ErrorAction SilentlyContinue) {
        # shared module signature: -ScriptBlock -MaxMinutes -InitialSeconds -Activity
        return (Invoke-NIC26WithRetry -ScriptBlock $ScriptBlock -MaxMinutes ($MaxSeconds / 60.0) -InitialSeconds $InitialDelaySeconds -Activity $Activity)
    }
    $delay = [Math]::Max(1, $InitialDelaySeconds)
    $elapsed = 0
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return (& $ScriptBlock)
        }
        catch {
            if (($elapsed + $delay) -gt $MaxSeconds) {
                throw "Retry budget of $MaxSeconds s exhausted for '$Activity' after $attempt attempts: $($_.Exception.Message)"
            }
            Write-LzAvdLog -Level Warning -Message "Attempt $attempt for '$Activity' failed; retrying in $delay s."
            Start-Sleep -Seconds $delay
            $elapsed += $delay
            $delay = [Math]::Min($delay * 2, 60)
        }
    }
}

function Get-LzAvdInputs {
    <#
    .SYNOPSIS
        Reads the generated canonical input set (terraform.generated.tfvars.json or the example file) as a hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$InputFile
    )
    if (-not (Test-Path -Path $InputFile)) { throw "Input file '$InputFile' not found. Run ConvertTo-NIC26TfVars -Solution lz-avd first." }
    $inputs = Get-Content -Path $InputFile -Raw | ConvertFrom-Json -AsHashtable
    foreach ($required in 'names', 'subscription_id_avd', 'location', 'lab_token') {
        if (-not $inputs.ContainsKey($required)) { throw "Input file '$InputFile' lacks required key '$required'." }
    }
    return $inputs
}

function Test-LzAvdResourceInSubscription {
    <#
    .SYNOPSIS
        True only when a resource id belongs to the given subscription (case-insensitive, exact segment match).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$SubscriptionId
    )
    return ($ResourceId -match ('^/subscriptions/' + [regex]::Escape($SubscriptionId) + '(/|$)'))
}

function Test-LzAvdIpInCidr {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][string]$Cidr
    )
    $parts = $Cidr.Split('/')
    $network = [System.Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
    $candidate = [System.Net.IPAddress]::Parse($IpAddress).GetAddressBytes()
    [Array]::Reverse($network); [Array]::Reverse($candidate)
    $mask = [uint32]::MaxValue -shl (32 - [int]$parts[1])
    return (([BitConverter]::ToUInt32($network, 0) -band $mask) -eq ([BitConverter]::ToUInt32($candidate, 0) -band $mask))
}

function ConvertTo-LzAvdSecureString {
    <#
    .SYNOPSIS
        Builds a SecureString character by character (no plaintext conversion cmdlet; the caller clears the source).
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)][char[]]$Characters
    )
    $secure = [securestring]::new()
    foreach ($c in $Characters) { $secure.AppendChar($c) }
    $secure.MakeReadOnly()
    return $secure
}

function New-LzAvdRandomPassword {
    <#
    .SYNOPSIS
        Generates a complex password in memory and returns it as a char array (caller zeroes it after use).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([char[]])]
    param(
        [ValidateRange(16, 128)][int]$Length = 24
    )
    if (-not $PSCmdlet.ShouldProcess('in-memory password', 'generate')) { return [char[]]@() }
    $upper = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = [char[]]'abcdefghijkmnopqrstuvwxyz'
    $digit = [char[]]'23456789'
    $symbol = [char[]]'!@#$%&*-_=+?'
    $all = $upper + $lower + $digit + $symbol
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $pick = {
            param([char[]]$set)
            $bytes = [byte[]]::new(4)
            $rng.GetBytes($bytes)
            return $set[[BitConverter]::ToUInt32($bytes, 0) % $set.Length]
        }
        $chars = [System.Collections.Generic.List[char]]::new()
        $chars.Add((& $pick $upper)); $chars.Add((& $pick $lower)); $chars.Add((& $pick $digit)); $chars.Add((& $pick $symbol))
        while ($chars.Count -lt $Length) { $chars.Add((& $pick $all)) }
        # Fisher-Yates shuffle with the CSPRNG
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $bytes = [byte[]]::new(4)
            $rng.GetBytes($bytes)
            $j = [int]([BitConverter]::ToUInt32($bytes, 0) % ($i + 1))
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        return , $chars.ToArray()
    }
    finally {
        $rng.Dispose()
    }
}

function Clear-LzAvdCharArray {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][char[]]$Characters
    )
    if ($PSCmdlet.ShouldProcess('char array', 'zero')) {
        for ($i = 0; $i -lt $Characters.Length; $i++) { $Characters[$i] = [char]0 }
    }
}

function Assert-LzAvdWindowsHost {
    <#
    .SYNOPSIS
        Scripts that touch secret values must run on the Windows jump server (SecureString is only protected on Windows).
    #>
    [CmdletBinding()]
    param()
    if (-not $IsWindows) {
        throw 'This script handles secret values and must run on the Windows lab jump server (keyvault-and-secrets.md K-8).'
    }
    if (Get-Variable -Name Transcript -Scope Global -ErrorAction SilentlyContinue) {
        throw 'A transcript appears to be active; Start-Transcript is forbidden around secret handling (contract section 3).'
    }
}

function Test-LzAvdCommand {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}
