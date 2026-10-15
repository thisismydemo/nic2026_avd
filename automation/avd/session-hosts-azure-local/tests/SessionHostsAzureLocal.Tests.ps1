#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Azure Local Arc Entra join required settings' {
    It 'explicitly supplies empty mdmId in both provider extension blocks' -ForEach @(
        @{ RelativePath = 'bicep/modules/host.bicep'; Pattern = "(?s)resource entra .*?settings:\s*\{\s*mdmId:\s*''\s*\}" }
        @{ RelativePath = 'terraform/main.tf'; Pattern = '(?s)resource "azapi_resource" "entra".*?settings\s*=\s*\{\s*mdmId\s*=\s*""\s*\}' }
    ) {
        $source = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) $RelativePath) -Raw
        $source | Should -Match $Pattern
        ($source -replace 'mdmId\s*[:=]\s*(?:""|\x27\x27)', '') | Should -Not -Match $Pattern
    }
}

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:register = Join-Path $script:root 'scripts/Register-AvdSessionHostsAzureLocal.ps1'
    $script:tokenFile = Join-Path $TestDrive 'Get-TestToken.ps1'
    Set-Content -LiteralPath $script:tokenFile -Value @'
param($SubscriptionId, $ResourceGroupName, $HostPoolName, $ExpirationHours, [switch]$Execute)
$global:AzureLocalFake.TokenCalls++
[pscustomobject]@{ Token = (ConvertTo-SecureString -String $global:AzureLocalFake.FakeToken -AsPlainText -Force) }
'@

    # Stubs declare the REAL cmdlet parameter lists (Az.ConnectedMachine): a wrong parameter name fails binding.
    function global:Set-AzContext { param($SubscriptionId, $Tenant) }
    function global:Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000000' }; Subscription = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000000' } } }   # the CI runner has no Azure login
    function global:Get-AzConnectedMachine {
        param($Name, $ResourceGroupName, $SubscriptionId, [string]$Expand)
        [pscustomobject]@{ Location = 'test-location'; Status = $global:AzureLocalFake.Connection; OSName = 'Windows 11' }
    }
    function global:New-AzConnectedMachineRunCommand {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Stub mirrors the real cmdlet signature.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($MachineName, $ResourceGroupName, $RunCommandName, $Location, $SourceScript, $Parameter,
            $ProtectedParameter, $TimeoutInSecond, [switch]$AsyncExecution, $RunAsUser, [securestring]$RunAsPassword)
        $global:AzureLocalFake.Created++
        $global:AzureLocalFake.ProtectedName = $ProtectedParameter[0].Name
        $global:AzureLocalFake.ProtectedValueMatched = $ProtectedParameter[0].Value -ceq $global:AzureLocalFake.FakeToken
    }
    function global:Get-AzConnectedMachineRunCommand {
        param($MachineName, $ResourceGroupName, $RunCommandName, $SubscriptionId, [string]$Expand)
        [pscustomobject]@{
            InstanceViewExecutionState = $global:AzureLocalFake.ExecutionState
            InstanceViewExitCode       = $global:AzureLocalFake.ExitCode
            InstanceViewOutput         = $global:AzureLocalFake.FakeToken
            InstanceViewError          = $global:AzureLocalFake.FakeToken
            ProvisioningState          = 'Succeeded'
        }
    }
    function global:Remove-AzConnectedMachineRunCommand {
        [CmdletBinding(SupportsShouldProcess)]
        param($MachineName, $ResourceGroupName, $RunCommandName, $SubscriptionId, [switch]$PassThru)
        $global:AzureLocalFake.Removed++
    }
    function global:Get-AzWvdSessionHost {
        param($HostPoolName, $ResourceGroupName, $SubscriptionId, $Name)
        [pscustomobject]@{ Name = "$HostPoolName/host1.example.test"; Status = $global:AzureLocalFake.HostStatus }
    }
    function global:Start-SessionHostSleep { param([int]$Seconds) }
}


