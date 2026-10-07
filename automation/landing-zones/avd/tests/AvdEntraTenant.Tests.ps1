#Requires -Version 7.0
<#
    Pester 5 - Entra tenant configuration scripts for lz-avd (Set-AvdEntraSso, New-AvdConditionalAccess).
    Graph cmdlets are stubbed with the real parameter names (Microsoft.Graph 2.40); no tenant call is made.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester 5: BeforeAll variables are consumed inside It and Mock blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mock bodies resolve $script: to the mocked command scope, so one global list records the calls and is removed in AfterAll.')]
param()

BeforeAll {
    $script:scriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
    $script:tenant = '00000000-0000-0000-0000-000000000000'
    $script:appIds = Import-PowerShellDataFile -Path (Join-Path $script:scriptsDir 'AvdMicrosoftAppIds.psd1')
    function global:Connect-MgGraph { param($TenantId, $Scopes, [switch]$NoWelcome) }
    function global:Get-MgServicePrincipal { param($Filter) }
    function global:Get-MgServicePrincipalRemoteDesktopSecurityConfiguration { param($ServicePrincipalId) }
    function global:Update-MgServicePrincipalRemoteDesktopSecurityConfiguration { param($ServicePrincipalId, [switch]$IsRemoteDesktopProtocolEnabled) }
    function global:Get-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup { param($ServicePrincipalId) }
    function global:New-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup { param($ServicePrincipalId, $BodyParameter) }
    function global:Get-MgGroup { param($Filter, $ConsistencyLevel, $Top) }
    function global:Get-MgIdentityConditionalAccessPolicy { param([switch]$All) }
    function global:New-MgIdentityConditionalAccessPolicy { param($BodyParameter) }
}

AfterAll {
    foreach ($f in 'Connect-MgGraph', 'Get-MgServicePrincipal', 'Get-MgServicePrincipalRemoteDesktopSecurityConfiguration', 'Update-MgServicePrincipalRemoteDesktopSecurityConfiguration', 'Get-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup', 'New-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup', 'Get-MgGroup', 'Get-MgIdentityConditionalAccessPolicy', 'New-MgIdentityConditionalAccessPolicy') {
        Remove-Item -Path "function:global:$f" -ErrorAction SilentlyContinue
    }
}

