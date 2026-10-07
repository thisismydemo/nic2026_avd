#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -ForEach data must exist at discovery time, so it is built here and not in BeforeAll.
$customizerDirectory = Join-Path $PSScriptRoot '../customizers'
$customizerCases = @(Get-ChildItem -LiteralPath $customizerDirectory -Filter '*.ps1' | Sort-Object Name |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })

BeforeAll {
    $script:customizerDirectory = Join-Path $PSScriptRoot '../customizers'
    $script:readme = Get-Content -LiteralPath (Join-Path $script:customizerDirectory 'README.md') -Raw
    $script:allowedUrls = @(
        'https://aka.ms/fslogix_download'
        'https://aka.ms/msrdcwebrtcsvc/msi'
        'https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409'
    )
}

Describe 'Shared image customizers' {
    It 'contains the six numbered scripts' {
        @(Get-ChildItem -LiteralPath $script:customizerDirectory -Filter '*.ps1').Count | Should -Be 6
    }

    It 'parses <Name> and applies strict error handling' -ForEach $customizerCases {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
    }

    It 'embeds no deployment-specific value in <Name>' -ForEach $customizerCases {
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Not -Match 'file\.core\.windows\.net'
        $text | Should -Not -Match '(?i)password|credential'
        if ($Name -ne '04-Set-DefenderExclusions.ps1') {
            $text | Should -Not -Match "StartsWith\('\\\\\\\\'\)"
        }
    }

    It 'uses only the verified URL literals and documents every token in <Name>' -ForEach $customizerCases {
        $text = Get-Content -LiteralPath $Path -Raw
        foreach ($url in @([regex]::Matches($text, 'https?://[^\s''"]+') | ForEach-Object Value)) {
            $script:allowedUrls | Should -Contain $url
        }

        foreach ($token in @([regex]::Matches($text, '\{\{[a-z_]+\}\}') | ForEach-Object Value | Select-Object -Unique)) {
            $script:readme | Should -Match ([regex]::Escape($token))
        }
    }

    It 'renders tokens and the result still parses' {
        $path = Join-Path $script:customizerDirectory '03-Set-ShortpathListener.ps1'
        $rendered = (Get-Content -LiteralPath $path -Raw).Replace('{{shortpath_port}}', '3390')
        $rendered | Should -Not -Match '\{\{shortpath_port\}\}'
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($rendered, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'rejects an out-of-range Shortpath port when run' {
        $path = Join-Path $script:customizerDirectory '03-Set-ShortpathListener.ps1'
        $rendered = (Get-Content -LiteralPath $path -Raw).Replace('{{shortpath_port}}', '80')
        { & ([scriptblock]::Create($rendered)) } | Should -Throw '*1024 through 65535*'
    }
}
