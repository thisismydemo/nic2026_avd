#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test fixtures only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Stubs mirror the real cmdlet signatures.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/HybridCommon.psm1') -Force
    $script:buildScript = Join-Path $PSScriptRoot '../scripts/New-HybridVm.ps1'
    $script:removeScript = Join-Path $PSScriptRoot '../scripts/Remove-HybridVm.ps1'
    $script:syncScript = Join-Path $PSScriptRoot '../scripts/Sync-HybridGuardianCertificates.ps1'
    $global:HybridTestCalls = [Collections.Generic.List[string]]::new()
    $global:HybridTestPaths = [Collections.Generic.List[string]]::new()
    $global:HybridTestState = @{ Switches = 1; VmExists = $false; FailWrite = $false }

    # Stubs declare the REAL cmdlet parameter lists (Hyper-V module, FailoverClusters): a wrong parameter name fails binding.
    function global:Resolve-NIC26KeyVaultRef {
        param([string]$Ref, [switch]$AsPlainText)
        if ($Ref -like '*username*') { return 'Administrator' }
        if ($Ref -like '*password*') { return (ConvertTo-SecureString 'PrivateLabSecret' -AsPlainText -Force) }
        return [Convert]::ToBase64String([byte[]](1, 2, 3))
    }
    function global:Get-VMSwitch {
        param($Name, $Id, $SwitchType, $ResourcePoolName, $CimSession, $ComputerName, $Credential)
        $global:HybridTestCalls.Add('Get-VMSwitch')
        1..$global:HybridTestState.Switches | ForEach-Object { [pscustomobject]@{ Name = "ComputeSwitch$_" } }
    }
    function global:Get-VM {
        param($Name, $Id, $ClusterObject, $CimSession, $ComputerName, $Credential)
        if ($global:HybridTestState.VmExists) { [pscustomobject]@{ Name = $Name; State = 'Running' } }
    }
    function global:Get-VHD {
        param($Path, $DiskNumber, $VMId, $CimSession, $ComputerName, $Credential)
        [pscustomobject]@{ Size = 1GB }
    }
    function global:Resize-VHD {
        param($Path, $SizeBytes, [switch]$ToMinimumSize, [switch]$Passthru, $CimSession, $ComputerName, $Credential)
        $global:HybridTestCalls.Add('Resize-VHD')
    }
    function global:Mount-VHD {
        param($Path, [switch]$NoDriveLetter, [switch]$ReadOnly, [switch]$Passthru, $CimSession, $ComputerName, $Credential)
        $global:HybridTestCalls.Add('Mount-VHD')
        [pscustomobject]@{ Number = 8 }
    }
    function global:Dismount-VHD {
        param($Path, $DiskNumber, $SnapshotId, [switch]$Passthru, $CimSession, $ComputerName, $Credential)
        $global:HybridTestCalls.Add('Dismount-VHD')
    }
    function global:Get-Partition { param($DiskNumber) [pscustomobject]@{ DriveLetter = 'Z' } }
    function global:Test-HybridWindowsFolder { param([string]$Path) $true }
    function global:New-VM {
        param($Name, $MemoryStartupBytes, $BootDevice, $NoVHD, $SwitchName, $NewVHDPath, $NewVHDSizeBytes, $VHDPath, $Path,
            $SourceGuestStatePath, $Version, $Prerelease, $Experimental, $Generation, $GuestStateIsolationType, $Force,
            $AsJob, $CimSession, $ComputerName, $Credential)
        $global:HybridTestCalls.Add('New-VM')
    }
    function global:Set-VMProcessor { param($VMName, $VM, $VMProcessor, $Count, $CompatibilityForMigrationEnabled, $ExposeVirtualizationExtensions, $Passthru) $global:HybridTestCalls.Add('Set-VMProcessor') }
    function global:Set-VMMemory { param($VMName, $VM, $VMMemory, $DynamicMemoryEnabled, $StartupBytes, $MinimumBytes, $MaximumBytes, $Passthru) $global:HybridTestCalls.Add('Set-VMMemory') }
    function global:Set-VMFirmware { param($VMName, $VM, $VMFirmware, $EnableSecureBoot, $SecureBootTemplate, $FirstBootDevice, $BootOrder, $Passthru) $global:HybridTestCalls.Add('Set-VMFirmware') }
    function global:Set-VMKeyProtector { param($VM, $VMName, $KeyProtector, [switch]$NewLocalKeyProtector, [switch]$RestoreLastKnownGoodKeyProtector, [switch]$Passthru) $global:HybridTestCalls.Add('Set-VMKeyProtector') }
    function global:Enable-VMTPM { param($VM, $VMName, [switch]$Passthru) $global:HybridTestCalls.Add('Enable-VMTPM') }
    function global:Set-VMNetworkAdapter { param($VMName, $VM, $VMNetworkAdapter, $Name, $StaticMacAddress, $DynamicMacAddress, $MacAddressSpoofing, $ManagementOS) $global:HybridTestCalls.Add('Set-VMNetworkAdapter') }
    function global:Set-VMNetworkAdapterVlan { param($VMName, $VM, $VMNetworkAdapter, $VMNetworkAdapterName, [switch]$Access, $VlanId, [switch]$Untagged, [switch]$Trunk, [switch]$ManagementOS, [switch]$Passthru) $global:HybridTestCalls.Add('Set-VMNetworkAdapterVlan') }
    function global:Set-VM { param($Name, $VM, $CheckpointType, $AutomaticStartAction, $AutomaticStopAction, $Notes, $ProcessorCount, $MemoryStartupBytes, $Passthru) $global:HybridTestCalls.Add('Set-VM') }
    function global:Start-VM { param($Name, $VM, $Passthru, $AsJob) $global:HybridTestCalls.Add('Start-VM') }
    function global:Stop-VM { param($Name, $VM, [switch]$TurnOff, [switch]$Save, [switch]$Force, [switch]$Passthru) $global:HybridTestCalls.Add('Stop-VM') }
    function global:Remove-VM { param($Name, $VM, [switch]$Force, [switch]$Passthru) $global:HybridTestCalls.Add('Remove-VM') }
    function global:Add-ClusterVirtualMachineRole { param([string]$VMName, [string]$VirtualMachine, [string]$Name, [guid]$VMId, [string]$Cluster) $global:HybridTestCalls.Add('Add-ClusterVirtualMachineRole') }
    function global:Set-ClusterOwnerNode { param([string]$Group, [string[]]$Owners, [string]$Resource, [string]$Cluster) $global:HybridTestCalls.Add('Set-ClusterOwnerNode') }
    function global:Get-ClusterGroup { param([string]$Name, [string]$Cluster) $global:HybridTestCalls.Add('Get-ClusterGroup'); [pscustomobject]@{ AntiAffinityClassNames = [string[]]@() } }
    function global:Remove-ClusterGroup { param([string]$Name, [switch]$RemoveResources, [switch]$Force, [string]$Cluster) $global:HybridTestCalls.Add('Remove-ClusterGroup') }
    function global:Write-HybridImageFile {
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$Path, [byte[]]$Bytes)
        if ($global:HybridTestState.FailWrite) { throw 'simulated write failure' }
        $global:HybridTestPaths.Add($Path)
        $global:HybridTestCalls.Add('Write-HybridImageFile')
    }

    $script:csv = Join-Path $TestDrive 'csv'
    New-Item -ItemType Directory -Path $script:csv -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $script:csv 'master.vhdx') -Value 'x'
    $script:parameters = @{
        VmName                   = 'Host01'
        OwnerNode                = 'Owner01'
        StaticMacAddress         = '00-15-5D-26-04-01'
        CsvPath                  = $script:csv
        MasterVhdx               = 'master.vhdx'
        ComputeSwitchNamePattern = 'Compute*'
        AccessVlanId             = 26
        CpuCount                 = 2
        MemoryGB                 = 4
        DiskGB                   = 2
        AntiAffinityClassName    = 'session-hosts'
        Notes                    = 'test'
        TimeZone                 = 'UTC'
        LocalAdminUsernameRef    = 'keyvault://kv-test/username'
        LocalAdminPasswordRef    = 'keyvault://kv-test/password'
        EntraBulkTokenRef        = 'keyvault://kv-test/token'
    }
    $script:previousComputerName = $env:COMPUTERNAME
}

