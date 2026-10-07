#Requires -Version 7.0
<#
    Pester 5 - owner decision D-029 (no private endpoints): the switch exists in every track, defaults to off,
    and the examples ship with it off. Static checks; no Azure call.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester 5: BeforeAll variables are consumed inside It blocks.')]
param()

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    function Get-Text([string]$relative) { Get-Content -LiteralPath (Join-Path $script:root $relative) -Raw }
}

Describe 'enable_private_endpoints switch (D-029) in lz-avd' {
    It 'is declared in Bicep and Terraform with default false' {
        (Get-Text 'bicep\main.bicep') | Should -Match "param enable_private_endpoints bool = false"
        (Get-Text 'terraform\variables.tf') | Should -Match 'variable "enable_private_endpoints"[\s\S]*?default\s*=\s*false'
    }
    It 'gates the private endpoint, the zone and the public access setting' {
        $storage = Get-Text 'bicep\modules\storage.bicep'
        $storage | Should -Match "publicNetworkAccess: enable_private_endpoints \? 'Disabled' : 'Enabled'"
        $storage | Should -Match 'privateEndpoints: !enable_private_endpoints \? \[\]'
        (Get-Text 'bicep\main.bicep') | Should -Match 'createFileZone = enable_private_endpoints'
        $tf = Get-Text 'terraform\main.tf'
        $tf | Should -Match 'public_network_access_enabled\s*=\s*!var\.enable_private_endpoints'
        $tf | Should -Match 'create_file_zone = var\.enable_private_endpoints'
    }
    It 'ships the examples with private endpoints off' {
        (Get-Text 'bicep\main.example.bicepparam') | Should -Match 'param enable_private_endpoints = false'
        (Get-Text 'terraform\terraform.example.tfvars.json') | Should -Match '"enable_private_endpoints":\s*false'
    }
}
