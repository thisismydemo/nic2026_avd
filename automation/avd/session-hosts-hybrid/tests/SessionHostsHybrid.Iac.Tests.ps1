#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'session-hosts-hybrid IaC contract' {
    BeforeAll {
        $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:bicep = Get-Content -Raw (Join-Path $script:root 'bicep/main.bicep')
        $script:tfMain = Get-Content -Raw (Join-Path $script:root 'terraform/main.tf')
        $script:tfVariables = Get-Content -Raw (Join-Path $script:root 'terraform/variables.tf')
        $script:tfOutputs = Get-Content -Raw (Join-Path $script:root 'terraform/outputs.tf')
        $script:outputs = @(
            'arc_rg_name', 'arc_rg_id', 'hostpool_hybrid_name', 'hostpool_rg',
            'expected_host_names', 'arc_machine_ids', 'ama_extension_ids',
            'dcr_association_ids', 'role_assignment_count'
        )
    }

    It 'declares every manifest output in both implementations' {
        foreach ($outputName in $script:outputs) {
            $script:bicep | Should -Match ('(?m)^output\s+' + [regex]::Escape($outputName) + '\s')
            $script:tfOutputs | Should -Match ('(?m)^output\s+"' + [regex]::Escape($outputName) + '"')
        }
    }

    It 'does not declare script-only secret-reference inputs' {
        foreach ($secretPattern in @('hybrid_local_admin_\w*', 'arc_onboarding_\w*', 'entra_bulk_token')) {
            $script:bicep | Should -Not -Match ('(?m)^param\s+' + $secretPattern + '\s')
            $script:tfVariables | Should -Not -Match ('(?m)^variable\s+"' + $secretPattern + '"')
        }
    }

    It 'contains no unexpected literal GUIDs' {
        $allowed = @(
            '00000000-0000-0000-0000-000000000000',
            'acdd72a7-3385-48ef-bd42-f606fba81ae7',
            'fb879df8-f326-4884-b1cf-06f3ad86be52',
            '1c0163c0-47e6-4577-8991-ea5c82e286e4',
            'b64e21ea-ac4e-4cdf-9dc9-5b892992bee7'
        )
        $files = @('bicep/main.bicep', 'bicep/main.example.bicepparam', 'terraform/versions.tf',
            'terraform/variables.tf', 'terraform/main.tf', 'terraform/outputs.tf',
            'terraform/terraform.example.tfvars.json')
        foreach ($file in $files) {
            $content = Get-Content -Raw (Join-Path $script:root $file)
            $found = [regex]::Matches($content, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')
            foreach ($guid in $found) {
                $allowed | Should -Contain $guid.Value.ToLowerInvariant()
            }
        }
    }

    It 'uses the required Bicep resource API versions' {
        $script:bicep | Should -Match 'Microsoft\.HybridCompute/machines@2025-06-01'
        $script:bicep | Should -Match 'Microsoft\.HybridCompute/machines/extensions@2025-06-01'
        $script:bicep | Should -Match 'Microsoft\.Insights/dataCollectionRuleAssociations@2024-03-11'
        $script:bicep | Should -Match 'Microsoft\.Authorization/roleAssignments@2022-04-01'
        $script:bicep | Should -Match 'Microsoft\.ManagedIdentity/userAssignedIdentities@2024-11-30'
    }

    It 'gates extensions and RBAC in both implementations' {
        $script:bicep | Should -Match 'if\s*\(enable_arc_extensions\)'
        $script:bicep | Should -Match 'if\s*\(manage_arc_rg_rbac\)'
        $script:tfMain | Should -Match 'count\s*=\s*var\.enable_arc_extensions\s*\?'
        $script:tfMain | Should -Match 'role_assignments\s*=\s*var\.manage_arc_rg_rbac\s*\?'
    }
}