AfterAll {
    $env:COMPUTERNAME = $script:previousComputerName
    Remove-Item Function:\Resolve-NIC26KeyVaultRef -ErrorAction SilentlyContinue
    foreach ($name in @('Get-VMSwitch', 'Get-VM', 'Get-VHD', 'Resize-VHD', 'Mount-VHD', 'Dismount-VHD', 'Get-Partition',
            'New-VM', 'Set-VMProcessor', 'Set-VMMemory', 'Set-VMFirmware', 'Set-VMKeyProtector', 'Enable-VMTPM',
            'Set-VMNetworkAdapter', 'Set-VMNetworkAdapterVlan', 'Set-VM', 'Start-VM', 'Stop-VM', 'Remove-VM',
            'Add-ClusterVirtualMachineRole', 'Set-ClusterOwnerNode', 'Get-ClusterGroup', 'Remove-ClusterGroup',
            'Write-HybridImageFile', 'Test-HybridWindowsFolder')) {
        Remove-Item "Function:\$name" -ErrorAction SilentlyContinue
    }
    Remove-Variable HybridTestCalls, HybridTestPaths, HybridTestState -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Hybrid pure functions' {
    It 'normalizes supported MAC forms and rejects invalid input' {
        ConvertTo-HybridMacAddress '00-15-5D-26-04-01' | Should -Be '00155D260401'
        ConvertTo-HybridMacAddress '00:15:5d:26:04:01' | Should -Be '00155D260401'
        ConvertTo-HybridMacAddress '00155d260401' | Should -Be '00155D260401'
        { ConvertTo-HybridMacAddress '00-15:5D-26-04-01' } | Should -Throw
        { ConvertTo-HybridMacAddress 'not-a-mac' } | Should -Throw
    }

    It 'produces well-formed unattend XML without the plaintext password' {
        $password = ConvertTo-SecureString 'PrivateLabSecret' -AsPlainText -Force
        $xmlText = New-HybridUnattendXml -ComputerName 'Host01' -TimeZone 'UTC' -LocalAdminUsername 'Administrator' -LocalAdminPassword $password
        { [void][xml]$xmlText } | Should -Not -Throw
        $xmlText | Should -Match 'Host01'
        $xmlText | Should -Match ([regex]::Escape([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('PrivateLabSecretPassword'))))
        $xmlText | Should -Not -Match 'PrivateLabSecret<'
        $xmlText | Should -Not -Match '>PrivateLabSecret'
        { New-HybridUnattendXml -ComputerName 'SixteenCharNameX' -TimeZone 'UTC' -LocalAdminUsername 'Administrator' -LocalAdminPassword $password } | Should -Throw
    }

    It 'gives every unattend component its full identity and avoids the deprecated OOBE skips' {
        $password = ConvertTo-SecureString 'PrivateLabSecret' -AsPlainText -Force
        $document = [xml](New-HybridUnattendXml -ComputerName 'Host01' -TimeZone 'UTC' -LocalAdminUsername 'Administrator' -LocalAdminPassword $password)
        $namespaceManager = [System.Xml.XmlNamespaceManager]::new($document.NameTable)
        $namespaceManager.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $components = $document.SelectNodes('//u:component', $namespaceManager)
        $components.Count | Should -Be 3
        foreach ($component in $components) {
            $component.GetAttribute('processorArchitecture') | Should -Be 'amd64'
            $component.GetAttribute('publicKeyToken') | Should -Be '31bf3856ad364e35'
            $component.GetAttribute('language') | Should -Be 'neutral'
            $component.GetAttribute('versionScope') | Should -Be 'nonSxS'
        }
        $document.OuterXml | Should -Not -Match 'SkipMachineOOBE|SkipUserOOBE'
        $document.OuterXml | Should -Match 'ProtectYourPC'
        $document.OuterXml | Should -Match 'wcm:action="add"'
    }

    It 'rejects traversal and sibling folders that share a prefix' {
        $parent = Join-Path $TestDrive 'csv/hyperv'
        { Resolve-HybridPath -Parent $parent -Child '../images' } | Should -Throw
        { Resolve-HybridPath -Parent $parent -Child '../hyperv-old/vm' } | Should -Throw
        Resolve-HybridPath -Parent $parent -Child 'vm' | Should -Match 'vm$'
    }

    It 'orders the key protector before the TPM and clustering after the VM configuration' {
        $steps = @((Get-HybridVmPlan -VmName 'Host01').Step)
        [array]::IndexOf($steps, 'Enable-VMTPM') | Should -BeGreaterThan ([array]::IndexOf($steps, 'Set-VMKeyProtector'))
        [array]::IndexOf($steps, 'Add-ClusterVirtualMachineRole') | Should -BeGreaterThan ([array]::IndexOf($steps, 'Set-VM'))
        [array]::IndexOf($steps, 'Dismount-VHD') | Should -BeLessThan ([array]::IndexOf($steps, 'New-VM'))
    }

    It 'requires exactly one matching switch' {
        $global:HybridTestState.Switches = 0
        { Get-HybridComputeSwitch -NamePattern 'Compute*' } | Should -Throw
        $global:HybridTestState.Switches = 2
        { Get-HybridComputeSwitch -NamePattern 'Compute*' } | Should -Throw
        $global:HybridTestState.Switches = 1
        (Get-HybridComputeSwitch -NamePattern 'Compute*').Name | Should -Be 'ComputeSwitch1'
    }
}

