#Requires -Version 7.0
<#
.SYNOPSIS
Removes a clustered hybrid VM and its dedicated CSV directory.
.DESCRIPTION
Destructive teardown: the owner must approve before it is run. Disconnect the Arc agent (azcmagent disconnect) or
delete the Arc machine in Azure first: Arc does not clean up a machine whose agent stopped heart-beating.
Requires -Execute, a -ConfirmName equal to the VM name, and an explicit -Confirm. Never deletes the master image or
the images directory.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER VmName
VM to remove.
.PARAMETER ConfirmName
Must exactly match VmName.
.PARAMETER CsvPath
Cluster shared volume containing the VM's hyperv directory.
.PARAMETER Execute
Permit destructive operations, subject to confirmation.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9-]{1,15}$')]
    [string]$VmName,

    [Parameter(Mandatory)]
    [string]$ConfirmName,

    [Parameter(Mandatory)]
    [string]$CsvPath,

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HybridCommon.psm1')

Write-Output 'Reminder: disconnect the Arc agent (azcmagent disconnect) or delete its Azure machine before teardown.'
if (-not [string]::Equals($ConfirmName, $VmName, [StringComparison]::Ordinal)) {
    throw 'ConfirmName must exactly match VmName.'
}
$parent = [IO.Path]::GetFullPath((Join-Path $CsvPath 'hyperv'))
$vmPath = Resolve-HybridPath -Parent $parent -Child $VmName
if (-not $Execute) {
    [pscustomobject]@{
        Step   = 'Remove cluster role, VM, and dedicated directory'
        Detail = $vmPath
    }
    return
}
if (-not $PSBoundParameters.ContainsKey('Confirm')) {
    throw 'Pass -Confirm explicitly: teardown is destructive.'
}
if (-not $PSCmdlet.ShouldProcess($VmName, 'Remove cluster role, VM, and dedicated CSV directory')) {
    return
}

$group = Get-ClusterGroup -Name $VmName -ErrorAction SilentlyContinue
if ($null -ne $group) {
    Remove-ClusterGroup -Name $VmName -RemoveResources -Force
}
$vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($null -ne $vm) {
    if ($vm.State -eq 'Running') {
        Stop-VM -Name $VmName -TurnOff -Force
    }
    Remove-VM -Name $VmName -Force
}
# Re-resolve immediately before deleting: Resolve-HybridPath rejects traversal and sibling folders that share a prefix.
$vmPath = Resolve-HybridPath -Parent $parent -Child $VmName
if (Test-Path -LiteralPath $vmPath) {
    Remove-Item -LiteralPath $vmPath -Recurse -Force
}
