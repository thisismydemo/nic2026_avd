#Requires -Version 7.0
<#
.SYNOPSIS
Builds a plain, clustered Generation 2 Hyper-V session-host VM.
.DESCRIPTION
Run locally on the VM's preferred owner node (Add-ClusterVirtualMachineRole cannot run remotely without CredSSP).
Without -Execute, prints the plan only. Resolve-NIC26KeyVaultRef must be available (NIC26.Automation imported) to
resolve the three keyvault:// references in memory; the Entra bulk-enrollment package is written only into the
mounted image, never to another disk path. The VM is not started unless -Start is given.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER VmName
VM, computer, and Arc machine name.
.PARAMETER OwnerNode
Preferred owner and node on which this script runs.
.PARAMETER StaticMacAddress
Static MAC address.
.PARAMETER CsvPath
Cluster shared volume path.
.PARAMETER MasterVhdx
Master VHDX path, absolute or relative to CsvPath.
.PARAMETER ComputeSwitchNamePattern
Wildcard pattern matching exactly one existing Network ATC switch.
.PARAMETER AccessVlanId
Access VLAN ID.
.PARAMETER CpuCount
Virtual processor count.
.PARAMETER MemoryGB
Static startup memory in gigabytes.
.PARAMETER DiskGB
Requested disk size in gigabytes.
.PARAMETER AntiAffinityClassName
Cluster anti-affinity class.
.PARAMETER Notes
Additional VM notes.
.PARAMETER TimeZone
Windows time-zone identifier.
.PARAMETER LocalAdminUsernameRef
Key Vault reference for the administrator username.
.PARAMETER LocalAdminPasswordRef
Key Vault reference for the administrator password.
.PARAMETER EntraBulkTokenRef
Key Vault reference for the base64 provisioning package.
.PARAMETER Start
Start the VM after clustering and anti-affinity configuration.
.PARAMETER Execute
Apply the plan instead of printing it.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'LocalAdminPasswordRef', Justification = 'A keyvault:// reference (a name), not a password; the value is resolved in memory.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The value was just resolved from Key Vault in memory and must become a SecureString/PSCredential for the downstream API.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9-]{1,15}$')]
    [string]$VmName,

    [Parameter(Mandatory)]
    [string]$OwnerNode,

    [Parameter(Mandatory)]
    [string]$StaticMacAddress,

    [Parameter(Mandatory)]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [string]$MasterVhdx,

    [Parameter(Mandatory)]
    [string]$ComputeSwitchNamePattern,

    [Parameter(Mandatory)]
    [ValidateRange(1, 4094)]
    [int]$AccessVlanId,

    [Parameter(Mandatory)]
    [ValidateRange(1, 256)]
    [int]$CpuCount,

    [Parameter(Mandatory)]
    [ValidateRange(1, 65536)]
    [int]$MemoryGB,

    [Parameter(Mandatory)]
    [ValidateRange(1, 1048576)]
    [int]$DiskGB,

    [Parameter(Mandatory)]
    [string]$AntiAffinityClassName,

    [Parameter(Mandatory)]
    [string]$Notes,

    [Parameter(Mandatory)]
    [string]$TimeZone,

    [Parameter(Mandatory)]
    [ValidatePattern('^keyvault://')]
    [string]$LocalAdminUsernameRef,

    [Parameter(Mandatory)]
    [ValidatePattern('^keyvault://')]
    [string]$LocalAdminPasswordRef,

    [Parameter(Mandatory)]
    [ValidatePattern('^keyvault://')]
    [string]$EntraBulkTokenRef,

    [switch]$Start,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HybridCommon.psm1')

