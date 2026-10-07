#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
<#
.SYNOPSIS
    Pester 5 tests for automation/demo/avd: Switch-UserHostPool (WhatIf default, reversible, idempotent),
    Stop/Restore-SessionHost (preflight, -Execute, hybrid message), Show-AvdState hygiene, Test-ProfilePortability and
    Test-AvdDemoSmoke with mocked wrappers. No Azure, no Graph, no device.
.DESCRIPTION
    Run from the repo root:
        Import-Module Pester -RequiredVersion 5.9.1
        Invoke-Pester -Path automation\demo\avd\tests -Output Detailed
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mock bodies invoked from another script file resolve $script: to that file (dynamic scoping); one global hashtable carries the mock state and is removed in AfterAll.')]
param()

BeforeAll {
    $global:NIC26Test = @{}
    $script:ScriptsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' 'scripts')).Path
    Import-Module (Join-Path $script:ScriptsRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1') -Force
    $env:NIC26_DEMO_STATE_DIR = Join-Path $TestDrive 'state'
    $env:NIC26_ASSUME_PLATFORM = 'Windows'
    $env:NIC26_ASSUME_TRANSCRIPT = $null
    $script:RefPrefix = 'acmecorp-'
    $global:NIC26Test.RefPrefix = $script:RefPrefix

    $global:NIC26Test.Config = @{
        org = 'iic'; token = 'nic26'; location_short = 'eus'; location = 'eastus'
        tenant_domain = 'contoso.com'; tenant_id = '00000000-0000-0000-0000-000000000000'
        subscriptions = @{ avd = '00000000-0000-0000-0000-000000000000' }
        owner_email = 'lab-owner@contoso.com'; screen_hidden_terms = @('acmecorp')
        log_analytics_workspace_id = ''
        entra_groups = @{ avd_azure = 'grp-iic-nic26-avd-azure'; avd_azl = 'grp-iic-nic26-avd-azl'; avd_hybrid = 'grp-iic-nic26-avd-hybrid' }
        demo_users = @(@{ upn = 'user1@contoso.com'; display_name = 'User 1'; realm = 'azure' }, @{ upn = 'user2@contoso.com'; display_name = 'User 2'; realm = 'azl' })
        host_pools = @{ azure = @{ friendly_name = 'Asgard' }; azl = @{ friendly_name = 'Midgard' }; hybrid = @{ friendly_name = 'Outer realms' } }
        share_names = @{ profiles = 'nic26-fslogix-profiles'; odfc = 'nic26-fslogix-odfc' }
        hybrid = @{ vms = @(@{ name = 'nic26-avd-hv01'; owner_node = 'nic26-01-n01' }, @{ name = 'nic26-avd-hv02'; owner_node = 'nic26-01-n02' }) }
    }
    function New-HostList {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure object factory; changes no state.')]
        param([string]$Prefix, [string]$FailedHost = '')
        @(1, 2) | ForEach-Object {
            $n = '{0}{1:00}' -f $Prefix, $_
            [pscustomobject]@{ Name = $n; FullName = "$n.contoso.com"; Status = $(if ($n -eq $FailedHost) { 'Unavailable' } else { 'Available' }); Sessions = 0; AllowNewSession = $true; LastHeartBeat = (Get-Date); ResourceId = "/x/$n"; AgentVersion = '1.0' }
        }
    }
    function Clear-Locks { Get-ChildItem -LiteralPath (Get-DemoStateRoot) -Filter '*.json' -File -ErrorAction SilentlyContinue | Remove-Item -Force }
    function Invoke-CaptureAll {
        param([scriptblock]$Script)
        $lines = & $Script *>&1 | ForEach-Object { if ($_ -is [string]) { $_ } else { $_ | Out-String } }
        return ($lines -join "`n")
    }
    function Initialize-DemoTestDefault {
        Clear-Locks
        Mock Get-DemoConfig { $global:NIC26Test.Config }
        Mock Start-DemoSleep {}
    }
}

AfterAll {
    Remove-Variable -Name NIC26Test -Scope Global -ErrorAction SilentlyContinue
    $env:NIC26_DEMO_STATE_DIR = $null
    $env:NIC26_ASSUME_PLATFORM = $null
}

Describe 'Switch-UserHostPool.ps1' {
    BeforeAll { $script:Switch = Join-Path $script:ScriptsRoot 'Switch-UserHostPool.ps1' }
    BeforeEach {
        . Initialize-DemoTestDefault
        $global:NIC26Test.Members = @{ 'g-azure' = [System.Collections.Generic.List[string]]@('u-user1'); 'g-azl' = [System.Collections.Generic.List[string]]@(); 'g-hybrid' = [System.Collections.Generic.List[string]]@() }
        Mock Get-DemoUserId { 'u-user1' }
        Mock Get-DemoGroupId { 'g-' + ($DisplayName -replace '^grp-iic-nic26-avd-', '') }
        Mock Get-DemoGroupMemberIdList { [string[]]$global:NIC26Test.Members[$GroupId] }
        Mock Add-DemoGroupMember { $global:NIC26Test.Members[$GroupId].Add($UserId) }
        Mock Remove-DemoGroupMember { $null = $global:NIC26Test.Members[$GroupId].Remove($UserId) }
    }
    It 'WhatIf is the default: prints the UNDO (previous realm) first and changes nothing' {
        $out = Invoke-CaptureAll { $script:R = & $script:Switch -UserPrincipalName user1@contoso.com -TargetRealm azl -PassThru }
        $out | Should -Match '-TargetRealm azure -Mode Group -Execute'
        $out.IndexOf('UNDO') | Should -BeLessThan $out.IndexOf('PLAN')
        Should -Invoke Add-DemoGroupMember -Times 0
        Should -Invoke Remove-DemoGroupMember -Times 0
        $script:R.PreviousRealms | Should -Be @('azure')
        $script:R.Changed | Should -BeFalse
    }
    It '-Execute moves the user azure -> azl, the UNDO moves it back, and a repeat is a no-op (reversible, idempotent)' {
        $r = & $script:Switch -UserPrincipalName user1@contoso.com -TargetRealm azl -Execute -PassThru 6>$null
        $r.Changed | Should -BeTrue
        $global:NIC26Test.Members['g-azl'] | Should -Contain 'u-user1'
        $global:NIC26Test.Members['g-azure'] | Should -Not -Contain 'u-user1'
        $r2 = & $script:Switch -UserPrincipalName user1@contoso.com -TargetRealm azure -Execute -PassThru 6>$null
        $r2.PreviousRealms | Should -Be @('azl')
        $global:NIC26Test.Members['g-azure'] | Should -Contain 'u-user1'
        $global:NIC26Test.Members['g-azl'] | Should -Not -Contain 'u-user1'
        $r3 = & $script:Switch -UserPrincipalName user1@contoso.com -TargetRealm azure -Execute -PassThru 6>$null
        $r3.Changed | Should -BeFalse
        Should -Invoke Add-DemoGroupMember -Times 2
        Should -Invoke Remove-DemoGroupMember -Times 2
    }
    It 'cleans up a user that is in two realms at once' {
        $global:NIC26Test.Members['g-hybrid'].Add('u-user1')
        $r = & $script:Switch -UserPrincipalName user1@contoso.com -TargetRealm hybrid -Execute -PassThru 6>$null
        $r.Removed | Should -Be @('azure')
        $r.Added.Count | Should -Be 0
    }
    It 'adds to the new realm BEFORE removing from the old one, so a failed add leaves the old route' {
        Mock Add-DemoGroupMember { throw 'Graph throttled' }
        { & $script:Switch -UserPrincipalName user1@contoso.com -TargetRealm hybrid -Execute 6>$null } | Should -Throw '*Graph throttled*'
        Should -Invoke Remove-DemoGroupMember -Times 0
        $global:NIC26Test.Members['g-azure'].Count | Should -Be 1
    }
    It '-RemoveOnly takes the user out of every realm' {
        $r = & $script:Switch -UserPrincipalName user1@contoso.com -RemoveOnly -Execute -PassThru 6>$null
        $r.Removed | Should -Be @('azure')
        $global:NIC26Test.Members['g-azure'].Count | Should -Be 0
    }
    It 'Direct mode uses the app-group role assignments' {
        $global:NIC26Test.Direct = @{ 'vdag-iic-nic26-azure-eus-01' = @('user1@contoso.com') }
        Mock Get-DemoAppGroupAssignmentList { [string[]]@($global:NIC26Test.Direct[$AppGroupName]) }
        Mock Add-DemoAppGroupAssignment { $global:NIC26Test.Direct[$AppGroupName] = @($UserPrincipalName) }
        Mock Remove-DemoAppGroupAssignment { $global:NIC26Test.Direct[$AppGroupName] = @() }
        $r = & $script:Switch -UserPrincipalName user1@contoso.com -TargetRealm hybrid -Mode Direct -Execute -PassThru 6>$null
        $r.PreviousRealms | Should -Be @('azure')
        Should -Invoke Add-DemoAppGroupAssignment -Times 1 -ParameterFilter { $AppGroupName -eq 'vdag-iic-nic26-hybrid-eus-01' }
        Should -Invoke Remove-DemoAppGroupAssignment -Times 1 -ParameterFilter { $AppGroupName -eq 'vdag-iic-nic26-azure-eus-01' }
    }
}

Describe 'Stop-SessionHost / Restore-SessionHost' {
    BeforeAll {
        $script:Stop = Join-Path $script:ScriptsRoot 'Stop-SessionHost.ps1'
        $script:Restore = Join-Path $script:ScriptsRoot 'Restore-SessionHost.ps1'
    }
    BeforeEach {
        . Initialize-DemoTestDefault
        $global:NIC26Test.Failed = ''
        Mock Get-DemoSessionHostList {
            $prefix = switch -Wildcard ($HostPoolName) { '*-hybrid-*' { 'nic26-avd-hv' } '*-azl-*' { 'nic26-avd-al' } default { 'nic26-avd-az' } }
            New-HostList -Prefix $prefix -FailedHost $global:NIC26Test.Failed
        }
        Mock Stop-DemoHyperVVM { $global:NIC26Test.Failed = $Name }
        Mock Stop-DemoAzureVM { $global:NIC26Test.Failed = 'nic26-avd-az' + ($Name -replace '^.*-(\d+)$', '$1') }   # VM resource name -> session-host name
        Mock Stop-DemoArcVM { $global:NIC26Test.Failed = 'nic26-avd-al' + ($Name -replace '^.*-(\d+)$', '$1') }
        Mock Start-DemoClusterGroup { $global:NIC26Test.Failed = '' }
        Mock Start-DemoAzureVM { $global:NIC26Test.Failed = '' }
        Mock Start-DemoArcVM { $global:NIC26Test.Failed = '' }
        Mock Get-DemoClusterGroupState { [pscustomobject]@{ Name = $Name; State = 'Offline'; OwnerNode = 'nic26-01-n01'; VMState = 'Off' } }
    }
    It 'WhatIf is the default: UNDO printed first, nothing stopped, no lock' {
        $out = Invoke-CaptureAll { & $script:Stop -Realm hybrid -HostName nic26-avd-hv01 }
        $out | Should -Match 'Restore-SessionHost.ps1 -Realm hybrid -HostName nic26-avd-hv01 -Execute'
        $out | Should -Match 'AVD does NOT restart this VM'
        Should -Invoke Stop-DemoHyperVVM -Times 0
        @(Get-DemoFaultLock).Count | Should -Be 0
    }
    It 'hybrid -Execute hard-powers the VM on its owner node, records the lock, waits for Unavailable; a second stop refuses' {
        $plan = & $script:Stop -Realm hybrid -HostName nic26-avd-hv01 -Execute -PassThru 6>$null
        $plan.Executed | Should -BeTrue
        Should -Invoke Stop-DemoHyperVVM -Times 1 -ParameterFilter { $ComputerName -eq 'nic26-01-n01' -and $Name -eq 'nic26-avd-hv01' }
        (Get-DemoFaultLock -Scope avd)[0].Detail.Realm | Should -Be 'hybrid'
        { & $script:Stop -Realm hybrid -HostName nic26-avd-hv02 -Execute 6>$null } | Should -Throw '*REFUSED*'
    }
    It 'writes the fault lock BEFORE the host is stopped' {
        Mock Stop-DemoHyperVVM { $global:NIC26Test.LockAtStop = @(Get-DemoFaultLock -Scope avd).Count; $global:NIC26Test.Failed = $Name }
        $null = & $script:Stop -Realm hybrid -HostName nic26-avd-hv01 -Execute 6>$null
        $global:NIC26Test.LockAtStop | Should -Be 1
    }
    It 'KEEPS the lock and names the Restore when the stop throws (outcome unknown)' {
        Mock Stop-DemoHyperVVM { throw 'remoting dropped after the command was sent' }
        { & $script:Stop -Realm hybrid -HostName nic26-avd-hv01 -Execute 6>$null } | Should -Throw '*outcome for nic26-avd-hv01 is unknown*'
        @(Get-DemoFaultLock -Scope avd).Count | Should -Be 1
    }
    It 'refuses when no second host is Available' {
        $global:NIC26Test.Failed = 'nic26-avd-hv02'
        { & $script:Stop -Realm hybrid -HostName nic26-avd-hv01 -Execute 6>$null } | Should -Throw '*REFUSED*'
        Should -Invoke Stop-DemoHyperVVM -Times 0
    }
    It 'azure and azl realms use the platform stop paths' {
        $null = & $script:Stop -Realm azure -HostName nic26-avd-az01 -Execute 6>$null
        Should -Invoke Stop-DemoAzureVM -Times 1 -ParameterFilter { $ResourceGroupName -eq 'rg-iic-nic26-avd-hosts-eus-01' -and $Name -eq 'vm-iic-nic26-avd-az-eus-01' }
        Clear-Locks; $global:NIC26Test.Failed = ''
        $null = & $script:Stop -Realm azl -HostName nic26-avd-al01 -Execute 6>$null
        Should -Invoke Stop-DemoArcVM -Times 1 -ParameterFilter { $ResourceGroupName -eq 'rg-iic-nic26-azl-eus-01' -and $Name -eq 'vm-iic-nic26-avd-azl-01' }
    }
    It 'Restore (hybrid) starts the clustered role, tells the presenter AVD did not restart it, waits for Available and clears the lock' {
        $null = & $script:Stop -Realm hybrid -HostName nic26-avd-hv01 -Execute 6>$null
        $out = Invoke-CaptureAll { $script:R = & $script:Restore -Execute -PassThru }
        $script:R.Restored | Should -BeTrue
        $out | Should -Match 'AVD did NOT restart this VM'
        $out | Should -Match 'Start-ClusterGroup'
        Should -Invoke Start-DemoClusterGroup -Times 1 -ParameterFilter { $Name -eq 'nic26-avd-hv01' }
        @(Get-DemoFaultLock).Count | Should -Be 0
    }
    It 'Restore: WhatIf default and nothing-to-restore paths' {
        (& $script:Restore -Execute -PassThru 6>$null).Restored | Should -BeFalse
        $null = & $script:Stop -Realm azure -HostName nic26-avd-az02 -Execute 6>$null
        (& $script:Restore -PassThru 6>$null).Reason | Should -Be 'whatif'
        Should -Invoke Start-DemoAzureVM -Times 0
        (& $script:Restore -Execute -PassThru 6>$null).Restored | Should -BeTrue
        Should -Invoke Start-DemoAzureVM -Times 1 -ParameterFilter { $Name -eq 'vm-iic-nic26-avd-az-eus-02' }
    }
}

Describe 'Show-AvdState / Test-ProfilePortability / Test-AvdDemoSmoke' {
    BeforeEach {
        . Initialize-DemoTestDefault
        Mock Get-DemoWorkspace { [pscustomobject]@{ Name = $Name; FriendlyName = 'IIC'; AppGroupCount = 3 } }
        Mock Get-DemoHostPool { [pscustomobject]@{ Name = $Name; Type = 'Pooled'; LoadBalancerType = 'BreadthFirst'; MaxSessionLimit = 4; FriendlyName = 'x' } }
        Mock Get-DemoSessionHostList { New-HostList -Prefix $(if ($HostPoolName -like '*hybrid*') { 'nic26-avd-hv' } else { 'nic26-avd-az' }) }
        Mock Get-DemoUserSessionList { if ($HostPoolName -like '*hybrid*') { @([pscustomobject]@{ UserPrincipalName = "user1@$($global:NIC26Test.RefPrefix)real.example"; SessionHost = 'nic26-avd-hv01'; SessionState = 'Active'; HostPool = $HostPoolName }) } else { @() } }
    }
    It 'Show-AvdState prints three pools through the hygiene filter' {
        $out = Invoke-CaptureAll { & (Join-Path $script:ScriptsRoot 'Show-AvdState.ps1') -PassThru | Out-Null }
        $out | Should -Match 'vdpool-iic-nic26-azure-eus-01'
        $out | Should -Match 'vdpool-iic-nic26-hybrid-eus-01'
        $out | Should -Not -Match ([regex]::Escape($script:RefPrefix))
        $out | Should -Match 'contoso.com|\[hidden\]'
    }
    It 'Test-ProfilePortability lists container metadata and sessions, never file contents' {
        Mock Get-DemoFileShareItemList {
            if (-not $Path) { return @([pscustomobject]@{ Name = 'S-1-5-21-1_user1'; IsDirectory = $true; Length = $null; LastModified = $null }) }
            return @([pscustomobject]@{ Name = 'Profile_user1.VHDX'; IsDirectory = $false; Length = 3GB; LastModified = (Get-Date) })
        }
        Mock Get-DemoFileHandleList { @() }
        # the script keeps only the sessions of the user it is asked about, so this user's session must carry that exact UPN
        Mock Get-DemoUserSessionList { if ($HostPoolName -like '*hybrid*') { @([pscustomobject]@{ UserPrincipalName = 'user1@contoso.com'; SessionHost = 'nic26-avd-hv01'; SessionState = 'Active'; HostPool = $HostPoolName }, [pscustomobject]@{ UserPrincipalName = 'user2@contoso.com'; SessionHost = 'nic26-avd-hv02'; SessionState = 'Active'; HostPool = $HostPoolName }) } else { @() } }
        $r = & (Join-Path $script:ScriptsRoot 'Test-ProfilePortability.ps1') -UserPrincipalName user1@contoso.com -SkipInsights -PassThru 6>$null
        $r.Containers.Count | Should -Be 2
        $r.Containers[0].SizeGB | Should -Be 3
        $r.Sessions.Count | Should -Be 1
        $r.Sessions.UserPrincipalName | Should -Be 'user1@contoso.com'   # another user's session in the same pool is excluded
        Should -Invoke Get-DemoFileShareItemList -Times 4
    }
    It 'Test-AvdDemoSmoke with -SkipAzure checks the console and the FSLogix path' {
        Mock Resolve-DemoDnsName { @('10.100.9.5') }
        Mock Test-DemoTcpPort { $true }
        $rows = @(& (Join-Path $script:ScriptsRoot 'Test-AvdDemoSmoke.ps1') -SkipAzure -PassThru 6>$null)
        @($rows | Where-Object { $_.Check -like '*resolves*' -and $_.Check -notlike 'cluster*' }).Status | Should -Be 'GREEN'
        @($rows | Where-Object { $_.Check -like 'SMB 445*' }).Status | Should -Be 'GREEN'
        @($rows | Where-Object { $_.Check -eq 'No transcript active' }).Status | Should -Be 'GREEN'
    }
}