Describe 'Set-AvdEntraSso' {
    BeforeEach {
        $script:sso = Join-Path $script:scriptsDir 'Set-AvdEntraSso.ps1'
        Mock -CommandName Connect-MgGraph -MockWith { }
        Mock -CommandName Get-MgServicePrincipal -MockWith { [pscustomobject]@{ Id = 'sp-1' } }
        Mock -CommandName Get-MgGroup -MockWith { [pscustomobject]@{ Id = 'grp-1'; DisplayName = 'grp-devices' } }
        Mock -CommandName Get-MgServicePrincipalRemoteDesktopSecurityConfiguration -MockWith { [pscustomobject]@{ IsRemoteDesktopProtocolEnabled = $false } }
        Mock -CommandName Get-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup -MockWith { @() }
        Mock -CommandName Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -MockWith { }
        Mock -CommandName New-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup -MockWith { }
    }

    It 'changes nothing without -Execute' {
        $rows = & $script:sso -TenantId $script:tenant -TargetDeviceGroupName 'grp-devices'
        @($rows | Where-Object { $_.Status -eq 'WhatIf' }).Count | Should -Be 2
        Should -Invoke -CommandName Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -Times 0 -Exactly
        Should -Invoke -CommandName New-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup -Times 0 -Exactly
    }

    It 'enables the protocol and adds the group with -Execute' {
        $null = & $script:sso -TenantId $script:tenant -TargetDeviceGroupName 'grp-devices' -Execute -Confirm:$false
        Should -Invoke -CommandName Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -Times 1 -Exactly -ParameterFilter { $ServicePrincipalId -eq 'sp-1' -and $IsRemoteDesktopProtocolEnabled }
        Should -Invoke -CommandName New-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup -Times 1 -Exactly -ParameterFilter { $BodyParameter.id -eq 'grp-1' }
    }

    It 'is idempotent when already configured' {
        Mock -CommandName Get-MgServicePrincipalRemoteDesktopSecurityConfiguration -MockWith { [pscustomobject]@{ IsRemoteDesktopProtocolEnabled = $true } }
        Mock -CommandName Get-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup -MockWith { [pscustomobject]@{ Id = 'grp-1' } }
        $rows = & $script:sso -TenantId $script:tenant -TargetDeviceGroupName 'grp-devices' -Execute -Confirm:$false
        @($rows | Where-Object { $_.Status -eq 'No change' }).Count | Should -Be 2
        Should -Invoke -CommandName Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -Times 0 -Exactly
        Should -Invoke -CommandName New-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup -Times 0 -Exactly
    }

    It 'treats a missing configuration as not yet enabled' {
        Mock -CommandName Get-MgServicePrincipalRemoteDesktopSecurityConfiguration -MockWith { throw 'Request_ResourceNotFound: 404' }
        $null = & $script:sso -TenantId $script:tenant -TargetDeviceGroupName 'grp-devices' -Execute -Confirm:$false
        Should -Invoke -CommandName Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -Times 1 -Exactly
    }

    It 'rethrows other read errors' {
        Mock -CommandName Get-MgServicePrincipalRemoteDesktopSecurityConfiguration -MockWith { throw 'Forbidden 403' }
        { & $script:sso -TenantId $script:tenant -TargetDeviceGroupName 'grp-devices' -Execute -Confirm:$false } | Should -Throw '*403*'
    }

    It 'fails before any change when a group is missing' {
        Mock -CommandName Get-MgGroup -MockWith { @() }
        { & $script:sso -TenantId $script:tenant -TargetDeviceGroupName 'nope' -Execute -Confirm:$false } | Should -Throw '*not found*'
        Should -Invoke -CommandName Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -Times 0 -Exactly
    }

    It 'allows enabling SSO with no target groups' {
        $rows = & $script:sso -TenantId $script:tenant -Execute -Confirm:$false
        @($rows | Where-Object { $_.Status -eq 'Updated' }).Count | Should -Be 1
        Should -Invoke -CommandName New-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup -Times 0 -Exactly
    }

    It 'refuses an ambiguous group name before any change' {
        Mock -CommandName Get-MgGroup -MockWith { @([pscustomobject]@{ Id = 'a'; DisplayName = 'dup' }, [pscustomobject]@{ Id = 'b'; DisplayName = 'dup' }) }
        { & $script:sso -TenantId $script:tenant -TargetDeviceGroupName 'dup' -Execute -Confirm:$false } | Should -Throw '*ambiguous*'
        Should -Invoke -CommandName Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -Times 0 -Exactly
    }

    It 'refuses more than 10 groups' {
        $names = 1..11 | ForEach-Object { "g$_" }
        { & $script:sso -TenantId $script:tenant -TargetDeviceGroupName $names -Execute -Confirm:$false } | Should -Throw '*at most 10*'
    }

    It 'fails when the Windows Cloud Login service principal is absent' {
        Mock -CommandName Get-MgServicePrincipal -MockWith { @() }
        { & $script:sso -TenantId $script:tenant -TargetDeviceGroupName 'grp-devices' -Execute -Confirm:$false } | Should -Throw '*service principal not found*'
    }
}

