#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test fixture only.')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:packerDirectory = Join-Path $script:root 'packer'
    $script:buildScript = Join-Path $script:root 'scripts/Invoke-PackerBuild.ps1'

    # Packer and the NIC26 module are not needed: the external calls are seams that the tests replace.
    function global:Test-PackerInstalled { return $true }
    function global:Invoke-PackerCommand { param([string[]]$Arguments, [string]$WorkingDirectory, [hashtable]$Environment) }
    function global:Resolve-NIC26KeyVaultRef { param([string]$Ref, [switch]$AsPlainText) }
}

AfterAll {
    foreach ($name in @('Test-PackerInstalled', 'Invoke-PackerCommand', 'Resolve-NIC26KeyVaultRef')) {
        Remove-Item "Function:\global:$name" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name PackerEvents, PackerEnvironment -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Hyper-V Packer files' {
    It 'includes every solution file' {
        foreach ($relativePath in @('solution.yml', 'packer/windows11-hyperv.pkr.hcl', 'packer/variables.pkr.hcl',
                'packer/windows11.auto.pkrvars.example.json', 'packer/templates/autounattend.xml.tpl',
                'scripts/Invoke-PackerBuild.ps1', 'README.md')) {
            Join-Path $script:root $relativePath | Should -Exist
        }
    }

    It 'declares the solution contract' {
        $text = Get-Content (Join-Path $script:root 'solution.yml') -Raw
        foreach ($value in @('name: avd-images-packer-hyperv', 'depends_on: [lz-azure-local]', 'hybrid_image_vhdx_path',
                'image_manifest_path', 'secrets: [avd-image-build-admin]', 'destroy: supported', 'build_vm:')) {
            $text | Should -Match ([regex]::Escape($value))
        }
    }

    It 'has the plugin, the builder settings and a sensitive password without default' {
        $hcl = Get-Content (Join-Path $script:packerDirectory 'windows11-hyperv.pkr.hcl') -Raw
        $vars = Get-Content (Join-Path $script:packerDirectory 'variables.pkr.hcl') -Raw
        $hcl | Should -Match 'required_plugins'
        $hcl | Should -Match 'github.com/hashicorp/hyperv'
        $hcl | Should -Match 'source\s+"hyperv-iso"'
        $hcl | Should -Match 'generation\s*=\s*2'
        $hcl | Should -Match 'enable_secure_boot\s*=\s*true'
        $hcl | Should -Match 'enable_tpm\s*=\s*true'
        $hcl | Should -Match 'communicator\s*=\s*"winrm"'
        $vars | Should -Match 'variable "build_password"\s*\{[^}]*sensitive\s*=\s*true'
        $vars | Should -Not -Match 'variable "build_password"\s*\{[^}]*default'
    }

    It 'has no literal GUID, IP address, UNC or drive path in the HCL' {
        $text = ((Get-Content (Join-Path $script:packerDirectory 'windows11-hyperv.pkr.hcl') -Raw) + "`n" +
            (Get-Content (Join-Path $script:packerDirectory 'variables.pkr.hcl') -Raw))
        # The documented sysprep default is a fixed Windows system path, not an environment value.
        $text = ($text -split "`n" | Where-Object { $_ -notmatch 'sysprep\.exe' }) -join "`n"
        $text | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $text | Should -Not -Match '\b\d{1,3}(?:\.\d{1,3}){3}\b'
        $text | Should -Not -Match '\\\\[A-Za-z]'
        $text | Should -Not -Match '[A-Za-z]:\\'
    }

    It 'references the six real customizer files in order' {
        $hcl = Get-Content (Join-Path $script:packerDirectory 'windows11-hyperv.pkr.hcl') -Raw
        $names = @('01-Install-Fslogix.ps1', '02-Install-TeamsWebRtc.ps1', '03-Set-ShortpathListener.ps1',
            '04-Set-DefenderExclusions.ps1', '05-Invoke-Vdot.ps1', '06-Copy-ArcAgent.ps1')
        $positions = @($names | ForEach-Object { $hcl.IndexOf($_) })
        foreach ($position in $positions) { $position | Should -BeGreaterThan -1 }
        ($positions -join ',') | Should -Be (($positions | Sort-Object) -join ',')
        foreach ($name in $names) {
            Join-Path $script:root "../shared/customizers/$name" | Should -Exist
        }
    }

    It 'renders every token the referenced customizers use' {
        $hcl = Get-Content (Join-Path $script:packerDirectory 'windows11-hyperv.pkr.hcl') -Raw
        foreach ($name in (Get-ChildItem (Join-Path $script:root '../shared/customizers') -Filter '*.ps1').Name) {
            $text = Get-Content (Join-Path $script:root "../shared/customizers/$name") -Raw
            foreach ($token in @([regex]::Matches($text, '\{\{[a-z_]+\}\}') | ForEach-Object Value | Select-Object -Unique)) {
                $hcl | Should -Match ([regex]::Escape($token))
            }
        }
    }

    It 'renders valid unattend XML with complete component identities and no deprecated OOBE skip' {
        $template = Get-Content (Join-Path $script:packerDirectory 'templates/autounattend.xml.tpl') -Raw
        $template | Should -Not -Match 'SkipMachineOOBE'
        $rendered = $template -replace '(?s)%\{ if product_key != "" ~\}.*?%\{ endif ~\}', ''
        $rendered = $rendered.Replace('${build_username}', 'builder').Replace('${build_password}', 'placeholder')
        $xml = [xml]$rendered
        $components = $xml.SelectNodes("//*[local-name()='component']")
        $components.Count | Should -BeGreaterThan 0
        foreach ($component in $components) {
            foreach ($attribute in @('processorArchitecture', 'publicKeyToken', 'language', 'versionScope')) {
                $component.GetAttribute($attribute) | Should -Not -BeNullOrEmpty
            }
        }
    }
}

Describe 'Invoke-PackerBuild' {
    BeforeEach {
        $global:PackerEvents = [System.Collections.Generic.List[string]]::new()
        $global:PackerEnvironment = @{}
        $output = Join-Path $TestDrive 'output'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        $script:fakeVhdx = Join-Path $output 'artifact.vhdx'
        [System.IO.File]::WriteAllBytes($script:fakeVhdx, [byte[]]@(1, 2, 3, 4))
        $script:varFile = Join-Path $TestDrive 'variables.json'
        @{ build_username = 'builder'; output_directory = $output } | ConvertTo-Json | Set-Content -LiteralPath $script:varFile
        $script:manifestPath = Join-Path $TestDrive 'result.json'
        Remove-Item -LiteralPath $script:manifestPath -ErrorAction SilentlyContinue
        $script:parameters = @{
            PackerDirectory  = $script:packerDirectory
            VarFile          = $script:varFile
            BuildPasswordRef = 'keyvault://kv-test/test-reference'
            BuildUsername    = 'builder'
            ManifestPath     = $script:manifestPath
        }
        Mock Test-PackerInstalled { $global:PackerEvents.Add('installed'); return $true }
        Mock Resolve-NIC26KeyVaultRef {
            $global:PackerEvents.Add('resolve')
            return (ConvertTo-SecureString 'TEST-PASSWORD' -AsPlainText -Force)
        }
        Mock Invoke-PackerCommand {
            $global:PackerEvents.Add($Arguments[0])
            $global:PackerEnvironment[$Arguments[0]] = @{
                Password  = $Environment['PKR_VAR_build_password']
                Arguments = @($Arguments)
            }
            if ($Arguments[0] -eq 'version') {
                return @{ ExitCode = 0; StdOut = "Packer v1.11.2`n"; StdErr = '' }
            }
            return @{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }
    }

    It 'resolves nothing and runs nothing in plan mode' {
        $plan = @(& $script:buildScript @script:parameters)
        $plan[0] | Should -Match '^Plan:'
        $global:PackerEvents.Count | Should -Be 0
    }

    It 'runs init, validate and build with a child-only password and writes a hash manifest' {
        $streams = & $script:buildScript @script:parameters -Execute -InformationAction Continue -Verbose *>&1 | Out-String
        $streams | Should -Not -Match 'TEST-PASSWORD'
        ($global:PackerEvents -join ',') | Should -Be 'installed,version,resolve,init,validate,build'
        foreach ($step in @('init', 'validate', 'build')) {
            $global:PackerEnvironment[$step].Password | Should -Be 'TEST-PASSWORD'
            ($global:PackerEnvironment[$step].Arguments -join ' ') | Should -Not -Match 'TEST-PASSWORD'
        }
        ($global:PackerEnvironment['init'].Arguments -join ' ') | Should -Not -Match 'var-file'
        ($global:PackerEnvironment['validate'].Arguments -join ' ') | Should -Match 'var-file'
        $global:PackerEnvironment['version'].Password | Should -BeNullOrEmpty
        $manifest = Get-Content $script:manifestPath -Raw | ConvertFrom-Json
        $manifest.vhdx_path | Should -Be $script:fakeVhdx
        $manifest.sha256 | Should -Be (Get-FileHash $script:fakeVhdx -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest.packer_version | Should -Be 'Packer v1.11.2'
        (Get-Content $script:manifestPath -Raw) | Should -Not -Match 'TEST-PASSWORD'
    }

    It 'withholds Packer output when a step fails' {
        Mock Invoke-PackerCommand {
            if ($Arguments[0] -eq 'version') { return @{ ExitCode = 0; StdOut = 'Packer v1'; StdErr = '' } }
            return @{ ExitCode = 1; StdOut = 'LEAK-FROM-PACKER'; StdErr = 'LEAK-FROM-PACKER' }
        }
        $caught = $null
        try { & $script:buildScript @script:parameters -Execute } catch { $caught = $_.ToString() }
        $caught | Should -Match 'output was withheld'
        $caught | Should -Not -Match 'LEAK-FROM-PACKER'
    }

    It 'refuses to overwrite an existing manifest' {
        Set-Content -LiteralPath $script:manifestPath -Value 'existing'
        { & $script:buildScript @script:parameters -Execute } | Should -Throw '*already exists*'
        $global:PackerEvents.Count | Should -Be 0
    }

    It 'reports a missing Packer installation' {
        Mock Test-PackerInstalled { return $false }
        { & $script:buildScript @script:parameters -Execute } | Should -Throw '*Packer is not installed*'
        $global:PackerEvents.Count | Should -Be 0
    }

    It 'refuses a variable file that carries a build password' {
        @{ build_username = 'builder'; build_password = 'x'; output_directory = $TestDrive } | ConvertTo-Json | Set-Content -LiteralPath $script:varFile
        { & $script:buildScript @script:parameters -Execute } | Should -Throw '*must not contain a build password*'
    }
}
