#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:registerScript = Join-Path $script:root 'scripts/Register-AvdSessionHosts.ps1'
}

Describe 'Session-host infrastructure' {
    It 'declares catalog names and the local administrator secret' {
        $manifest = Get-Content (Join-Path $script:root 'solution.yml') -Raw
        foreach ($key in @('vm_azure_1', 'vm_azure_2', 'cn_azure_1', 'cn_azure_2',
                'nic_azure_1', 'nic_azure_2', 'osdisk_azure_1', 'osdisk_azure_2',
                'avd-sessionhost-local-admin')) {
            $manifest | Should -Match ([regex]::Escape($key))
        }
    }

    It 'keeps registration credentials out of both IaC implementations' {
        $bicepPath = Join-Path $script:root 'bicep/main.bicep'
        $tfPath = Join-Path $script:root 'terraform/main.tf'
        $tfVarsPath = Join-Path $script:root 'terraform/variables.tf'
        Test-Path $bicepPath | Should -BeTrue
        Test-Path $tfPath | Should -BeTrue
        $bicep = Get-Content $bicepPath -Raw
        $tf = Get-Content $tfPath -Raw
        $tfVars = Get-Content $tfVarsPath -Raw
        foreach ($text in @($bicep, $tf, $tfVars)) {
            $text | Should -Not -Match '(?i)param\s+\w*(registration|(?<!lab_)token)'
            $text | Should -Not -Match '(?i)variable\s+"?\w*(registration|(?<!lab_)token)'
        }
        foreach ($text in @($bicep, $tf)) {
            $text | Should -Not -Match '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        }
        $bicep | Should -Match 'avm/res/compute/virtual-machine'
        $bicep | Should -Match "securityType: 'TrustedLaunch'"
        $bicep | Should -Not -Match 'pipConfiguration'
        $tf | Should -Not -Match 'public_ip'
    }
}

Describe 'Session-host registration' {
    BeforeAll {
        function global:Set-AzContext { param($SubscriptionId) }
        function global:Get-AzVM {
            param($ResourceGroupName, $Name, [switch]$Status)
            # Mirrors the real shapes: the model has Location/OSProfile; -Status returns the instance view (no Location, no OSProfile).
            if ($Status) {
                [pscustomobject]@{ Name = $Name; ComputerName = $Name; Statuses = @([pscustomobject]@{ Code = 'PowerState/running' }) }
            }
            else {
                [pscustomobject]@{ Name = $Name; Location = 'example-region'; OSProfile = [pscustomobject]@{ ComputerName = $Name } }
            }
        }
        function global:Set-AzVMRunCommand {
            param($ResourceGroupName, $VMName, $RunCommandName, $Location,
                $SourceScript, $ProtectedParameter, $Parameter, $TimeoutInSecond)
        }
        function global:Get-AzVMRunCommand {
            param($ResourceGroupName, $VMName, $RunCommandName, $Expand)
            [pscustomobject]@{ InstanceView = [pscustomobject]@{ ExecutionState = 'Succeeded'; ExitCode = 0 } }
        }
        function global:Remove-AzVMRunCommand {
            [CmdletBinding(SupportsShouldProcess)]
            param($ResourceGroupName, $VMName, $RunCommandName, [switch]$PassThru)
        }
        function global:Get-AzWvdSessionHost {
            param($ResourceGroupName, $HostPoolName)
            [pscustomobject]@{ Name = "$HostPoolName/testvm.example.invalid"; Status = 'Available' }
        }
        function global:Restart-AzVM { [CmdletBinding(SupportsShouldProcess)] param($ResourceGroupName, $Name) }
        function global:Start-SessionHostSleep { param($Seconds) }

        $script:tokenPath = Join-Path $TestDrive 'FakeToken.ps1'
        @'
param($SubscriptionId, $ResourceGroupName, $HostPoolName, $ExpirationHours, [switch]$Execute)
$global:Nic26TokenCalls++
[pscustomobject]@{ Token = (ConvertTo-SecureString 'fake-token-for-test' -AsPlainText -Force) }
'@ | Set-Content $script:tokenPath
        $script:baseArguments = @{
            SubscriptionId        = 'example-subscription'
            ResourceGroupName     = 'example-vm-rg'
            HostPoolResourceGroup = 'example-pool-rg'
            HostPoolName          = 'example-pool'
            VmName                = @('testvm')
            TokenScriptPath       = $script:tokenPath
        }
    }

    BeforeEach {
        $global:Nic26TokenCalls = 0
        $global:Nic26ProtectedName = $null
        $global:Nic26ProtectedValue = $null
        Mock Set-AzVMRunCommand {
            $global:Nic26ProtectedName = $ProtectedParameter[0].Name
            $global:Nic26ProtectedValue = $ProtectedParameter[0].Value
        }
        Mock Remove-AzVMRunCommand {}
        Mock Restart-AzVM {}
        Mock Get-AzWvdSessionHost { [pscustomobject]@{ Name = 'example-pool/testvm.example.invalid'; Status = 'Available' } }
    }

    AfterAll {
        foreach ($name in @('Set-AzContext', 'Get-AzVM', 'Set-AzVMRunCommand',
                'Get-AzVMRunCommand', 'Remove-AzVMRunCommand',
                'Get-AzWvdSessionHost', 'Restart-AzVM', 'Start-SessionHostSleep')) {
            Remove-Item "Function:global:$name" -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name Nic26TokenCalls, Nic26ProtectedName, Nic26ProtectedValue -Scope Global -ErrorAction SilentlyContinue
    }

    It 'does not request a token or create a Run Command without Execute' {
        $rows = @(& $script:registerScript @script:baseArguments)
        $rows[0].Status | Should -Be 'Planned'
        Should -Invoke Set-AzVMRunCommand -Times 0 -Exactly
        $global:Nic26TokenCalls | Should -Be 0
    }

    It 'uses a protected parameter, hides the token, and removes the command' {
        $captured = & $script:registerScript @script:baseArguments -Execute -InformationAction Continue -Verbose *>&1
        $global:Nic26ProtectedName | Should -Be 'RegistrationToken'
        $global:Nic26ProtectedValue | Should -Be 'fake-token-for-test'
        ($captured | Out-String) | Should -Not -Match 'fake-token-for-test'
        Should -Invoke Set-AzVMRunCommand -Times 1 -Exactly
        Should -Invoke Remove-AzVMRunCommand -Times 1 -Exactly
    }

    It 'removes the command and stops on the first failed VM' {
        Mock Get-AzVMRunCommand {
            [pscustomobject]@{ InstanceView = [pscustomobject]@{ ExecutionState = 'Failed'; ExitCode = 1 } }
        }
        $arguments = $script:baseArguments.Clone()
        $arguments.VmName = @('testvm', 'secondvm')
        { & $script:registerScript @arguments -Execute } | Should -Throw
        Should -Invoke Set-AzVMRunCommand -Times 1 -Exactly
        Should -Invoke Remove-AzVMRunCommand -Times 1 -Exactly
    }

    It 'fails if the session host never becomes Available' {
        Mock Get-AzWvdSessionHost { @() }
        { & $script:registerScript @script:baseArguments -WaitMinutes 1 -Execute } | Should -Throw '*did not become Available*'
    }

    It 'restarts only after Available' {
        & $script:registerScript @script:baseArguments -RestartWhenAvailable -Execute | Out-Null
        Should -Invoke Get-AzWvdSessionHost -Times 2 -Exactly
        Should -Invoke Restart-AzVM -Times 1 -Exactly

        Mock Get-AzWvdSessionHost { @() }
        { & $script:registerScript @script:baseArguments -RestartWhenAvailable -WaitMinutes 1 -Execute } | Should -Throw
        Should -Invoke Restart-AzVM -Times 1 -Exactly
    }
}
