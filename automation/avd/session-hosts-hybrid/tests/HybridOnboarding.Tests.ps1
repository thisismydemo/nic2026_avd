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
    $script:scripts = Join-Path $PSScriptRoot '..' 'scripts'

    # Stubs declare the REAL cmdlet parameter lists (Az.ConnectedMachine / Az.DesktopVirtualization / Az.Accounts).
    function global:Resolve-NIC26KeyVaultRef {
        param([string]$Ref, [switch]$AsPlainText)
        if ($Ref -match 'password|secret') {
            return ConvertTo-SecureString -String "private-$Ref" -AsPlainText -Force
        }
        return "private-$Ref"
    }
    function global:Get-AzConnectedMachine { param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$Expand) }
    function global:Get-AzConnectedMachineExtension { param([string]$ResourceGroupName, [string]$MachineName, [string]$Name, [string]$SubscriptionId) }
    function global:Get-AzWvdSessionHost { param([string]$HostPoolName, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$Name) }
    function global:Set-AzContext { param([string]$SubscriptionId) }
    function global:New-AzConnectedMachineExtension {
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$Name, [string]$ResourceGroupName, [string]$MachineName, [string]$Location, [string]$Publisher,
            [string]$ExtensionType, [hashtable]$ProtectedSetting, $Setting, [string]$TypeHandlerVersion,
            [switch]$EnableAutomaticUpgrade, [switch]$AutoUpgradeMinorVersion, [string]$ForceUpdateTag, $Tag,
            [string]$SubscriptionId, [switch]$NoWait, [switch]$AsJob, $DefaultProfile)
    }
    function global:Start-SessionHostSleep { param([int]$Seconds) }

    $script:arcParams = @{
        VmName                = @('vm-one')
        TenantId              = 'tenant'
        SubscriptionId        = 'subscription'
        ArcResourceGroup      = 'arc-group'
        Location              = 'location'
        Tags                  = @{ role = 'hybrid' }
        LocalAdminUsernameRef = 'keyvault://kv-test/username'
        LocalAdminPasswordRef = 'keyvault://kv-test/password'
        OnboardingClientIdRef = 'keyvault://kv-test/client'
        OnboardingSecretRef   = 'keyvault://kv-test/secret'
    }
    $script:registerParams = @{
        SubscriptionId        = 'subscription'
        ArcResourceGroup      = 'arc-group'
        HostPoolResourceGroup = 'pool-group'
        HostPoolName          = 'pool'
        MachineName           = @('vm-one')
        WaitMinutes           = 1
    }
    $script:validationParams = @{
        ExpectedHostName      = @('vm-one')
        SubscriptionId        = 'subscription'
        ArcResourceGroup      = 'arc-group'
        HostPoolResourceGroup = 'pool-group'
        HostPoolName          = 'pool'
    }
}

