#Requires -Version 7.0
<#
.SYNOPSIS
Builds DHCP reservation data from the Hybrid VM records.
.DESCRIPTION
Validates and normalizes the VM records (MAC to lower-case colon form, IPv4, no duplicates, host name at most 15
characters) and emits {hostname, mac, ip, vlan_id} rows for your DHCP server or network automation. Without -Execute, returns the
rows and writes nothing. An existing output file is replaced only with -Force.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER Vms
VM objects with name, owner_node, mac_address and ip_address.
.PARAMETER VmsJsonPath
Path to a JSON array of VM objects, as an alternative to -Vms.
.PARAMETER VlanId
VLAN ID of the reservations.
.PARAMETER OutputPath
Destination JSON file.
.PARAMETER Force
Allow an existing output file to be replaced.
.PARAMETER Execute
Write the output file instead of only returning the rows.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, ParameterSetName = 'Objects')]
    [object[]]$Vms,

    [Parameter(Mandatory, ParameterSetName = 'Json')]
    [string]$VmsJsonPath,

    [Parameter(Mandatory)]
    [ValidateRange(1, 4094)]
    [int]$VlanId,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [switch]$Force,

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSCmdlet.ParameterSetName -eq 'Json') {
    $Vms = @(Get-Content -LiteralPath $VmsJsonPath -Raw | ConvertFrom-Json)
}

$rows = [System.Collections.Generic.List[object]]::new()
$macs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$ips = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($vm in $Vms) {
    $name = [string]$vm.name
    $mac = [string]$vm.mac_address
    $ip = [string]$vm.ip_address
    if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 15 -or [string]::IsNullOrWhiteSpace([string]$vm.owner_node)) {
        throw 'Each VM needs a name of at most 15 characters and an owner_node.'
    }
    if ($mac -notmatch '^(?:[0-9a-fA-F]{2}-){5}[0-9a-fA-F]{2}$' -and $mac -notmatch '^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$') {
        throw "Invalid MAC address for $name."
    }
    $normalizedMac = ($mac -replace '-', ':').ToLowerInvariant()
    $octets = $ip.Split('.')
    if ($octets.Count -ne 4) {
        throw "Invalid IPv4 address for $name."
    }
    $bytes = [System.Collections.Generic.List[byte]]::new()
    foreach ($octet in $octets) {
        $parsed = [byte]0
        if ($octet -notmatch '^\d{1,3}$' -or -not [byte]::TryParse($octet, [ref]$parsed)) {
            throw "Invalid IPv4 address for $name."
        }
        $bytes.Add($parsed)
    }
    $normalizedIp = $bytes.ToArray() -join '.'
    if (-not $names.Add($name) -or -not $macs.Add($normalizedMac) -or -not $ips.Add($normalizedIp)) {
        throw 'Duplicate hostname, MAC address, or IP address.'
    }
    $rows.Add([pscustomobject]@{
            hostname = $name
            mac      = $normalizedMac
            ip       = $normalizedIp
            vlan_id  = $VlanId
        })
}

if (-not $Execute) {
    $rows.ToArray()
    return
}
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    throw 'Output file already exists; specify -Force to replace it.'
}
if ($PSCmdlet.ShouldProcess($OutputPath, 'Write DHCP reservation JSON')) {
    $json = ConvertTo-Json -InputObject $rows.ToArray() -Depth 5
    [System.IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath), $json)
    $rows.ToArray()
}
