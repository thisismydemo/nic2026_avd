#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stubs mirror the real cmdlet signatures.')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:azureRoot = Join-Path $PSScriptRoot '..'
    $script:manifest = Get-Content -LiteralPath (Join-Path $script:azureRoot 'solution.yml') -Raw
    $script:bicep = Get-Content -LiteralPath (Join-Path $script:azureRoot 'bicep/main.bicep') -Raw
    $script:terraform = Get-Content -LiteralPath (Join-Path $script:azureRoot 'terraform/main.tf') -Raw
    $script:terraformVariables = Get-Content -LiteralPath (Join-Path $script:azureRoot 'terraform/variables.tf') -Raw
    $script:versionScript = Join-Path $script:azureRoot 'scripts/Get-PlatformImageVersion.ps1'
    $script:buildScript = Join-Path $script:azureRoot 'scripts/Start-ImageBuild.ps1'

    # Real Az cmdlets are used when installed (Mock follows their signatures); otherwise stubs with the same parameters.
    if (-not (Get-Command Get-AzVMImage -ErrorAction SilentlyContinue)) {
        function Get-AzVMImage { param([string]$Location, [string]$PublisherName, [string]$Offer, [string]$Skus, [string]$Version, [int]$Top, [string]$Orderby) }
    }
    if (-not (Get-Command Invoke-AzResourceAction -ErrorAction SilentlyContinue)) {
        function Invoke-AzResourceAction {
            [CmdletBinding(SupportsShouldProcess)]
            param([string]$ResourceGroupName, [string]$ResourceType, [string]$ResourceName, [string]$ApiVersion, [string]$Action, [object]$Parameters, [switch]$Force, [string]$ResourceId)
        }
    }
    if (-not (Get-Command Get-AzResource -ErrorAction SilentlyContinue)) {
        function Get-AzResource { param([string]$ResourceGroupName, [string]$ResourceType, [string]$Name, [switch]$ExpandProperties) }
    }
    if (-not (Get-Command Set-AzContext -ErrorAction SilentlyContinue)) {
        function Set-AzContext { param([string]$SubscriptionId) }
    }
    if (-not (Get-Command Start-ImageBuildSleep -ErrorAction SilentlyContinue)) {
        function Start-ImageBuildSleep { param([int]$Seconds) }
    }
}

