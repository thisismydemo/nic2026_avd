#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
<#
.SYNOPSIS
    Pester 5 tests for scripts/New-AvdRegistrationToken.ps1 (K-7: token in memory only). No Azure call is made.
    Authored by gpt-6-sol; reviewed by non-Anthropic models.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester BeforeAll variables are consumed inside It and Mock blocks.')]
param()

BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..' 'scripts' 'New-AvdRegistrationToken.ps1'
    $script:subscriptionId = [guid]::NewGuid().ToString()
    $script:resourceGroupName = 'rg-' + [guid]::NewGuid().ToString('N')
    $script:hostPoolName = 'hp-' + [guid]::NewGuid().ToString('N')
    $script:fakeToken = 'fake-' + [guid]::NewGuid().ToString('N')

    function global:Get-AzContext { [CmdletBinding()] param() }
    function global:Get-AzWvdHostPool { [CmdletBinding()] param([string] $SubscriptionId, [string] $ResourceGroupName, [string] $Name) }
    function global:New-AzWvdRegistrationInfo { [CmdletBinding()] param([string] $SubscriptionId, [string] $ResourceGroupName, [string] $HostPoolName, [string] $ExpirationTime) }
    function global:Remove-AzWvdRegistrationInfo { [CmdletBinding()] param([string] $SubscriptionId, [string] $ResourceGroupName, [string] $HostPoolName) }
}

AfterAll {
    foreach ($commandName in @('Get-AzContext', 'Get-AzWvdHostPool', 'New-AzWvdRegistrationInfo', 'Remove-AzWvdRegistrationInfo')) {
        Remove-Item -Path "Function:\global:$commandName" -ErrorAction SilentlyContinue
    }
}

