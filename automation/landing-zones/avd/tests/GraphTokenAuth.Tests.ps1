#Requires -Version 7.0
<#
.SYNOPSIS
    Checks tenant routing and SDK parameter sets without live Graph authentication.
.NOTES
    Author: Kristopher Turner
    TaskReference: T-3.2.2
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Only synthetic JWT fixtures are constructed; no credentials.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Fixture variables are consumed by extracted production scriptblocks.')]
param()
BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot '../scripts/New-AvdEntraGroups.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Group script parse errors' }
    $helper = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Assert-LzAvdGraphTokenTenant'
        }, $true)
    . ([scriptblock]::Create($helper.Extent.Text))
    $branch = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text.StartsWith('if ($null -eq $GraphAccessToken)')
        }, $true)
    $script:authBranch = [scriptblock]::Create($branch.Extent.Text)
    function Connect-MgGraph {
        [CmdletBinding(DefaultParameterSetName = 'Interactive')]
        param(
            [Parameter(ParameterSetName = 'Interactive')][string]$TenantId,
            [Parameter(ParameterSetName = 'Interactive')][string[]]$Scopes,
            [Parameter(Mandatory, ParameterSetName = 'Token')][securestring]$AccessToken,
            [switch]$NoWelcome
        )
        $script:graphAuthCalls.Add([pscustomobject]@{
                ParameterSet = $PSCmdlet.ParameterSetName
                Keys = @($PSBoundParameters.Keys)
                Token = $AccessToken
                Tenant = $TenantId
                Scopes = $Scopes
                NoWelcome = $NoWelcome
            })
    }
    function Get-TestGraphToken {
        param([hashtable]$Claims)
        $header = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"alg":"none"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Claims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $signature = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('synthetic')).TrimEnd('=')
        ConvertTo-SecureString "$header.$payload.$signature" -AsPlainText -Force
    }
}
Describe 'Operator Graph token routing' {
    BeforeEach { $script:graphAuthCalls = [Collections.Generic.List[object]]::new() }
    It 'uses the secure custom-token parameter set for the matching tenant' {
        $TenantId = '00000000-0000-0000-0000-000000000000'
        $GraphAccessToken = Get-TestGraphToken @{ tid = $TenantId }
        try {
            & $script:authBranch
            $script:graphAuthCalls.Count | Should -Be 1
            $script:graphAuthCalls[0].ParameterSet | Should -Be 'Token'
            $script:graphAuthCalls[0].Token | Should -BeOfType [securestring]
            $script:graphAuthCalls[0].Keys | Should -Not -Contain 'TenantId'
            $script:graphAuthCalls[0].Keys | Should -Not -Contain 'Scopes'
            $script:graphAuthCalls[0].NoWelcome | Should -BeTrue
            $GraphAccessToken.Length | Should -BeGreaterThan 0
        }
        finally { $GraphAccessToken.Dispose() }
    }
    It 'preserves interactive tenant and scopes when no token is supplied' {
        $TenantId = '00000000-0000-0000-0000-000000000000'
        $GraphAccessToken = $null
        $scopes = @('Group.ReadWrite.All', 'GroupMember.ReadWrite.All')
        & $script:authBranch
        $script:graphAuthCalls.Count | Should -Be 1
        $script:graphAuthCalls[0].ParameterSet | Should -Be 'Interactive'
        $script:graphAuthCalls[0].Tenant | Should -Be $TenantId
        $script:graphAuthCalls[0].Scopes | Should -Be $scopes
        $script:graphAuthCalls[0].Keys | Should -Not -Contain 'AccessToken'
        $script:graphAuthCalls[0].NoWelcome | Should -BeTrue
    }
    It 'rejects <Case> before SDK authentication' -ForEach @(
        @{ Case = 'malformed token'; Claims = $null },
        @{ Case = 'wrong tenant'; Claims = @{ tid = '11111111-1111-1111-1111-111111111111' } },
        @{ Case = 'missing tenant'; Claims = @{ role = 'synthetic' } }
    ) {
        $TenantId = '00000000-0000-0000-0000-000000000000'
        $GraphAccessToken = if ($Claims) { Get-TestGraphToken $Claims } else { ConvertTo-SecureString 'synthetic-invalid' -AsPlainText -Force }
        try {
            { & $script:authBranch } | Should -Throw 'Invalid Graph access token or tenant mismatch.'
            $script:graphAuthCalls.Count | Should -Be 0
        }
        finally { $GraphAccessToken.Dispose() }
    }
}
