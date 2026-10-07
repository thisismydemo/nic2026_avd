#Requires -Version 7.0
<#
    Pester 5 - IaC gates for lz-avd (automation/CONTRACT.md section 8): az bicep build on every .bicep and the example
    .bicepparam with 0 errors and 0 warnings; terraform fmt -check, init -backend=false, validate.
    Needs az (with bicep) and terraform on PATH; module restore needs internet (mcr.microsoft.com, registry.terraform.io).
#>
BeforeDiscovery {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:bicepFiles = @(Get-Item (Join-Path $script:root 'bicep\main.bicep')) + @(Get-ChildItem -Path (Join-Path $script:root 'bicep\modules') -Filter '*.bicep')
    $script:hasAz = [bool](Get-Command az -ErrorAction SilentlyContinue)
    $script:hasTerraform = [bool](Get-Command terraform -ErrorAction SilentlyContinue)
}

Describe 'Bicep build' -Skip:(-not $hasAz) -ForEach ($bicepFiles | ForEach-Object { @{ File = $_ } }) {
    It '<File.Name> builds with 0 errors and 0 warnings' {
        $out = & az bicep build --file $File.FullName --stdout 2>&1 | ForEach-Object { "$_" }
        $diag = @($out | Where-Object { $_ -match ': (Error|Warning) ' } | Sort-Object -Unique)
        $diag -join "`n" | Should -BeNullOrEmpty
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Bicep example parameters' -Skip:(-not $hasAz) {
    It 'main.example.bicepparam builds against main.bicep' {
        $file = Join-Path (Split-Path -Parent $PSScriptRoot) 'bicep\main.example.bicepparam'
        $out = & az bicep build-params --file $file --stdout 2>&1 | ForEach-Object { "$_" }
        @($out | Where-Object { $_ -match ': Error ' }) -join "`n" | Should -BeNullOrEmpty
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Terraform' -Skip:(-not $hasTerraform) {
    BeforeAll {
        $script:tfDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'terraform'
        Push-Location $script:tfDir
    }
    AfterAll { Pop-Location }

    It 'terraform fmt -check passes' {
        $out = & terraform fmt -check -recursive 2>&1 | ForEach-Object { "$_" }
        $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
    }

    It 'terraform init -backend=false succeeds' {
        $out = & terraform init -backend=false -input=false -no-color 2>&1 | ForEach-Object { "$_" }
        $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
    }

    It 'terraform validate succeeds' {
        $out = & terraform validate -no-color 2>&1 | ForEach-Object { "$_" }
        $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
        ($out -join "`n") | Should -Match 'Success'
    }
}
