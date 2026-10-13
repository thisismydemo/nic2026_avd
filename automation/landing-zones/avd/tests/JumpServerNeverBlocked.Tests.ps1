#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# D-056 (owner, 12 Oct 2026): the jump server is never blocked. Every AVD landing-zone NSG carries AllowJumpServerInbound
# (priority 101, inbound, allow, all protocols and ports, source jump_admin_source_prefix) in both IaC tracks.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    $script:Bicep = Get-Content (Join-Path $root 'bicep/modules/network.bicep') -Raw
    $script:Main = Get-Content (Join-Path $root 'bicep/main.bicep') -Raw
    $script:Tf = Get-Content (Join-Path $root 'terraform/main.tf') -Raw
}
Describe 'Jump server never blocked on the AVD NSGs (D-056)' {
    It 'Bicep defines the rule with the live fields' {
        $script:Bicep | Should -Match "name: 'AllowJumpServerInbound'\s+properties: \{\s+priority: 101\s+direction: 'Inbound'\s+access: 'Allow'\s+protocol: '\*'\s+sourceAddressPrefix: jump_server_source_prefix\s+sourcePortRange: '\*'\s+destinationAddressPrefix: '\*'\s+destinationPortRange: '\*'\s+description: 'Jump server is never blocked \(owner, 12 Oct 2026\)'"
    }
    It 'Bicep puts the rule first on all three NSGs (hosts, private endpoint, image build)' {
        ([regex]::Matches($script:Bicep, 'securityRules: \[\s+jumpServerRule\s')).Count | Should -Be 3
        ([regex]::Matches($script:Bicep, "module nsg\w+ 'br/public:avm/res/network/network-security-group")).Count | Should -Be 3
    }
    It 'main.bicep feeds the rule from the jump admin host prefix' {
        $script:Main | Should -Match 'jump_server_source_prefix: jump_admin_source_prefix'
    }
    It 'Terraform mirrors the rule on all three NSG modules' {
        $pattern = 'jump_server_in = \{\s+name\s+= "AllowJumpServerInbound"\s+priority\s+= 101\s+direction\s+= "Inbound"\s+access\s+= "Allow"\s+protocol\s+= "\*"\s+source_address_prefix\s+= var\.jump_admin_source_prefix\s+source_port_range\s+= "\*"\s+destination_address_prefix = "\*"\s+destination_port_range\s+= "\*"\s+description\s+= "Jump server is never blocked \(owner, 12 Oct 2026\)"'
        ([regex]::Matches($script:Tf, $pattern)).Count | Should -Be 3
        ([regex]::Matches($script:Tf, 'source\s+= "Azure/avm-res-network-networksecuritygroup/azurerm"')).Count | Should -Be 3
    }
    It 'priority 101 is not used by any other inbound rule in either track' {
        ([regex]::Matches($script:Bicep, 'priority: 101\b')).Count | Should -Be 1
        ([regex]::Matches($script:Tf, 'priority\s+= 101\b')).Count | Should -Be 3
    }
}