AfterAll {
    foreach ($name in @('Resolve-NIC26KeyVaultRef', 'Get-AzConnectedMachine', 'Get-AzConnectedMachineExtension',
            'Get-AzWvdSessionHost', 'Set-AzContext', 'New-AzConnectedMachineExtension', 'Start-SessionHostSleep')) {
        Remove-Item "Function:\$name" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name recordedToken, tokenCalls, polls, capturedGuestSecret -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Install-ArcAgent' {
    BeforeAll {
        $script:arcScript = Join-Path $script:scripts 'Install-ArcAgent.ps1'
    }

    It 'plans without resolving secrets or entering a guest' {
        Mock Resolve-NIC26KeyVaultRef { throw 'Unexpected resolution' }
        Mock Invoke-Command { throw 'Unexpected guest call' }
        $row = & $script:arcScript @script:arcParams
        $row.ArcStatus | Should -Be 'Planned'
        Should -Invoke Resolve-NIC26KeyVaultRef -Times 0 -Exactly
        Should -Invoke Invoke-Command -Times 0 -Exactly
    }

    It 'passes the credential and connection arguments and emits no secret' {
        Mock Invoke-Command {
            if (@($ArgumentList).Count -eq 0) { return $true }
            $global:capturedGuestSecret = $ArgumentList[1]
            return [pscustomobject]@{ Status = 'Connected' }
        }
        $stream = & $script:arcScript @script:arcParams -Execute -InformationAction Continue -Verbose *>&1
        @($stream | Where-Object { $_.PSObject.Properties.Name -contains 'ArcStatus' })[0].ArcStatus | Should -Be 'Connected'
        ($stream | Out-String) | Should -Not -Match 'private-'
        Should -Invoke Invoke-Command -Times 2 -Exactly -ParameterFilter { $VMName -eq 'vm-one' -and $Credential -is [pscredential] }
        $global:capturedGuestSecret | Should -Be 'private-keyvault://kv-test/secret'
    }

    It 'goes through the named Hyper-V host when -ComputerName is given' {
        Mock Invoke-Command {
            if ($ComputerName) {
                if ($ArgumentList[3].Count -eq 0) { return $true }
                return [pscustomobject]@{ Status = 'Connected' }
            }
            throw 'PowerShell Direct must not start from this machine'
        }
        $row = @(& $script:arcScript @script:arcParams -ComputerName 'node-one' -Execute)[0]
        $row.ArcStatus | Should -Be 'Connected'
        Should -Invoke Invoke-Command -Times 2 -Exactly -ParameterFilter { $ComputerName -eq 'node-one' -and -not $VMName }
    }

    It 'rethrows a fixed message instead of the guest exception' {
        Mock Invoke-Command { throw 'private-guest-detail' }
        $caught = $null
        try { & $script:arcScript @script:arcParams -Execute } catch { $caught = $_.ToString() }
        $caught | Should -Match 'Hybrid Arc onboarding failed for VM'
        $caught | Should -Not -Match 'private-guest-detail'
    }

    It 'stops before connecting when the guest is not Entra joined' {
        Mock Invoke-Command { return $false }
        { & $script:arcScript @script:arcParams -Execute } | Should -Throw
        Should -Invoke Invoke-Command -Times 1 -Exactly
    }

    It 'rejects tag values with a comma or equals sign' {
        foreach ($value in @('bad,value', 'bad=value')) {
            $parameters = $script:arcParams.Clone()
            $parameters.Tags = @{ role = $value }
            { & $script:arcScript @parameters } | Should -Throw
        }
    }

    It 'stops processing after the first guest failure' {
        $parameters = $script:arcParams.Clone()
        $parameters.VmName = @('vm-one', 'vm-two')
        Mock Invoke-Command { throw 'guest failure' }
        { & $script:arcScript @parameters -Execute } | Should -Throw
        Should -Invoke Invoke-Command -Times 1 -Exactly
    }
}

Describe 'Register-HybridHosts' {
    BeforeAll {
        $script:registerScript = Join-Path $script:scripts 'Register-HybridHosts.ps1'
        $script:tokenPath = Join-Path $TestDrive 'New-AvdRegistrationToken.ps1'
        @'
param($SubscriptionId, $ResourceGroupName, $HostPoolName, $ExpirationHours, [switch]$Execute)
$global:tokenCalls++
[pscustomobject]@{ Token = (ConvertTo-SecureString -String 'private-registration-token' -AsPlainText -Force) }
'@ | Set-Content -LiteralPath $script:tokenPath
        $script:registerParams.TokenScriptPath = $script:tokenPath
    }

    BeforeEach {
        $global:tokenCalls = 0
        $global:recordedToken = $null
        $global:polls = 0
        Mock Set-AzContext {}
        Mock Get-AzConnectedMachine { [pscustomobject]@{ Name = $Name; Location = 'location'; Status = 'Connected' } }
        Mock New-AzConnectedMachineExtension { $global:recordedToken = $ProtectedSetting['registrationToken'] }
        Mock Get-AzConnectedMachineExtension { [pscustomobject]@{ Name = $Name; ProvisioningState = 'Succeeded' } }
        Mock Get-AzWvdSessionHost { [pscustomobject]@{ Name = 'pool/vm-one.example'; Status = 'Available' } }
    }

    It 'plans without requesting a token' {
        (& $script:registerScript @script:registerParams).Status | Should -Be 'Planned'
        $global:tokenCalls | Should -Be 0
        Should -Invoke Get-AzConnectedMachine -Times 0 -Exactly
    }

    It 'passes the token only in the protected setting and emits no token' {
        $stream = & $script:registerScript @script:registerParams -Execute -InformationAction Continue -Verbose *>&1
        @($stream | Where-Object { $_.PSObject.Properties.Name -contains 'Registered' })[0].Registered | Should -BeTrue
        $global:recordedToken | Should -Be 'private-registration-token'
        ($stream | Out-String) | Should -Not -Match 'private-registration-token'
        Should -Invoke New-AzConnectedMachineExtension -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Microsoft.AzureVirtualDesktop.CloudDeviceExtension' -and $MachineName -eq 'vm-one' -and $Location -eq 'location'
        }
    }

    It 'rejects a disconnected machine before requesting a token' {
        Mock Get-AzConnectedMachine { [pscustomobject]@{ Name = $Name; Status = 'Disconnected' } }
        { & $script:registerScript @script:registerParams -Execute } | Should -Throw '*not Connected*'
        $global:tokenCalls | Should -Be 0
    }

    It 'requires the extension to succeed' {
        Mock Get-AzConnectedMachineExtension { [pscustomobject]@{ Name = $Name; ProvisioningState = 'Failed' } }
        { & $script:registerScript @script:registerParams -Execute } | Should -Throw '*did not succeed*'
        Should -Invoke Get-AzWvdSessionHost -Times 0 -Exactly
    }

    It 'caps polling by count and fails when the host never becomes Available' {
        Mock Get-AzWvdSessionHost {
            $global:polls++
            [pscustomobject]@{ Name = 'pool/vm-one.example'; Status = 'Unavailable' }
        }
        { & $script:registerScript @script:registerParams -Execute } | Should -Throw '*did not become Available*'
        $global:polls | Should -Be 12
    }

    It 'stops after the first machine failure' {
        $parameters = $script:registerParams.Clone()
        $parameters.MachineName = @('vm-one', 'vm-two')
        Mock Get-AzConnectedMachineExtension { [pscustomobject]@{ Name = $Name; ProvisioningState = 'Failed' } }
        { & $script:registerScript @parameters -Execute } | Should -Throw
        $global:tokenCalls | Should -Be 1
    }
}

