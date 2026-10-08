#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
BeforeAll {
    Import-Module powershell-yaml -ErrorAction Stop
    $root = Resolve-Path (Join-Path $PSScriptRoot '../../..')
    $script:SchemaFile = Join-Path $root 'shared/schemas/avd.environment.schema.json'
    $script:Example = Get-Content (Join-Path $root 'shared/examples/environment.avd.example.yml') -Raw | ConvertFrom-Yaml
}
Describe 'Dedicated jump admin host prefix contract' {
    It 'accepts a documentation IPv4 host prefix in the complete AVD example' {
        $script:Example.jump_admin_source_prefix | Should -Be '192.0.2.10/32'
        ($script:Example | ConvertTo-Json -Depth 50 | Test-Json -SchemaFile $script:SchemaFile -ErrorAction SilentlyContinue) | Should -BeTrue
    }
    It 'rejects an entire subnet instead of the dedicated host' {
        $candidate = $script:Example.Clone()
        $candidate.jump_admin_source_prefix = '192.0.2.0/24'
        ($candidate | ConvertTo-Json -Depth 50 | Test-Json -SchemaFile $script:SchemaFile -ErrorAction SilentlyContinue) | Should -BeFalse
    }
    It 'rejects an invalid IPv4 host' {
        $candidate = $script:Example.Clone()
        $candidate.jump_admin_source_prefix = (('999', '0', '2', '10') -join '.') + '/32'
        ($candidate | ConvertTo-Json -Depth 50 | Test-Json -SchemaFile $script:SchemaFile -ErrorAction SilentlyContinue) | Should -BeFalse
    }
    It 'rejects IPv6 for this IPv4 admin-source contract' {
        $candidate = $script:Example.Clone()
        $candidate.jump_admin_source_prefix = '2001:db8::10/32'
        ($candidate | ConvertTo-Json -Depth 50 | Test-Json -SchemaFile $script:SchemaFile -ErrorAction SilentlyContinue) | Should -BeFalse
    }
    It 'requires an explicit admin source instead of falling back to the workload spoke' {
        $candidate = $script:Example.Clone()
        $candidate.Remove('jump_admin_source_prefix')
        ($candidate | ConvertTo-Json -Depth 50 | Test-Json -SchemaFile $script:SchemaFile -ErrorAction SilentlyContinue) | Should -BeFalse
    }
}
