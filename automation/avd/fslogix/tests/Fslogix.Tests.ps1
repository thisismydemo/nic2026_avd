#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
<#
.SYNOPSIS
    Pester 5 tests for the avd-fslogix solution. No Azure call and no real share: the registry tests use a throw-away HKCU key
    and the share/ACL tests mock the private wrappers. Authored by gpt-6-sol; reviewed by non-Anthropic models.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mock bodies cannot read the test file scope, so the ACL fixtures are passed through global variables that are removed in a finally block.')]
param()

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $scripts = Join-Path $root 'scripts'
    $settings = Join-Path $root 'fslogix-settings.json'
    $redirections = Join-Path $root 'redirections.xml'
    $registryRoot = 'HKCU:\Software\NIC26PesterTest'
    $profileShare = '\\files.example\profiles'
    $odfcShare = '\\files.example\odfc'
    $usersGroup = '00000000-0000-0000-0000-000000000001'
    $adminsGroup = 'aabbccdd-eeff-0011-2233-445566778899'
    Import-Module (Join-Path $scripts 'FslogixCommon.psm1') -Force
    if ($IsWindows) { $null = New-Item -Path $registryRoot -Force }
}
AfterAll {
    if ($IsWindows) { Remove-Item -LiteralPath $registryRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Shared configuration' {
    It 'parses without embedded share paths, tenant markers, or GUIDs' {
        $raw = Get-Content -LiteralPath $settings -Raw
        { ConvertFrom-Json $raw -ErrorAction Stop } | Should -Not -Throw
        $raw | Should -Not -Match '\\\\\\\\'
        $raw | Should -Not -Match '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'
        $raw | Should -Match '\{\{profile_share_unc\}\}'
        $raw | Should -Match '\{\{odfc_share_unc\}\}'
    }
    It 'has well-formed redirections with excludes and no UNC' {
        $raw = Get-Content -LiteralPath $redirections -Raw
        @(([xml]$raw).FrxProfileFolderRedirection.Excludes.Exclude).Count | Should -BeGreaterThan 0
        $raw | Should -Not -Match '\\\\'
    }
    It 'contains no forbidden logging commands or literal storage account names' {
        foreach ($file in (Get-ChildItem -LiteralPath $scripts -Filter '*.ps*1')) {
            (Get-Content -LiteralPath $file.FullName -Raw) | Should -Not -Match 'Write-Host|Start-Transcript'
        }
        foreach ($file in (Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object { $_.Extension -in '.ps1', '.psm1', '.json', '.xml', '.yml', '.md' } | Where-Object { $_.Name -ne 'Fslogix.Tests.ps1' })) {
            (Get-Content -LiteralPath $file.FullName -Raw) | Should -Not -Match 'https://[a-z0-9]+\.file\.core\.windows\.net'
        }
    }
}

Describe 'Registry plan and application' -Skip:(-not $IsWindows) {
    It 'plans every value on an empty root, then becomes idempotent' {
        $plan = @(Get-FslogixSettingPlan -SettingsPath $settings -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -RegistryRoot $registryRoot)
        @($plan | Where-Object Action -NE 'set').Count | Should -Be 0
        $null = & (Join-Path $scripts 'Set-FslogixHostConfig.ps1') -SettingsPath $settings -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -RegistryRoot $registryRoot -SkipDefender -Execute
        $second = @(& (Join-Path $scripts 'Set-FslogixHostConfig.ps1') -SettingsPath $settings -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -RegistryRoot $registryRoot -SkipDefender -Execute)
        @($second | Where-Object Action -NE 'none').Count | Should -Be 0
        $profileKey = Get-ItemProperty -LiteralPath "$registryRoot\SOFTWARE\FSLogix\Profiles"
        $profileKey.VHDLocations | Should -BeExactly $profileShare
        $profileKey.RedirXMLSourceFolder | Should -BeExactly ($profileShare + '\redirections')
    }
    It 'Test-FslogixHostConfig is clean after the apply, throws on drift, and returns rows with -PassThru' {
        $clean = @(& (Join-Path $scripts 'Test-FslogixHostConfig.ps1') -SettingsPath $settings -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -RegistryRoot $registryRoot)
        @($clean | Where-Object Action -NE 'none').Count | Should -Be 0
        Set-ItemProperty -LiteralPath "$registryRoot\SOFTWARE\FSLogix\Profiles" -Name VolumeType -Value 'VHD'
        { & (Join-Path $scripts 'Test-FslogixHostConfig.ps1') -SettingsPath $settings -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -RegistryRoot $registryRoot } | Should -Throw '*differ*'
        $rows = @(& (Join-Path $scripts 'Test-FslogixHostConfig.ps1') -SettingsPath $settings -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -RegistryRoot $registryRoot -PassThru)
        @($rows | Where-Object { $_.Action -eq 'set' -and $_.Name -eq 'VolumeType' }).Count | Should -Be 1
    }
    It 'selects rehearsal and production prevention values' {
        foreach ($mode in @('Production', 'Rehearsal')) {
            $rows = @(Get-FslogixSettingPlan -SettingsPath $settings -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -Mode $mode -RegistryRoot $registryRoot)
            $expected = if ($mode -eq 'Production') { 1 } else { 0 }
            $prevent = @($rows | Where-Object { $_.Name -like 'PreventLogin*' })
            $prevent.Count | Should -Be 2
            @($prevent | Where-Object { $_.Desired -ne $expected }).Count | Should -Be 0
        }
    }
    It 'rejects incomplete and trailing-backslash UNC paths' {
        foreach ($bad in @('\\server', '\\server\share\')) {
            { Get-FslogixSettingPlan -SettingsPath $settings -ProfileShareUnc $bad -OdfcShareUnc $odfcShare -RegistryRoot $registryRoot } | Should -Throw
        }
    }
}

Describe 'Entra SIDs and ACLs' {
    It 'converts GUID bytes as four little-endian UInt32 values' {
        ConvertTo-EntraGroupSid $usersGroup | Should -Be 'S-1-12-1-0-0-0-16777216'   # .NET Guid byte order: the last group 00..01 reads as 0x01000000
        $bytes = ([guid]$adminsGroup).ToByteArray()
        $numbers = @(0, 4, 8, 12 | ForEach-Object { [BitConverter]::ToUInt32($bytes, $_) })
        ConvertTo-EntraGroupSid $adminsGroup | Should -Be ('S-1-12-1-' + ($numbers -join '-'))
        { ConvertTo-EntraGroupSid 'invalid' } | Should -Throw
    }
    It 'plans the required grants and removals on both shares' {
        $plan = @(Get-FslogixAclPlan -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -UsersGroupObjectId $usersGroup -AdminsGroupObjectId $adminsGroup)
        $plan.Count | Should -Be 2
        foreach ($row in $plan) {
            $text = $row.Arguments -join ' '
            foreach ($sid in @('S-1-5-18', 'S-1-3-0', 'S-1-5-11', 'S-1-5-32-545', (ConvertTo-EntraGroupSid $usersGroup), (ConvertTo-EntraGroupSid $adminsGroup))) {
                $text | Should -Match ([regex]::Escape($sid))
            }
            $text | Should -Match '\(OI\)\(CI\)\(IO\)M'
            $text | Should -Match '/inheritance:r'
        }
    }
}

Describe 'Share permission execution' -Skip:(-not $IsWindows) {
    BeforeEach {
        Mock Invoke-FslogixIcacls -ModuleName FslogixCommon {}
    }
    It 'does not invoke icacls without Execute' {
        $null = & (Join-Path $scripts 'Set-FslogixSharePermissions.ps1') -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -UsersGroupObjectId $usersGroup -AdminsGroupObjectId $adminsGroup
        Should -Invoke Invoke-FslogixIcacls -ModuleName FslogixCommon -Times 0
    }
    It 'stops after the first failing write' {
        Mock Test-Path { $true }
        Mock Invoke-FslogixIcacls -ModuleName FslogixCommon { throw 'icacls failure' }
        { & (Join-Path $scripts 'Set-FslogixSharePermissions.ps1') -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -UsersGroupObjectId $usersGroup -AdminsGroupObjectId $adminsGroup -Execute } | Should -Throw
        Should -Invoke Invoke-FslogixIcacls -ModuleName FslogixCommon -Times 1
    }
    It 'refuses to write when the share root is unreachable' {
        Mock Test-Path { $false }
        { & (Join-Path $scripts 'Set-FslogixSharePermissions.ps1') -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -UsersGroupObjectId $usersGroup -AdminsGroupObjectId $adminsGroup -Execute } | Should -Throw '*unreachable*'
        Should -Invoke Invoke-FslogixIcacls -ModuleName FslogixCommon -Times 0
    }
}

Describe 'Redirections publication' {
    It 'refuses to overwrite differing content without Overwrite' {
        Mock Test-Path { $true }
        Mock Get-FileHash { if ($LiteralPath -like '*redirections.xml' -and $LiteralPath -like '*\\files.example*') { [pscustomobject]@{ Hash = 'BBBB' } } else { [pscustomobject]@{ Hash = 'AAAA' } } }
        { & (Join-Path $scripts 'Publish-FslogixRedirections.ps1') -ProfileShareUnc $profileShare -RedirectionsPath $redirections } | Should -Throw '*Overwrite*'
    }
    It 'rejects a redirections file that contains a UNC path' {
        $bad = Join-Path $TestDrive 'bad.xml'
        Set-Content -LiteralPath $bad -Value '<FrxProfileFolderRedirection><Excludes><Exclude Copy="0">\\server\share</Exclude></Excludes></FrxProfileFolderRedirection>'
        { & (Join-Path $scripts 'Publish-FslogixRedirections.ps1') -ProfileShareUnc $profileShare -RedirectionsPath $bad } | Should -Throw '*must not contain a UNC*'
    }
}

Describe 'Defender exclusions' -Skip:(-not $IsWindows) {
    It 'adds only the missing exclusions through the wrapper and none with -SkipDefender' {
        Mock Get-FslogixMpPreference -ModuleName FslogixCommon { [pscustomobject]@{ ExclusionPath = @('%ProgramFiles%\FSLogix\Apps\frxdrv.sys'); ExclusionProcess = @('frxsvc.exe') } }
        Mock Add-FslogixMpExclusion -ModuleName FslogixCommon {}
        $null = & (Join-Path $scripts 'Set-FslogixHostConfig.ps1') -SettingsPath $settings -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -RegistryRoot $registryRoot -Execute
        # 7 paths and 2 processes are configured; one of each already exists
        Should -Invoke Add-FslogixMpExclusion -ModuleName FslogixCommon -Times 6 -Exactly -ParameterFilter { $Kind -eq 'ExclusionPath' }
        Should -Invoke Add-FslogixMpExclusion -ModuleName FslogixCommon -Times 1 -Exactly -ParameterFilter { $Kind -eq 'ExclusionProcess' }
        Should -Invoke Add-FslogixMpExclusion -ModuleName FslogixCommon -Times 0 -Exactly -ParameterFilter { $Value -eq 'frxsvc.exe' }
    }
    It 'touches nothing without -Execute' {
        Mock Get-FslogixMpPreference -ModuleName FslogixCommon { [pscustomobject]@{ ExclusionPath = @(); ExclusionProcess = @() } }
        Mock Add-FslogixMpExclusion -ModuleName FslogixCommon {}
        $null = & (Join-Path $scripts 'Set-FslogixHostConfig.ps1') -SettingsPath $settings -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -RegistryRoot $registryRoot
        Should -Invoke Add-FslogixMpExclusion -ModuleName FslogixCommon -Times 0 -Exactly
    }
}

Describe 'ACL check (exact permitted set, by SID)' {
    BeforeAll {
        $usersSid = ConvertTo-EntraGroupSid $usersGroup
        $adminsSid = ConvertTo-EntraGroupSid $adminsGroup
        function New-AclRule {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper that builds an in-memory object; changes no state.')]
            param($Sid, $Rights, $Inheritance, $Propagation, $AccessType = 'Allow', $Inherited = $false)
            [pscustomobject]@{ Sid = $Sid; AccessType = $AccessType; Rights = $Rights; Inheritance = $Inheritance; Propagation = $Propagation; Inherited = $Inherited }
        }
        $script:goodRules = @(
            New-AclRule 'S-1-5-18' 0x1F01FF 3 0
            New-AclRule $adminsSid 0x1F01FF 3 0
            New-AclRule $usersSid 0x1301BF 0 0
            New-AclRule 'S-1-3-0' 0x1301BF 3 2
        )
    }
    It 'accepts exactly the permitted four entries' {
        @(Test-FslogixAclRule -Rules $script:goodRules -UsersSid $usersSid -AdminsSid $adminsSid).Count | Should -Be 0
    }
    It 'reports an extra principal, a deny entry, an inherited entry and a missing entry' {
        $extra = $script:goodRules + (New-AclRule 'S-1-1-0' 0x1301BF 3 0)
        (Test-FslogixAclRule -Rules $extra -UsersSid $usersSid -AdminsSid $adminsSid) -join ';' | Should -Match 'unexpected principal S-1-1-0'
        $deny = $script:goodRules + (New-AclRule $usersSid 0x1301BF 0 0 'Deny')
        (Test-FslogixAclRule -Rules $deny -UsersSid $usersSid -AdminsSid $adminsSid) -join ';' | Should -Match 'deny entry'
        $inherited = @($script:goodRules | Select-Object -SkipLast 1) + (New-AclRule 'S-1-3-0' 0x1301BF 3 2 'Allow' $true)
        (Test-FslogixAclRule -Rules $inherited -UsersSid $usersSid -AdminsSid $adminsSid) -join ';' | Should -Match 'inherited entry'
        (Test-FslogixAclRule -Rules @($script:goodRules | Select-Object -First 3) -UsersSid $usersSid -AdminsSid $adminsSid) -join ';' | Should -Match 'missing entry for CREATOR OWNER'
    }
    It 'reports weaker rights and wrong inheritance (users must be this folder only)' {
        $weak = @($script:goodRules | Where-Object { $_.Sid -ne $usersSid }) + (New-AclRule $usersSid 0x120089 0 0)
        (Test-FslogixAclRule -Rules $weak -UsersSid $usersSid -AdminsSid $adminsSid) -join ';' | Should -Match 'users group: rights'
        $wide = @($script:goodRules | Where-Object { $_.Sid -ne $usersSid }) + (New-AclRule $usersSid 0x1301BF 3 0)
        (Test-FslogixAclRule -Rules $wide -UsersSid $usersSid -AdminsSid $adminsSid) -join ';' | Should -Match 'users group: inheritance'
    }
    It 'treats a missing rule list as every entry missing' {
        @(Test-FslogixAclRule -Rules @() -UsersSid $usersSid -AdminsSid $adminsSid).Count | Should -Be 4
    }
}

Describe 'Share permission execution with the ACL readback' -Skip:(-not $IsWindows) {
    It 'succeeds when the readback is exactly the permitted set and fails when it is not' {
        Mock Test-Path { $true }
        Mock Invoke-FslogixIcacls -ModuleName FslogixCommon {}
        $users = ConvertTo-EntraGroupSid $usersGroup
        $admins = ConvertTo-EntraGroupSid $adminsGroup
        $global:Nic26FslogixAcl = $true
        try {
            Mock Get-FslogixAclRule -ModuleName FslogixCommon { if ($global:Nic26FslogixAcl) { Get-Variable -Scope Global -Name Nic26FslogixGood -ValueOnly } else { Get-Variable -Scope Global -Name Nic26FslogixBad -ValueOnly } }
            $global:Nic26FslogixGood = @(
                [pscustomobject]@{ Sid = 'S-1-5-18'; AccessType = 'Allow'; Rights = 0x1F01FF; Inheritance = 3; Propagation = 0; Inherited = $false }
                [pscustomobject]@{ Sid = $admins; AccessType = 'Allow'; Rights = 0x1F01FF; Inheritance = 3; Propagation = 0; Inherited = $false }
                [pscustomobject]@{ Sid = $users; AccessType = 'Allow'; Rights = 0x1301BF; Inheritance = 0; Propagation = 0; Inherited = $false }
                [pscustomobject]@{ Sid = 'S-1-3-0'; AccessType = 'Allow'; Rights = 0x1301BF; Inheritance = 3; Propagation = 2; Inherited = $false }
            )
            $global:Nic26FslogixBad = $global:Nic26FslogixGood + [pscustomobject]@{ Sid = 'S-1-5-11'; AccessType = 'Allow'; Rights = 0x1301BF; Inheritance = 3; Propagation = 0; Inherited = $false }
            { & (Join-Path $scripts 'Set-FslogixSharePermissions.ps1') -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -UsersGroupObjectId $usersGroup -AdminsGroupObjectId $adminsGroup -Execute } | Should -Not -Throw
            $global:Nic26FslogixAcl = $false
            { & (Join-Path $scripts 'Set-FslogixSharePermissions.ps1') -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -UsersGroupObjectId $usersGroup -AdminsGroupObjectId $adminsGroup -Execute } | Should -Throw '*does not match the permitted set*unexpected principal S-1-5-11*'
        }
        finally { Remove-Variable -Name Nic26FslogixAcl, Nic26FslogixGood, Nic26FslogixBad -Scope Global -ErrorAction SilentlyContinue }
    }
}

Describe 'Registry value kind' -Skip:(-not $IsWindows) {
    It 'plans a change when a value has the right text but the wrong registry kind' {
        $key = "$registryRoot\SOFTWARE\FSLogix\Profiles"
        $null = New-Item -Path $key -Force
        New-ItemProperty -LiteralPath $key -Name 'VolumeType' -Value 'VHDX' -PropertyType ExpandString -Force | Out-Null
        $row = @(Get-FslogixSettingPlan -SettingsPath $settings -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -RegistryRoot $registryRoot | Where-Object { $_.Name -eq 'VolumeType' -and $_.Area -eq 'profiles' })
        $row.Count | Should -Be 1
        $row[0].Action | Should -Be 'set'
        New-ItemProperty -LiteralPath $key -Name 'VolumeType' -Value 'VHDX' -PropertyType String -Force | Out-Null
        @(Get-FslogixSettingPlan -SettingsPath $settings -ProfileShareUnc $profileShare -OdfcShareUnc $odfcShare -RegistryRoot $registryRoot | Where-Object { $_.Name -eq 'VolumeType' -and $_.Area -eq 'profiles' })[0].Action | Should -Be 'none'
    }
}
