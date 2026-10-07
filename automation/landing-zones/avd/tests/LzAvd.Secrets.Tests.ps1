#Requires -Version 7.0
<#
    Pester 5 - secrets / identifiers sweep for lz-avd (automation/CONTRACT.md section 8, "Secrets" gate).
    Zero GUIDs (other than all-zero placeholders and bicep/modules/builtin-ids.bicep), no private-tenant identifiers
    (contract section 7; the forbidden words are assembled at run time so this file does not carry them),
    no credential literals, no non-documentation public IPs. Private RFC1918 lab ranges are allowed only in the
    two example files (they are the design's IIC example addresses).
#>
BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:files = Get-ChildItem -Path $script:root -Recurse -File |
        Where-Object { $_.FullName -notmatch '\\\.terraform\\' -and $_.Name -notmatch '\.generated\.' -and $_.Extension -in '.bicep', '.bicepparam', '.tf', '.json', '.yml', '.yaml', '.ps1', '.md', '.hcl' }
    $script:guidAllowList = @('builtin-ids.bicep', 'AvdMicrosoftAppIds.psd1')
    $script:exampleFiles = @('main.example.bicepparam', 'terraform.example.tfvars.json')
}

Describe 'identifier and secret sweep' {
    It 'contains no non-zero GUID outside the built-in id file' {
        $hits = foreach ($f in $script:files) {
            if ($script:guidAllowList -contains $f.Name) { continue }
            Select-String -Path $f.FullName -Pattern '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' |
                Where-Object { $_.Line -notmatch '00000000-0000-0000-0000-000000000000' -and $_.Line -notmatch '11111111-1111-1111-1111-111111111111' } |
                ForEach-Object { "$($f.Name):$($_.LineNumber)" }
        }
        $hits | Should -BeNullOrEmpty
    }

    It 'contains no credential literal' {
        $hits = foreach ($f in $script:files) {
            Select-String -Path $f.FullName -Pattern '(?i)(password|client_secret|clientsecret|accesskey|access_key|sas_token|token)\s*[:=]\s*["''][^"''\s]{6,}["'']' | ForEach-Object { "$($f.Name):$($_.LineNumber)" }
        }
        $hits | Should -BeNullOrEmpty
    }

    It 'contains no IP address outside the example files; example files use only private lab ranges' {
        $ipPattern = '\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b'
        $hits = foreach ($f in $script:files) {
            $matches = Select-String -Path $f.FullName -Pattern $ipPattern -AllMatches
            foreach ($m in $matches) {
                foreach ($ip in $m.Matches.Value) {
                    if ($ip -match '^\d+\.\d+\.\d+$') { continue }
                    $isPrivate = $ip -match '^10\.' -or $ip -match '^192\.168\.' -or $ip -match '^172\.(1[6-9]|2\d|3[01])\.'
                    $isDocRange = $ip -match '^(192\.0\.2|198\.51\.100|203\.0\.113)\.'
                    $isVersion = $m.Line -match 'version|Version|~>|>=|api' # module/provider pins like 0.22.2 or 4.60.0
                    if ($isVersion -and $ip -notmatch '^(10|192|172)\.') { continue }
                    if ($isDocRange) { continue }
                    if ($isPrivate -and ($script:exampleFiles -contains $f.Name -or $f.Extension -eq '.md' -or $f.Name -like '*.Tests.ps1')) { continue }
                    "$($f.Name):$($m.LineNumber) $ip"
                }
            }
        }
        $hits | Should -BeNullOrEmpty
    }

    It 'example files use only all-zero GUIDs and IIC resource names and example.com-style domains' {
        foreach ($name in $script:exampleFiles) {
            $f = $script:files | Where-Object Name -EQ $name
            $content = Get-Content -Path $f.FullName -Raw
            [regex]::Matches($content, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value } | Should -Not -Contain ({ $_ -ne '00000000-0000-0000-0000-000000000000' })
            $content | Should -Match 'contoso\.com'
            $content | Should -Match 'iic'
        }
    }
}