if (-not (Get-Command Write-HybridImageFile -ErrorAction SilentlyContinue)) {
    function Write-HybridImageFile {
        <#
        .SYNOPSIS
        Writes one file directly into a mounted image.
        .DESCRIPTION
        Creates its parent directory and writes bytes without emitting their contents.
        .PARAMETER Path
        Destination in the mounted image.
        .PARAMETER Bytes
        File contents.
        #>
        [CmdletBinding(SupportsShouldProcess)]
        param(
            [Parameter(Mandatory)]
            [string]$Path,

            [Parameter(Mandatory)]
            [byte[]]$Bytes
        )

        if ($PSCmdlet.ShouldProcess($Path, 'Write mounted-image file')) {
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
            [IO.File]::WriteAllBytes($Path, $Bytes)
        }
    }
}

if (-not (Get-Command Test-HybridWindowsFolder -ErrorAction SilentlyContinue)) {
    function Test-HybridWindowsFolder {
        <#
        .SYNOPSIS
        Tests whether a path in the mounted image exists.
        .DESCRIPTION
        Thin wrapper so tests can run without a mounted drive.
        .PARAMETER Path
        Path to test.
        #>
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Path)
        return (Test-Path -LiteralPath $Path -PathType Container)
    }
}

if (-not (Get-Command Set-HybridAntiAffinity -ErrorAction SilentlyContinue)) {
    function Set-HybridAntiAffinity {
        <#
        .SYNOPSIS
        Sets the cluster group's anti-affinity class.
        .DESCRIPTION
        Assigns one anti-affinity class to an existing cluster group.
        .PARAMETER Name
        Cluster group name.
        .PARAMETER ClassName
        Anti-affinity class name.
        #>
        [CmdletBinding(SupportsShouldProcess)]
        param(
            [Parameter(Mandatory)]
            [string]$Name,

            [Parameter(Mandatory)]
            [string]$ClassName
        )

        if ($PSCmdlet.ShouldProcess($Name, 'Set anti-affinity class')) {
            $group = Get-ClusterGroup -Name $Name
            $group.AntiAffinityClassNames = [string[]]@($ClassName)
        }
    }
}

if (-not $Execute) {
    Get-HybridVmPlan -VmName $VmName
    return
}