Describe 'New-AvdConditionalAccess' {
    BeforeEach {
        $script:ca = Join-Path $script:scriptsDir 'New-AvdConditionalAccess.ps1'
        $global:Nic26CaBodies = [System.Collections.Generic.List[object]]::new()
        Mock -CommandName Connect-MgGraph -MockWith { }
        Mock -CommandName Get-MgGroup -MockWith { [pscustomobject]@{ Id = "id-$($Filter.Split("'")[1])"; DisplayName = $Filter.Split("'")[1] } }
        Mock -CommandName Get-MgIdentityConditionalAccessPolicy -MockWith { @() }
        Mock -CommandName New-MgIdentityConditionalAccessPolicy -MockWith { $global:Nic26CaBodies.Add($BodyParameter) }
    }
    AfterEach {
        Remove-Variable -Name Nic26CaBodies -Scope Global -ErrorAction SilentlyContinue
    }

    It 'creates nothing without -Execute' {
        $rows = & $script:ca -TenantId $script:tenant -UsersGroupName 'users' -NamePrefix 'CA-x' 3>$null 6>$null
        @($rows | Where-Object { $_.Status -eq 'WhatIf' }).Count | Should -Be 2
        Should -Invoke -CommandName New-MgIdentityConditionalAccessPolicy -Times 0 -Exactly
    }

    It 'creates two report-only policies targeting the right apps' {
        $null = & $script:ca -TenantId $script:tenant -UsersGroupName 'users' -NamePrefix 'CA-x' -Execute -Confirm:$false 3>$null 6>$null
        $global:Nic26CaBodies.Count | Should -Be 2
        $service = $global:Nic26CaBodies | Where-Object { $_.displayName -eq 'CA-x-mfa-service' }
        $sso = $global:Nic26CaBodies | Where-Object { $_.displayName -eq 'CA-x-mfa-sso' }
        $service.state | Should -Be 'enabledForReportingButNotEnforced'
        $service.conditions.applications.includeApplications | Should -Be @($script:appIds.AzureVirtualDesktop)
        $sso.conditions.applications.includeApplications | Should -Be @($script:appIds.WindowsCloudLogin)
        $service.grantControls.builtInControls | Should -Be @('mfa')
        $service.sessionControls.signInFrequency.frequencyInterval | Should -Be 'timeBased'
        $service.sessionControls.signInFrequency.value | Should -Be 1
        $service.conditions.users.includeGroups | Should -Be @('id-users')
    }

    It 'uses everyTime on the Windows Cloud Login policy only' {
        $null = & $script:ca -TenantId $script:tenant -UsersGroupName 'users' -NamePrefix 'CA-x' -EveryTimeOnWindowsCloudLogin -Execute -Confirm:$false 3>$null 6>$null
        ($global:Nic26CaBodies | Where-Object { $_.displayName -eq 'CA-x-mfa-sso' }).sessionControls.signInFrequency.frequencyInterval | Should -Be 'everyTime'
        ($global:Nic26CaBodies | Where-Object { $_.displayName -eq 'CA-x-mfa-service' }).sessionControls.signInFrequency.frequencyInterval | Should -Be 'timeBased'
    }

    It 'leaves an existing policy alone' {
        Mock -CommandName Get-MgIdentityConditionalAccessPolicy -MockWith { [pscustomobject]@{ DisplayName = 'CA-x-mfa-service'; State = 'enabled'; Conditions = $null; GrantControls = $null } }
        $rows = & $script:ca -TenantId $script:tenant -UsersGroupName 'users' -NamePrefix 'CA-x' -Execute -Confirm:$false 3>$null 6>$null
        @($rows | Where-Object { $_.Status -eq 'Exists' }).Count | Should -Be 1
        $global:Nic26CaBodies.Count | Should -Be 1
    }

    It 'passes exclusions and rejects an overlapping exclusion' {
        $null = & $script:ca -TenantId $script:tenant -UsersGroupName 'users' -NamePrefix 'CA-x' -ExcludeGroupName 'breakglass' -Execute -Confirm:$false 3>$null 6>$null
        $global:Nic26CaBodies[0].conditions.users.excludeGroups | Should -Be @('id-breakglass')
        { & $script:ca -TenantId $script:tenant -UsersGroupName 'users' -NamePrefix 'CA-x' -ExcludeGroupName 'users' -Execute -Confirm:$false 3>$null 6>$null } | Should -Throw '*cannot also be an excluded group*'
    }

    It 'refuses an ambiguous users group' {
        Mock -CommandName Get-MgGroup -MockWith { @([pscustomobject]@{ Id = 'a'; DisplayName = 'dup' }, [pscustomobject]@{ Id = 'b'; DisplayName = 'dup' }) }
        { & $script:ca -TenantId $script:tenant -UsersGroupName 'dup' -NamePrefix 'CA-x' -Execute -Confirm:$false 3>$null 6>$null } | Should -Throw '*ambiguous*'
        Should -Invoke -CommandName New-MgIdentityConditionalAccessPolicy -Times 0 -Exactly
    }

    It 'refuses the ARM Provider and Windows 365 apps and invalid ids' {
        { & $script:ca -TenantId $script:tenant -UsersGroupName 'users' -NamePrefix 'CA-x' -ExtraTargetAppId $script:appIds.AzureVirtualDesktopArmProvider -Execute -Confirm:$false } | Should -Throw '*prohibited*'
        { & $script:ca -TenantId $script:tenant -UsersGroupName 'users' -NamePrefix 'CA-x' -ExtraTargetAppId $script:appIds.Windows365.ToUpperInvariant() -Execute -Confirm:$false } | Should -Throw '*prohibited*'
        { & $script:ca -TenantId $script:tenant -UsersGroupName 'users' -NamePrefix 'CA-x' -ExtraTargetAppId 'not-a-guid' -Execute -Confirm:$false } | Should -Throw '*not a valid*'
        Should -Invoke -CommandName New-MgIdentityConditionalAccessPolicy -Times 0 -Exactly
    }

    It 'warns about an enabled all-apps policy' {
        Mock -CommandName Get-MgIdentityConditionalAccessPolicy -MockWith {
            [pscustomobject]@{ DisplayName = 'baseline'; State = 'enabled'; Conditions = [pscustomobject]@{ Applications = [pscustomobject]@{ IncludeApplications = @('All') } }; GrantControls = $null }
        }
        $warnings = @()
        $null = & $script:ca -TenantId $script:tenant -UsersGroupName 'users' -NamePrefix 'CA-x' -WarningVariable warnings -WarningAction SilentlyContinue 6>$null
        ($warnings -join ' ') | Should -Match 'includes All applications'
    }
}