Describe 'New-AvdRegistrationToken' {
    BeforeEach {
        $ctx = [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $script:subscriptionId }; Account = [pscustomobject]@{ Id = 'operator' } }
        $tokenText = $script:fakeToken
        Mock -CommandName Get-AzContext -MockWith { $ctx }.GetNewClosure()
        Mock -CommandName Get-AzWvdHostPool -MockWith { [pscustomobject]@{ Name = $Name } }
        Mock -CommandName New-AzWvdRegistrationInfo -MockWith { [pscustomobject]@{ Token = $tokenText } }.GetNewClosure()
        Mock -CommandName Remove-AzWvdRegistrationInfo -MockWith {}
    }

    It 'creates nothing and returns nothing without Execute' {
        $result = & $script:scriptPath -SubscriptionId $script:subscriptionId -ResourceGroupName $script:resourceGroupName -HostPoolName $script:hostPoolName
        $result | Should -BeNullOrEmpty
        Should -Invoke -CommandName New-AzWvdRegistrationInfo -Times 0 -Exactly
    }

    It 'returns a SecureString with the default two-hour UTC expiration' {
        $before = [datetime]::UtcNow
        $result = & $script:scriptPath -SubscriptionId $script:subscriptionId -ResourceGroupName $script:resourceGroupName -HostPoolName $script:hostPoolName -Execute
        $after = [datetime]::UtcNow
        $result.Token | Should -BeOfType [securestring]
        $result.ExpirationTimeUtc.Kind | Should -Be 'Utc'
        $result.ExpirationTimeUtc | Should -BeGreaterThan $before.AddMinutes(119)
        $result.ExpirationTimeUtc | Should -BeLessThan $after.AddMinutes(121)
        Should -Invoke -CommandName New-AzWvdRegistrationInfo -Times 1 -Exactly -ParameterFilter {
            ([datetimeoffset]::Parse($ExpirationTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).Offset -eq [timespan]::Zero
        }
    }

    It 'does not emit the token text on any captured output stream' {
        $captured = @(& $script:scriptPath -SubscriptionId $script:subscriptionId -ResourceGroupName $script:resourceGroupName -HostPoolName $script:hostPoolName -Execute -InformationAction Continue -Verbose *>&1)
        foreach ($entry in $captured) {
            if ($entry -is [pscustomobject] -and $entry.PSObject.Properties['Token']) { continue }
            [string]$entry | Should -Not -Match ([regex]::Escape($script:fakeToken))
        }
    }

    It 'rejects expiration hours outside 1 to 24' {
        foreach ($hours in @(0, 25)) {
            { & $script:scriptPath -SubscriptionId $script:subscriptionId -ResourceGroupName $script:resourceGroupName -HostPoolName $script:hostPoolName -ExpirationHours $hours -Execute } | Should -Throw
        }
        Should -Invoke -CommandName New-AzWvdRegistrationInfo -Times 0 -Exactly
    }

    It 'reports a missing host pool without creating a token' {
        Mock -CommandName Get-AzWvdHostPool -MockWith { throw 'Not found.' }
        { & $script:scriptPath -SubscriptionId $script:subscriptionId -ResourceGroupName $script:resourceGroupName -HostPoolName $script:hostPoolName -Execute } | Should -Throw '*host pool*'
        Should -Invoke -CommandName New-AzWvdRegistrationInfo -Times 0 -Exactly
    }

    It 'revokes only when Execute is specified' {
        $preview = & $script:scriptPath -SubscriptionId $script:subscriptionId -ResourceGroupName $script:resourceGroupName -HostPoolName $script:hostPoolName -Revoke
        $preview | Should -BeNullOrEmpty
        Should -Invoke -CommandName Remove-AzWvdRegistrationInfo -Times 0 -Exactly
        $result = & $script:scriptPath -SubscriptionId $script:subscriptionId -ResourceGroupName $script:resourceGroupName -HostPoolName $script:hostPoolName -Revoke -Execute
        $result.Revoked | Should -BeTrue
        Should -Invoke -CommandName Remove-AzWvdRegistrationInfo -Times 1 -Exactly
        Should -Invoke -CommandName New-AzWvdRegistrationInfo -Times 0 -Exactly
    }

    It 'returns exactly the documented properties, with the token only as a SecureString' {
        $result = & $script:scriptPath -SubscriptionId $script:subscriptionId -ResourceGroupName $script:resourceGroupName -HostPoolName $script:hostPoolName -Execute
        @($result.PSObject.Properties.Name | Sort-Object) | Should -Be @('ExpirationTimeUtc', 'HostPoolName', 'ResourceGroupName', 'Token')
        foreach ($property in $result.PSObject.Properties) {
            if ($property.Name -eq 'Token') { $property.Value | Should -BeOfType [securestring] }
            else { [string]$property.Value | Should -Not -Match ([regex]::Escape($script:fakeToken)) }
        }
    }

    It 'passes the subscription to every Az call and never switches the session context' {
        $null = & $script:scriptPath -SubscriptionId $script:subscriptionId -ResourceGroupName $script:resourceGroupName -HostPoolName $script:hostPoolName -Execute
        Should -Invoke -CommandName Get-AzWvdHostPool -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $script:subscriptionId }
        Should -Invoke -CommandName New-AzWvdRegistrationInfo -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $script:subscriptionId }
        (Get-Content -LiteralPath $script:scriptPath -Raw) | Should -Not -Match 'Set-AzContext'
    }

    It 'fails when the service returns no token' {
        Mock -CommandName New-AzWvdRegistrationInfo -MockWith { [pscustomobject]@{ Token = '' } }
        { & $script:scriptPath -SubscriptionId $script:subscriptionId -ResourceGroupName $script:resourceGroupName -HostPoolName $script:hostPoolName -Execute } | Should -Throw '*no registration token*'
    }

    It 'contains no token-export, plaintext-conversion or file-writing commands' {
        $source = Get-Content -LiteralPath $script:scriptPath -Raw
        $source | Should -Not -Match '(?i)\bExport-Clixml\b'
        $source | Should -Not -Match '(?i)\bConvertFrom-SecureString\b'
        $source | Should -Not -Match '(?i)\b(?:Out-File|Set-Content|Add-Content)\b'
    }
}