if (-not [string]::Equals($env:COMPUTERNAME, $OwnerNode, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Run this script locally on the preferred owner node.'
}
$mac = ConvertTo-HybridMacAddress -MacAddress $StaticMacAddress
$vmRoot = Resolve-HybridPath -Parent (Join-Path $CsvPath 'hyperv') -Child $VmName
$diskPath = Resolve-HybridPath -Parent $vmRoot -Child (Join-Path 'Virtual Hard Disks' "$VmName.vhdx")
$masterPath = if ([IO.Path]::IsPathFullyQualified($MasterVhdx)) {
    [IO.Path]::GetFullPath($MasterVhdx)
}
else {
    Resolve-HybridPath -Parent $CsvPath -Child $MasterVhdx
}
if ([string]::Equals($masterPath, $diskPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The destination must not be the master VHDX.'
}
if (Test-Path -LiteralPath $diskPath) {
    throw 'The VM disk path already exists (a previous run may have stopped part-way: dismount it with Dismount-VHD and remove the VM folder).'
}
if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
    throw "VM '$VmName' already exists."
}
$switch = Get-HybridComputeSwitch -NamePattern $ComputeSwitchNamePattern
if (-not (Test-Path -LiteralPath $masterPath -PathType Leaf)) {
    throw 'The master VHDX does not exist.'
}
$requestedBytes = [long]$DiskGB * 1GB
$masterDisk = Get-VHD -Path $masterPath
if ($requestedBytes -lt $masterDisk.Size) {
    throw 'DiskGB cannot be smaller than the master VHDX.'
}
if (-not (Get-Command Resolve-NIC26KeyVaultRef -ErrorAction SilentlyContinue)) {
    throw 'Resolve-NIC26KeyVaultRef is required.'
}
if (-not $PSCmdlet.ShouldProcess($VmName, 'Build clustered hybrid VM')) {
    return
}

$username = $null
$password = $null
$token = $null
$packageBytes = $null
$xml = $null
try {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($diskPath))
    Copy-Item -LiteralPath $masterPath -Destination $diskPath -ErrorAction Stop
    if ($requestedBytes -gt $masterDisk.Size) {
        Resize-VHD -Path $diskPath -SizeBytes $requestedBytes
    }

    $mounted = $null
    try {
        $mounted = Mount-VHD -Path $diskPath -Passthru
        $windowsRoot = $null
        foreach ($partition in @(Get-Partition -DiskNumber $mounted.Number)) {
            if ($partition.DriveLetter -and (Test-HybridWindowsFolder -Path "$($partition.DriveLetter):\Windows")) {
                $windowsRoot = "$($partition.DriveLetter):\Windows"
                break
            }
        }
        if (-not $windowsRoot) {
            throw 'No mounted partition contains a Windows directory.'
        }

        $username = Resolve-NIC26KeyVaultRef -Ref $LocalAdminUsernameRef
        $password = Resolve-NIC26KeyVaultRef -Ref $LocalAdminPasswordRef
        $token = Resolve-NIC26KeyVaultRef -Ref $EntraBulkTokenRef
        if ($username -is [securestring]) {
            $username = ConvertFrom-SecureString -SecureString $username -AsPlainText
        }
        if ($password -isnot [securestring]) {
            $password = ConvertTo-SecureString -String ([string]$password) -AsPlainText -Force
        }
        if ($token -is [securestring]) {
            $token = ConvertFrom-SecureString -SecureString $token -AsPlainText
        }

        $xml = New-HybridUnattendXml -ComputerName $VmName -TimeZone $TimeZone -LocalAdminUsername $username -LocalAdminPassword $password
        $packageBytes = [Convert]::FromBase64String($token)
        $joinScript = @'
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    Install-ProvisioningPackage -PackagePath 'C:\Windows\Setup\Scripts\avd-entra-join.ppkg' -QuietInstall -ForceInstall
}
finally {
    Remove-Item -LiteralPath 'C:\Windows\Setup\Scripts\avd-entra-join.ppkg', 'C:\Windows\Panther\Unattend\Unattend.xml', $PSCommandPath -Force -ErrorAction SilentlyContinue
}
'@
        Write-HybridImageFile -Path ([IO.Path]::Combine($windowsRoot, 'Panther\Unattend\Unattend.xml')) -Bytes ([Text.Encoding]::UTF8.GetBytes($xml))
        Write-HybridImageFile -Path ([IO.Path]::Combine($windowsRoot, 'Setup\Scripts\avd-entra-join.ppkg')) -Bytes $packageBytes
        Write-HybridImageFile -Path ([IO.Path]::Combine($windowsRoot, 'Setup\Scripts\Join-Entra.ps1')) -Bytes ([Text.Encoding]::UTF8.GetBytes($joinScript))
    }
    finally {
        $username = $null
        $password = $null
        $token = $null
        $packageBytes = $null
        $xml = $null
        if ($null -ne $mounted) {
            Dismount-VHD -Path $diskPath
        }
    }

    $memoryBytes = [long]$MemoryGB * 1GB
    New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $memoryBytes -VHDPath $diskPath -Path $vmRoot -SwitchName $switch.Name
    Set-VMProcessor -VMName $VmName -Count $CpuCount
    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false -StartupBytes $memoryBytes
    Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
    Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector
    Enable-VMTPM -VMName $VmName
    Set-VMNetworkAdapter -VMName $VmName -StaticMacAddress $mac
    Set-VMNetworkAdapterVlan -VMName $VmName -Access -VlanId $AccessVlanId
    Set-VM -Name $VmName -CheckpointType Disabled -AutomaticStartAction Start -AutomaticStopAction ShutDown -Notes $Notes
    Add-ClusterVirtualMachineRole -VMName $VmName
    Set-ClusterOwnerNode -Group $VmName -Owners ([string[]]@($OwnerNode))
    Set-HybridAntiAffinity -Name $VmName -ClassName $AntiAffinityClassName
    if ($Start) {
        Start-VM -Name $VmName
    }
}
finally {
    $username = $null
    $password = $null
    $token = $null
    $packageBytes = $null
}