Describe 'Test-HybridHost' {
    BeforeAll {
        $script:testScript = Join-Path $script:scripts 'Test-HybridHost.ps1'
    }

    BeforeEach {
        Mock Set-AzContext {}
        Mock Get-AzConnectedMachine {
            if ($Name) { [pscustomobject]@{ Name = $Name; Status = 'Connected' } }
            else { [pscustomobject]@{ Name = 'vm-one'; Status = 'Connected' } }
        }
        Mock Get-AzConnectedMachineExtension { [pscustomobject]@{ Name = $Name; ProvisioningState = 'Succeeded' } }
        Mock Get-AzWvdSessionHost { [pscustomobject]@{ Name = 'pool/vm-one.example'; Status = 'Available' } }
    }

    It 'returns a healthy row' {
        $row = & $script:testScript @script:validationParams -PassThru
        $row.HostName | Should -Be 'vm-one'
        $row.Problems.Count | Should -Be 0
        $row.SessionHostAvailable | Should -BeTrue
    }

    It 'reports an unexpected Arc machine' {
        Mock Get-AzConnectedMachine {
            if ($Name) { [pscustomobject]@{ Name = $Name; Status = 'Connected' } }
            else {
                [pscustomobject]@{ Name = 'vm-one'; Status = 'Connected' }
                [pscustomobject]@{ Name = 'extra'; Status = 'Connected' }
            }
        }
        $rows = @(& $script:testScript @script:validationParams -PassThru)
        $rows.Count | Should -Be 2
        $rows[1].Problems | Should -Contain 'unexpected machine'
        { & $script:testScript @script:validationParams } | Should -Throw
    }

    It 'throws without -PassThru when an extension fails' {
        Mock Get-AzConnectedMachineExtension { [pscustomobject]@{ Name = $Name; ProvisioningState = 'Failed' } }
        { & $script:testScript @script:validationParams } | Should -Throw
        (& $script:testScript @script:validationParams -PassThru).AmaSucceeded | Should -BeFalse
    }
}

Describe 'Set-HybridVmDhcpData' {
    BeforeAll {
        $script:dhcpScript = Join-Path $script:scripts 'Set-HybridVmDhcpData.ps1'
        $script:outputPath = Join-Path $TestDrive 'reservations.json'
        $script:vm = [pscustomobject]@{
            name        = 'vm-one'
            owner_node  = 'node-one'
            mac_address = '00-15-5D-AA-BB-CC'
            ip_address  = '192.0.2.10'
        }
    }

    It 'normalizes a MAC in plan mode without writing a file' {
        $row = & $script:dhcpScript -Vms @($script:vm) -VlanId 25 -OutputPath $script:outputPath
        $row.mac | Should -Be '00:15:5d:aa:bb:cc'
        Test-Path -LiteralPath $script:outputPath | Should -BeFalse
    }

    It 'rejects duplicate hostnames, MACs and IP addresses' {
        foreach ($field in @('name', 'mac_address', 'ip_address')) {
            $other = [pscustomobject]@{ name = 'vm-two'; owner_node = 'node-one'; mac_address = '00:15:5D:AA:BB:DD'; ip_address = '192.0.2.11' }
            $other.$field = $script:vm.$field
            { & $script:dhcpScript -Vms @($script:vm, $other) -VlanId 25 -OutputPath $script:outputPath } | Should -Throw
        }
    }

    It 'refuses to overwrite without -Force' {
        '{}' | Set-Content -LiteralPath $script:outputPath
        { & $script:dhcpScript -Vms @($script:vm) -VlanId 25 -OutputPath $script:outputPath -Execute } | Should -Throw
        $rows = @(& $script:dhcpScript -Vms @($script:vm) -VlanId 25 -OutputPath $script:outputPath -Execute -Force)
        $rows.Count | Should -Be 1
        @(Get-Content -LiteralPath $script:outputPath -Raw | ConvertFrom-Json)[0].hostname | Should -Be 'vm-one'
    }
}
