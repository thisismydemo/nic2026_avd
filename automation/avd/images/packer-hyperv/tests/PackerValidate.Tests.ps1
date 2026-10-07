#Requires -Version 7.0
# Pester 5 - defects that only a real `packer validate` finds (review R-39): an unknown HCL function and Packer's own template
# engine seeing the literal double braces in the customizers. The validate test runs only when packer is on PATH.
BeforeDiscovery {
    $script:hasPacker = [bool](Get-Command packer -ErrorAction SilentlyContinue)
}
BeforeAll {
    $script:hcl = Join-Path $PSScriptRoot '..\packer\windows11-hyperv.pkr.hcl'
    $script:text = Get-Content -LiteralPath $script:hcl -Raw
}
Describe 'Packer template regressions' {
    It 'uses no function Packer HCL does not have (tostring)' {
        $script:text | Should -Not -Match '\btostring\('
    }
    It 'escapes literal double braces in every inline customizer' {
        foreach ($n in '01', '02', '03', '04', '05', '06') {
            $script:text | Should -Match ([regex]::Escape("replace(local.rendered_$n, `"{{`", `"{{ \`"{{\`" }}`")"))
        }
    }
    It 'passes packer validate with the example variables and the real customizers' -Skip:(-not $script:hasPacker) {
        Push-Location (Split-Path $script:hcl)
        try {
            $customizers = (Resolve-Path '..\..\shared\customizers').Path
            $null = & packer init . 2>&1
            $output = & packer validate '-var-file=windows11.auto.pkrvars.example.json' '-var' 'build_password=Example-Only-1!' '-var' "customizer_directory=$customizers" . 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        }
        finally { Pop-Location }
    }
}