Describe 'New-HybridVm' {
    BeforeEach {
        $global:HybridTestCalls.Clear()
        $global:HybridTestPaths.Clear()
        $global:HybridTestState.Switches = 1
        $global:HybridTestState.VmExists = $false
        $global:HybridTestState.FailWrite = $false
        $env:COMPUTERNAME = 'Owner01'
        Remove-Item -LiteralPath (Join-Path $script:csv 'hyperv') -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'invokes no infrastructure without Execute' {
        $plan = @(& $script:buildScript @script:parameters)
        $plan.Count | Should -BeGreaterThan 10
        $global:HybridTestCalls.Count | Should -Be 0
    }

    It 'runs the documented order with the secrets in no stream' {
        $streams = & $script:buildScript @script:parameters -Execute -Confirm:$false -InformationAction Continue -Verbose *>&1
        $expected = @('Get-VMSwitch', 'Resize-VHD', 'Mount-VHD', 'Write-HybridImageFile', 'Write-HybridImageFile', 'Write-HybridImageFile',
            'Dismount-VHD', 'New-VM', 'Set-VMProcessor', 'Set-VMMemory', 'Set-VMFirmware', 'Set-VMKeyProtector', 'Enable-VMTPM',
            'Set-VMNetworkAdapter', 'Set-VMNetworkAdapterVlan', 'Set-VM', 'Add-ClusterVirtualMachineRole',
            'Set-ClusterOwnerNode', 'Get-ClusterGroup')
        ($global:HybridTestCalls -join ',') | Should -Be ($expected -join ',')
        ($streams | Out-String) | Should -Not -Match 'PrivateLabSecret'
        $global:HybridTestCalls | Should -Not -Contain 'Start-VM'
    }

    It 'writes the image files only under the mounted drive letter' {
        & $script:buildScript @script:parameters -Execute -Confirm:$false | Out-Null
        $global:HybridTestPaths.Count | Should -Be 3
        foreach ($path in $global:HybridTestPaths) { $path | Should -Match '^Z:\\Windows\\' }
    }

    It 'starts the VM only with -Start, last' {
        & $script:buildScript @script:parameters -Execute -Confirm:$false -Start | Out-Null
        $global:HybridTestCalls[-1] | Should -Be 'Start-VM'
    }

    It 'dismounts the disk even when writing into the image fails' {
        $global:HybridTestState.FailWrite = $true
        { & $script:buildScript @script:parameters -Execute -Confirm:$false } | Should -Throw
        $global:HybridTestCalls | Should -Contain 'Dismount-VHD'
        $global:HybridTestCalls | Should -Not -Contain 'New-VM'
    }

    It 'refuses to run on another node' {
        $env:COMPUTERNAME = 'OtherNode'
        { & $script:buildScript @script:parameters -Execute -Confirm:$false } | Should -Throw '*preferred owner*'
        $global:HybridTestCalls.Count | Should -Be 0
    }

    It 'refuses when the VM disk already exists (a previous run stopped part-way)' {
        $disk = Join-Path $script:csv 'hyperv/Host01/Virtual Hard Disks/Host01.vhdx'
        New-Item -ItemType Directory -Path (Split-Path $disk) -Force | Out-Null
        Set-Content -LiteralPath $disk -Value 'x'
        { & $script:buildScript @script:parameters -Execute -Confirm:$false } | Should -Throw '*already exists*'
        $global:HybridTestCalls | Should -Not -Contain 'Mount-VHD'
    }

    It 'refuses when the VM already exists' {
        $global:HybridTestState.VmExists = $true
        { & $script:buildScript @script:parameters -Execute -Confirm:$false } | Should -Throw '*already exists*'
        $global:HybridTestCalls | Should -Not -Contain 'Mount-VHD'
    }

    It 'refuses when the switch pattern matches zero or two switches' {
        foreach ($count in 0, 2) {
            $global:HybridTestState.Switches = $count
            { & $script:buildScript @script:parameters -Execute -Confirm:$false } | Should -Throw '*exactly one compute switch*'
        }
        $global:HybridTestCalls | Should -Not -Contain 'Mount-VHD'
    }
}

Describe 'Remove-HybridVm' {
    BeforeEach { $global:HybridTestCalls.Clear() }

    It 'requires the confirmation name to match' {
        { & $script:removeScript -VmName 'Host01' -ConfirmName 'Different' -CsvPath $script:csv -Execute -Confirm:$false } | Should -Throw '*ConfirmName*'
        $global:HybridTestCalls.Count | Should -Be 0
    }

    It 'plans without removing anything' {
        $row = @(& $script:removeScript -VmName 'Host01' -ConfirmName 'Host01' -CsvPath $script:csv | Where-Object { $_ -isnot [string] })
        $row[0].Detail | Should -Match 'hyperv'
        $global:HybridTestCalls.Count | Should -Be 0
    }

    It 'removes the role, VM and folder in order, only inside hyperv' {
        $vmFolder = Join-Path $script:csv 'hyperv/Host01'
        New-Item -ItemType Directory -Path $vmFolder -Force | Out-Null
        $images = Join-Path $script:csv 'images'
        New-Item -ItemType Directory -Path $images -Force | Out-Null
        & $script:removeScript -VmName 'Host01' -ConfirmName 'Host01' -CsvPath $script:csv -Execute -Confirm:$false | Out-Null
        ($global:HybridTestCalls -join ',') | Should -Be 'Get-ClusterGroup,Remove-ClusterGroup'
        Test-Path -LiteralPath $vmFolder | Should -BeFalse
        Test-Path -LiteralPath $images | Should -BeTrue
    }
}

Describe 'Sync-HybridGuardianCertificates' {
    It 'refuses to export private keys onto a cluster shared volume' {
        $password = ConvertTo-SecureString 'PrivateLabSecret' -AsPlainText -Force
        { & $script:syncScript -Direction Export -Path 'C:\ClusterStorage\Volume1\pfx' -PfxPassword $password -Execute } | Should -Throw '*cluster shared volume*'
    }

    It 'prints a plan without touching the store and never prints the password' {
        $password = ConvertTo-SecureString 'PrivateLabSecret' -AsPlainText -Force
        $output = & $script:syncScript -Direction Export -Path (Join-Path $TestDrive 'pfx') -PfxPassword $password *>&1
        ($output | Out-String) | Should -Not -Match 'PrivateLabSecret'
        @($output)[0].Step | Should -Be 'Export'
    }
}