AfterAll {
    foreach ($name in @('Set-AzContext', 'Get-AzContext', 'Get-AzConnectedMachine', 'New-AzConnectedMachineRunCommand',
            'Get-AzConnectedMachineRunCommand', 'Remove-AzConnectedMachineRunCommand',
            'Get-AzWvdSessionHost', 'Start-SessionHostSleep')) {
        Remove-Item "Function:\global:$name" -ErrorAction SilentlyContinue
    }
    Remove-Variable AzureLocalFake -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Manifest and infrastructure contracts' {
    It 'declares catalog keys and the logical secret' {
        $manifest = Get-Content (Join-Path $script:root 'solution.yml') -Raw
        foreach ($key in 'vm_azl_1', 'cn_azl_1', 'nic_azl_1', 'vm_azl_2', 'cn_azl_2', 'nic_azl_2',
            'dcr_assoc', 'deployment_name', 'avd-sessionhost-local-admin') {
            $manifest | Should -Match ([regex]::Escape($key))
        }
    }

    It 'uses the verified resource APIs and carries no registration-token input' {
        $bicep = Get-Content (Join-Path $script:root 'bicep/main.bicep') -Raw
        $hostFile = Get-Content (Join-Path $script:root 'bicep/modules/host.bicep') -Raw
        $tf = Get-Content (Join-Path $script:root 'terraform/main.tf') -Raw
        $tfVars = Get-Content (Join-Path $script:root 'terraform/variables.tf') -Raw
        foreach ($resource in @(
                'Microsoft.HybridCompute/machines@2025-01-13',
                'Microsoft.AzureStackHCI/networkInterfaces@2026-04-01-preview',
                'Microsoft.AzureStackHCI/virtualMachineInstances@2026-04-01-preview')) {
            $hostFile | Should -Match ([regex]::Escape($resource))
            $tf | Should -Match ([regex]::Escape($resource))
        }
        $bicep | Should -Match 'range\(0, host_count\)'
        # The cluster accepts only 2025-09-01-preview, 2026-02-01-preview or 2026-04-01-preview for VM management.
        foreach ($text in @($hostFile, $tf)) {
            $text | Should -Not -Match 'Microsoft\.AzureStackHCI/\w+@(?!2025-09-01-preview|2026-02-01-preview|2026-04-01-preview)'
        }
        # D-050: AD join through JsonADDomainExtension with the password only in protected settings; explicit storage path.
        foreach ($text in @($hostFile, $tf)) {
            $text | Should -Match 'JsonADDomainExtension'
            $text | Should -Match 'vmConfigStoragePathId'
        }
        $hostFile | Should -Match '(?s)protectedSettings:\s*\{\s*Password: domainJoinPassword'
        $hostFile | Should -Match '(?s)@secure\(\)\s*param domainJoinPassword'
        foreach ($text in @($bicep, $hostFile, $tf, $tfVars)) {
        }
        foreach ($text in @($bicep, $hostFile)) {
            $text | Should -Not -Match '(?i)param\s+\w*(registration|(?<!naming_)token)'
            $text | Should -Not -Match '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        }
        $tfVars | Should -Not -Match '(?i)variable\s+"?\w*(registration|(?<!naming_)token)'
        $tf | Should -Not -Match '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    }
}

Describe 'Arc registration' {
    BeforeEach {
        $global:AzureLocalFake = @{
            FakeToken             = 'FAKE-REGISTRATION-SECRET-DO-NOT-PRINT'
            TokenCalls            = 0
            Created               = 0
            Removed               = 0
            Connection            = 'Connected'
            ExecutionState        = 'Succeeded'
            ExitCode              = 0
            HostStatus            = 'Available'
            ProtectedName         = ''
            ProtectedValueMatched = $false
        }
        $script:parameters = @{
            SubscriptionId        = '00000000-0000-0000-0000-000000000000'
            ResourceGroupName     = 'test-machines'
            HostPoolResourceGroup = 'test-pool-rg'
            HostPoolName          = 'test-pool'
            MachineName           = @('host1')
            TokenScriptPath       = $script:tokenFile
        }
    }
    It 'plans without requesting a token or creating a command' {
        $result = & $script:register @script:parameters
        $result.Status | Should -Be 'Planned'
        $global:AzureLocalFake.TokenCalls | Should -Be 0
        $global:AzureLocalFake.Created | Should -Be 0
    }

    It 'passes only the protected token and prints it in no stream' {
        $streams = & $script:register @script:parameters -Execute -InformationAction Continue -Verbose *>&1
        $global:AzureLocalFake.ProtectedName | Should -Be 'RegistrationToken'
        $global:AzureLocalFake.ProtectedValueMatched | Should -BeTrue
        $global:AzureLocalFake.Removed | Should -Be 1
        ($streams | Out-String) | Should -Not -Match ([regex]::Escape($global:AzureLocalFake.FakeToken))
        @($streams | Where-Object { $_.PSObject.Properties.Name -contains 'MachineName' })[0].Status | Should -Be 'Available'
    }

    It 'removes a failed run command and stops before the next machine' {
        $global:AzureLocalFake.ExecutionState = 'Failed'
        $script:parameters.MachineName = @('host1', 'host2')
        { & $script:register @script:parameters -Execute } | Should -Throw '*run command failed*'
        $global:AzureLocalFake.Created | Should -Be 1
        $global:AzureLocalFake.Removed | Should -Be 1
    }

    It 'rejects a disconnected machine before creating a command' {
        $global:AzureLocalFake.Connection = 'Disconnected'
        { & $script:register @script:parameters -Execute } | Should -Throw '*not Connected*'
        $global:AzureLocalFake.Created | Should -Be 0
        $global:AzureLocalFake.TokenCalls | Should -Be 0
    }

    It 'rejects a non-zero exit code and still removes the command' {
        $global:AzureLocalFake.ExitCode = 1
        { & $script:register @script:parameters -Execute } | Should -Throw '*run command failed*'
        $global:AzureLocalFake.Removed | Should -Be 1
    }

    It 'accepts MSI exit code 3010' {
        $global:AzureLocalFake.ExitCode = 3010
        $row = @(& $script:register @script:parameters -Execute)[0]
        $row.Registered | Should -BeTrue
    }

    It 'fails if the registered host never becomes Available' {
        $global:AzureLocalFake.HostStatus = 'Unavailable'
        { & $script:register @script:parameters -Execute -WaitMinutes 1 } | Should -Throw '*did not become Available*'
        $global:AzureLocalFake.Removed | Should -Be 1
    }
}

Describe 'GPU demo workload (a4b option B)' {
    BeforeAll {
        $script:gpuDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
        $script:gpuInstall = Get-Content (Join-Path $script:gpuDir 'Install-GpuDemoWorkload.ps1') -Raw
        $script:gpuInvoke = Get-Content (Join-Path $script:gpuDir 'Invoke-GpuDemoWorkload.ps1') -Raw
    }
    It 'parses, holds no environment values and never touches the NVIDIA driver' {
        foreach ($f in 'Install-GpuDemoWorkload.ps1', 'Invoke-GpuDemoWorkload.ps1') {
            $errs = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:gpuDir $f), [ref]$null, [ref]$errs)
            $errs | Should -BeNullOrEmpty
        }
        foreach ($t in $script:gpuInstall, $script:gpuInvoke) {
            $t | Should -Not -Match '\b(10|172|192)\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            $t | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        }
        $script:gpuInstall | Should -Not -Match 'pnputil|-f?dm 0|\.inf\b'
        $script:gpuInstall | Should -Match 'Python Software Foundation'
    }
    It 'drains the host for the change and restores AllowNewSession, gated behind -Execute' {
        $body = ($script:gpuInvoke -split '\$doInstall = ')[1]
        $body.IndexOf('-not $Execute') | Should -BeLessThan $body.IndexOf('Set-Drain $false')
        $script:gpuInvoke | Should -Match 'finally \{ if \(\$before\) \{ Set-Drain \$true \} \}'
    }
}
