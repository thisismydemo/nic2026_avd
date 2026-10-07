#Requires -Version 7.0
<#
    Pester 5 - manifest / Bicep / Terraform parity for lz-avd (automation/CONTRACT.md sections 2, 6, 10).
    Compares declared inputs, outputs and the names catalog across solution.yml, bicep/main.bicep,
    terraform/variables.tf + outputs.tf and both example files. No Azure call is made.
#>
BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module powershell-yaml -ErrorAction Stop
    $script:manifest = Get-Content -Path (Join-Path $script:root 'solution.yml') -Raw | ConvertFrom-Yaml
    $script:manifestInputs = @($script:manifest.inputs | ForEach-Object { $_.name })
    $script:manifestOutputs = @($script:manifest.outputs | ForEach-Object { $_.name })
    $script:manifestNames = @($script:manifest.names.Keys)

    $bicepMain = Get-Content -Path (Join-Path $script:root 'bicep\main.bicep') -Raw
    $script:bicepParams = @([regex]::Matches($bicepMain, '(?m)^param\s+(\w+)\s') | ForEach-Object { $_.Groups[1].Value })
    $script:bicepOutputs = @([regex]::Matches($bicepMain, '(?m)^output\s+(\w+)\s') | ForEach-Object { $_.Groups[1].Value })
    $script:bicepAll = (Get-ChildItem -Path (Join-Path $script:root 'bicep') -Filter '*.bicep' -Recurse | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"

    $tfVars = Get-Content -Path (Join-Path $script:root 'terraform\variables.tf') -Raw
    $script:tfVariables = @([regex]::Matches($tfVars, '(?m)^variable\s+"(\w+)"') | ForEach-Object { $_.Groups[1].Value })
    $tfOut = Get-Content -Path (Join-Path $script:root 'terraform\outputs.tf') -Raw
    $script:tfOutputs = @([regex]::Matches($tfOut, '(?m)^output\s+"(\w+)"') | ForEach-Object { $_.Groups[1].Value })
    $script:tfAll = (Get-ChildItem -Path (Join-Path $script:root 'terraform') -Filter '*.tf' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"

    $script:tfExample = Get-Content -Path (Join-Path $script:root 'terraform\terraform.example.tfvars.json') -Raw | ConvertFrom-Json -AsHashtable
    $bicepExample = Get-Content -Path (Join-Path $script:root 'bicep\main.example.bicepparam') -Raw
    $script:bicepExampleParams = @([regex]::Matches($bicepExample, '(?m)^param\s+(\w+)\s*=') | ForEach-Object { $_.Groups[1].Value })
}

Describe 'manifest shape (contract section 2)' {
    It 'has the required top-level keys' {
        foreach ($k in 'name', 'description', 'scope', 'tools', 'depends_on', 'inputs', 'outputs', 'secrets', 'destroy', 'names') { $script:manifest.Keys | Should -Contain $k }
        $script:manifest.name | Should -Be 'lz-avd'
        $script:manifest.depends_on | Should -Contain 'lz-azure-local'
        $script:manifest.tools | Should -Be @('bicep', 'terraform')
        $script:manifest.destroy | Should -Be 'supported'
    }

    It 'declares type, description, required, default and source for every input' {
        foreach ($i in $script:manifest.inputs) {
            foreach ($k in 'name', 'type', 'description', 'required', 'source') { $i.Keys | Should -Contain $k -Because "input $($i.name)" }
            $i.type | Should -BeIn @('string', 'int', 'bool', 'list', 'map', 'secret-ref')
            $i.source | Should -BeIn @('environment', 'keyvault', 'generated')
        }
    }

    It 'has no default that looks like a tenant, subscription, IP or GUID value' {
        foreach ($i in $script:manifest.inputs) {
            $d = if ($i.Contains('default')) { "$($i['default'])" } else { '' }
            $d | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
            $d | Should -Not -Match '\d+\.\d+\.\d+\.\d+'
        }
    }
}

Describe 'inputs parity' {
    It 'Bicep params equal the manifest inputs' {
        Compare-Object -ReferenceObject $script:manifestInputs -DifferenceObject $script:bicepParams | Should -BeNullOrEmpty
    }
    It 'Terraform variables equal the manifest inputs' {
        Compare-Object -ReferenceObject $script:manifestInputs -DifferenceObject $script:tfVariables | Should -BeNullOrEmpty
    }
    It 'both example files set every manifest input' {
        Compare-Object -ReferenceObject $script:manifestInputs -DifferenceObject @($script:tfExample.Keys) | Should -BeNullOrEmpty
        Compare-Object -ReferenceObject $script:manifestInputs -DifferenceObject $script:bicepExampleParams | Should -BeNullOrEmpty
    }
}

Describe 'outputs parity (contract section 6)' {
    It 'Bicep outputs equal the manifest outputs' {
        Compare-Object -ReferenceObject $script:manifestOutputs -DifferenceObject $script:bicepOutputs | Should -BeNullOrEmpty
    }
    It 'Terraform outputs equal the manifest outputs' {
        Compare-Object -ReferenceObject $script:manifestOutputs -DifferenceObject $script:tfOutputs | Should -BeNullOrEmpty
    }
}

Describe 'names catalog (contract section 10, naming standard)' {
    It 'every catalog key is consumed by both tracks and present in both example files' {
        foreach ($key in $script:manifestNames) {
            $script:bicepAll | Should -Match "names\.$key\b" -Because "bicep must reference names.$key"
            $script:tfAll | Should -Match "names\[`"$key`"\]" -Because "terraform must reference names[`"$key`"]"
            $script:tfExample.names.Keys | Should -Contain $key
        }
    }

    It 'IaC never builds a resource name from org/lab_token/location_short' {
        $script:bicepAll | Should -Not -Match "'\$\{org\}-|\$\{lab_token\}|\$\{location_short\}"
        $script:tfAll | Should -Not -Match '\$\{var\.org\}-|\$\{var\.lab_token\}|\$\{var\.location_short\}'
    }

    It 'rendered names (example tfvars = the expected catalog output) follow the naming standard' {
        foreach ($key in $script:manifestNames) {
            $entry = $script:manifest.names[$key]
            $expected = $script:tfExample.names[$key]
            $expected | Should -Not -BeNullOrEmpty
            if ($entry.type -eq 'pdnszone') {
                # Azure-fixed zone names are exempt from the token rule (naming standard 3b) and pass through 'name'
                $expected | Should -Be $entry.name
                continue
            }
            $expected | Should -Match 'nic26' -Because "$key must carry the lab token (D-005)"
            $expected | Should -Match 'iic' -Because "$key must carry the org token (D-006)"
            switch ($entry.type) {
                'st' { $expected | Should -Match '^[a-z0-9]{3,24}$' }
                'gal' { $expected | Should -Match '^[a-zA-Z0-9._]+$' }
                'rg' { $expected.Length | Should -BeLessOrEqual 90 }
                'vnet' { $expected.Length | Should -BeLessOrEqual 64 }
                'snet' { $expected | Should -Match '^snet-iic-nic26-[a-z]+$' }
                'nsg' { $expected | Should -Match '^nsg-iic-nic26-.+-eus-\d{2}$' }
                'id' { $expected.Length | Should -BeGreaterOrEqual 3; $expected.Length | Should -BeLessOrEqual 128 }
                'rsv' { $expected.Length | Should -BeGreaterOrEqual 2; $expected.Length | Should -BeLessOrEqual 50 }
                default { $expected.Length | Should -BeLessOrEqual 80 }
            }
        }
    }

    It 'both example files render the same name for every key' {
        $bicepExample = Get-Content -Path (Join-Path $script:root 'bicep\main.example.bicepparam') -Raw
        foreach ($key in $script:manifestNames) {
            $bicepExample | Should -Match ("(?m)^\s+$key`: '" + [regex]::Escape($script:tfExample.names[$key]) + "'\r?$") -Because "bicepparam names.$key must equal the tfvars value"
        }
    }

    It 'storage account and gallery names have no hyphens; everything else is lowercase kebab' {
        $script:tfExample.names.fslogix_sa | Should -Not -Match '-'
        $script:tfExample.names.gallery | Should -Not -Match '-'
        foreach ($key in $script:manifestNames) { $script:tfExample.names[$key] | Should -Match '^[a-z0-9.-]+$' }
    }

    It 'every catalog entry uses a type the naming registry knows (when the shared module is present)' {
        $modulePath = Join-Path $script:root '..\..\shared\powershell\NIC26.Automation\NIC26.Automation.psd1'
        if (-not (Test-Path $modulePath)) { Set-ItResult -Skipped -Because 'NIC26.Automation not built yet'; return }
        Import-Module $modulePath -Force
        $registryFile = Join-Path $script:root '..\..\shared\powershell\NIC26.Automation\Private\Get-NIC26NameRegistry.ps1'
        $known = @([regex]::Matches((Get-Content $registryFile -Raw), "Type = '([a-z]+)'") | ForEach-Object { $_.Groups[1].Value })
        $unknown = @($script:manifestNames | Where-Object { $known -notcontains $script:manifest.names[$_].type } | ForEach-Object { "$_ ($($script:manifest.names[$_].type))" })
        # 'role' (custom RBAC role definition) is a documented, pending registry addition (README "Open items").
        $pendingTypes = @('role')
        $unexpected = @($unknown | Where-Object { $_ -notmatch ('\((' + ($pendingTypes -join '|') + ')\)$') })
        $unexpected | Should -BeNullOrEmpty -Because 'the converter fails on unknown types; ask the module owner to add them'
        if ($unknown.Count -gt 0) { Set-ItResult -Skipped -Because "awaiting naming-registry type(s): $($unknown -join ', ')" }
    }
}

Describe 'no secret lookups in IaC (contract section 3)' {
    It 'Bicep has no getSecret / listKeys and Terraform no key vault secret data source' {
        $script:bicepAll | Should -Not -Match 'getSecret\(|listKeys\('
        $script:tfAll | Should -Not -Match 'data\s+"azurerm_key_vault_secret"'
    }
    It 'Terraform backend carries no values' {
        $versions = Get-Content -Path (Join-Path $script:root 'terraform\versions.tf') -Raw
        $versions | Should -Match 'backend "azurerm" \{\}'
    }
}