Describe 'Image solution contracts' {
    It 'declares the names and outputs' {
        foreach ($name in @('it_azure', 'it_azl', 'runout_azure', 'runout_azl_gallery', 'runout_azl_vhd', 'deployment_name')) {
            $script:manifest | Should -Match ([regex]::Escape("${name}:"))
        }
        foreach ($name in @('template_ids', 'template_names', 'gallery_image_version_ids')) {
            $script:manifest | Should -Match ([regex]::Escape("name: $name"))
        }
    }

    It 'uses the API version, the customizers and the conditional VHD distribution in both implementations' {
        foreach ($text in @($script:bicep, $script:terraform)) {
            $text | Should -Match 'imageTemplates@2025-10-01'
            $text | Should -Match 'SharedImage'
            $text | Should -Match 'distribute_vhd'
            $text | Should -Match "'VHD'|`"VHD`""
            $text | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
            foreach ($number in '01', '02', '03', '04', '05') {
                $text | Should -Match ([regex]::Escape("/$number-"))
            }
        }
    }

    It 'requires a supplied exact source version and never defaults it' {
        $script:bicep | Should -Match '(?m)^param source_version string\s*$'
        $script:terraformVariables | Should -Match 'variable "source_version"'
        $script:terraformVariables | Should -Match 'regex\("\^\[0-9\]\+'
        ($script:bicep + $script:terraform) | Should -Not -Match "version\s*[:=]\s*['""]latest"
    }
}

Describe 'Get-PlatformImageVersion' {
    It 'sorts numeric components, not strings' {
        Mock Get-AzVMImage {
            @([pscustomobject]@{ Version = '26200.100.9' }, [pscustomobject]@{ Version = '26200.1000.1' })
        }
        & $script:versionScript -Location 'region' -Publisher 'publisher' -Offer 'offer' -Sku 'sku' | Should -Be '26200.1000.1'
    }

    It 'rejects the moving alias' {
        { & $script:versionScript -Location 'region' -Publisher 'publisher' -Offer 'offer' -Sku 'sku' -Version 'latest' } | Should -Throw '*latest*'
    }

    It 'throws when no exact version exists' {
        Mock Get-AzVMImage { @() }
        { & $script:versionScript -Location 'region' -Publisher 'publisher' -Offer 'offer' -Sku 'sku' } | Should -Throw '*No matching*'
    }

    It 'validates a requested version against the regional list' {
        Mock Get-AzVMImage { @([pscustomobject]@{ Version = '26200.100.9' }) }
        & $script:versionScript -Location 'region' -Publisher 'publisher' -Offer 'offer' -Sku 'sku' -Version '26200.100.9' | Should -Be '26200.100.9'
        { & $script:versionScript -Location 'region' -Publisher 'publisher' -Offer 'offer' -Sku 'sku' -Version '1.2.3' } | Should -Throw '*No matching*'
    }
}

Describe 'Start-ImageBuild' {
    BeforeEach {
        Mock Set-AzContext {}
        Mock Invoke-AzResourceAction {}
        Mock Start-ImageBuildSleep {}
    }

    It 'starts nothing and selects no subscription without -Execute' {
        $plan = @(& $script:buildScript -SubscriptionId 'subscription' -ResourceGroupName 'images' -TemplateName 'image')
        $plan[0] | Should -Match 'Plan: start image build image'
        Should -Invoke Invoke-AzResourceAction -Times 0 -Exactly
        Should -Invoke Set-AzContext -Times 0 -Exactly
    }

    It 'returns the succeeded last-run status' {
        Mock Get-AzResource {
            [pscustomobject]@{ Properties = [pscustomobject]@{ lastRunStatus = [pscustomobject]@{ runState = 'Succeeded' } } }
        }
        $result = & $script:buildScript -SubscriptionId 'subscription' -ResourceGroupName 'images' -TemplateName 'image' -Execute
        $result.LastRunStatus.runState | Should -Be 'Succeeded'
        Should -Invoke Invoke-AzResourceAction -Times 1 -Exactly
    }

    It 'reports only the failed run fields' {
        Mock Get-AzResource {
            [pscustomobject]@{
                Properties = [pscustomobject]@{
                    lastRunStatus = [pscustomobject]@{ runState = 'Failed'; runSubState = 'Customizing'; message = 'Installation failed'; secret = 'MUST-NOT-APPEAR' }
                }
            }
        }
        $caught = $null
        try { & $script:buildScript -SubscriptionId 'subscription' -ResourceGroupName 'images' -TemplateName 'image' -Execute } catch { $caught = $_.ToString() }
        $caught | Should -Match 'Customizing Installation failed'
        $caught | Should -Not -Match 'MUST-NOT-APPEAR'
    }

    It 'times out after the maximum number of polls' {
        Mock Get-AzResource {
            [pscustomobject]@{ Properties = [pscustomobject]@{ lastRunStatus = [pscustomobject]@{ runState = 'Running' } } }
        }
        { & $script:buildScript -SubscriptionId 'subscription' -ResourceGroupName 'images' -TemplateName 'image' -TimeoutMinutes 2 -Execute } | Should -Throw '*2 polls*'
        # one read before the run (to remember the previous run) plus one per poll
        Should -Invoke Get-AzResource -Times 3 -Exactly
        Should -Invoke Start-ImageBuildSleep -Times 1 -Exactly
    }

    It 'ignores the previous run status and waits for the new run' {
        $global:ImageBuildReads = 0
        Mock Get-AzResource {
            $global:ImageBuildReads++
            switch ($global:ImageBuildReads) {
                1 { $status = [pscustomobject]@{ runState = 'Succeeded'; startTime = 'old-run' } }
                2 { $status = [pscustomobject]@{ runState = 'Succeeded'; startTime = 'old-run' } }
                3 { $status = [pscustomobject]@{ runState = 'Running'; startTime = 'new-run' } }
                default { $status = [pscustomobject]@{ runState = 'Succeeded'; startTime = 'new-run' } }
            }
            [pscustomobject]@{ Properties = [pscustomobject]@{ lastRunStatus = $status } }
        }
        $result = & $script:buildScript -SubscriptionId 'subscription' -ResourceGroupName 'images' -TemplateName 'image' -Execute
        $result.LastRunStatus.startTime | Should -Be 'new-run'
        Should -Invoke Start-ImageBuildSleep -Times 2 -Exactly
        Remove-Variable -Name ImageBuildReads -Scope Global -ErrorAction SilentlyContinue
    }

    It 'stops at the first failed template' {
        Mock Get-AzResource {
            [pscustomobject]@{ Properties = [pscustomobject]@{ lastRunStatus = [pscustomobject]@{ runState = 'Failed'; runSubState = 'x'; message = 'y' } } }
        }
        { & $script:buildScript -SubscriptionId 'subscription' -ResourceGroupName 'images' -TemplateName 'one', 'two' -Execute } | Should -Throw
        Should -Invoke Invoke-AzResourceAction -Times 1 -Exactly
    }
}
