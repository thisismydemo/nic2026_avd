#Requires -Version 7.0
<#
.SYNOPSIS
    Stages the lz-avd deployment: Prereqs -> Generate -> Validate -> Preview (what-if / plan) -> Deploy.
.DESCRIPTION
    Nothing changes in Azure unless -Execute is given: without it the script runs in -WhatIf mode and stops after the
    Preview stage (az deployment sub what-if or terraform plan). Inputs come from the environment file through
    Get-NIC26Config and the converters (ConvertTo-NIC26BicepParam / ConvertTo-NIC26TfVars); the generated files are
    git-ignored. Secrets are never read here (the landing zone needs none).
.PARAMETER Tool
    Bicep (demo path) or Terraform (parity path).
.PARAMETER Stage
    One stage, or All (= every stage up to Preview; Deploy only with -Execute).
.PARAMETER BackendConfig
    Terraform only: path to the backend-config file in environment/ (never committed).
.PARAMETER Execute
    Required for the Deploy stage. Still asks for confirmation (ConfirmImpact High) unless -Confirm:$false.
.EXAMPLE
    .\Invoke-LzAvdDeploy.ps1 -Tool Bicep            # generate, validate, what-if; changes nothing
.EXAMPLE
    .\Invoke-LzAvdDeploy.ps1 -Tool Terraform -BackendConfig ..\..\..\..\environment\avd\backend.lz-avd.hcl -Stage Deploy -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Bicep', 'Terraform')][string]$Tool = 'Bicep',
    [ValidateSet('Prereqs', 'Generate', 'Validate', 'Preview', 'Deploy', 'All')][string]$Stage = 'All',
    [string]$Scope = 'avd',
    [string]$Solution = 'lz-avd',
    [string]$BackendConfig,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LzAvd.Common.ps1')

if (-not $Execute) { $WhatIfPreference = $true }

$root = Get-LzAvdSolutionRoot
$bicepDir = Join-Path $root 'bicep'
$tfDir = Join-Path $root 'terraform'
$tfVarsFile = Join-Path $tfDir 'terraform.generated.tfvars.json'
$bicepParamFile = Join-Path $bicepDir 'main.generated.bicepparam'

$stages = if ($Stage -eq 'All') { @('Prereqs', 'Generate', 'Validate', 'Preview') + $(if ($Execute) { @('Deploy') } else { @() }) } else { @($Stage) }

function Invoke-LzAvdNative {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory)
    Write-LzAvdLog -Level Verbose -Message "$FilePath $($ArgumentList -join ' ')"
    $previous = Get-Location
    try {
        if ($WorkingDirectory) { Set-Location -Path $WorkingDirectory }
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) { throw "$FilePath exited with code $LASTEXITCODE" }
    }
    finally {
        Set-Location -Path $previous
    }
}

foreach ($current in $stages) {
    Write-LzAvdLog -Message "=== Stage: $current ($Tool) ==="
    switch ($current) {
        'Prereqs' {
            foreach ($cmd in @('az') + $(if ($Tool -eq 'Terraform') { @('terraform') } else { @() })) {
                if (-not (Test-LzAvdCommand -Name $cmd)) { throw "'$cmd' is not installed on this machine." }
            }
            $modulePresent = Import-LzAvdAutomationModule -Optional
            Write-LzAvdLog -Message "NIC26.Automation present: $modulePresent"
            Write-LzAvdLog -Message 'Resource providers: run Register-AvdProviders.ps1 -SubscriptionId <id> (-Execute to register).'
        }
        'Generate' {
            [void](Import-LzAvdAutomationModule)
            $config = Get-NIC26Config -Scope $Scope
            # Generating the git-ignored local files is not an Azure change, so the converters run with -Execute even in
            # WhatIf mode; both files are produced so Test-AvdLandingZone can read the canonical JSON.
            ConvertTo-NIC26BicepParam -Solution $Solution -Config $config -OutFile $bicepParamFile -Execute -WhatIf:$false | Out-Null
            ConvertTo-NIC26TfVars -Solution $Solution -Config $config -OutFile $tfVarsFile -Execute -WhatIf:$false | Out-Null
            Write-LzAvdLog -Message "Generated $bicepParamFile and $tfVarsFile (git-ignored)."
        }
        'Validate' {
            if ($Tool -eq 'Bicep') {
                $files = @((Join-Path $bicepDir 'main.bicep')) + (Get-ChildItem -Path (Join-Path $bicepDir 'modules') -Filter '*.bicep' | Select-Object -ExpandProperty FullName)
                foreach ($f in $files) { Invoke-LzAvdNative -FilePath 'az' -ArgumentList @('bicep', 'build', '--file', $f, '--stdout') | Out-Null }
                if (Test-Path $bicepParamFile) { Invoke-LzAvdNative -FilePath 'az' -ArgumentList @('bicep', 'build-params', '--file', $bicepParamFile, '--stdout') | Out-Null }
            }
            else {
                Invoke-LzAvdNative -FilePath 'terraform' -ArgumentList @('fmt', '-check', '-recursive') -WorkingDirectory $tfDir
                Invoke-LzAvdNative -FilePath 'terraform' -ArgumentList @('init', '-backend=false', '-input=false') -WorkingDirectory $tfDir
                Invoke-LzAvdNative -FilePath 'terraform' -ArgumentList @('validate') -WorkingDirectory $tfDir
            }
            Write-LzAvdLog -Message 'Validation passed.'
        }
        'Preview' {
            $inputs = Get-LzAvdInputs -InputFile $tfVarsFile
            $deploymentName = "dep-$($inputs.org)-$($inputs.lab_token)-$Solution-01"
            if ($Tool -eq 'Bicep') {
                # what-if is read-only
                Invoke-LzAvdNative -FilePath 'az' -ArgumentList @('deployment', 'sub', 'what-if', '--subscription', $inputs.subscription_id_avd, '--location', $inputs.location, '--name', $deploymentName, '--template-file', (Join-Path $bicepDir 'main.bicep'), '--parameters', $bicepParamFile)
            }
            else {
                if (-not $BackendConfig) { throw 'Terraform Preview/Deploy needs -BackendConfig <environment/.../backend.hcl> (contract section 3).' }
                Invoke-LzAvdNative -FilePath 'terraform' -ArgumentList @('init', '-input=false', "-backend-config=$BackendConfig") -WorkingDirectory $tfDir
                Invoke-LzAvdNative -FilePath 'terraform' -ArgumentList @('plan', '-input=false', "-var-file=$tfVarsFile", "-out=$Solution.tfplan") -WorkingDirectory $tfDir
            }
        }
        'Deploy' {
            if (-not $Execute) { throw 'Deploy requires -Execute (owner approval). Without it only Preview runs.' }
            $inputs = Get-LzAvdInputs -InputFile $tfVarsFile
            $deploymentName = "dep-$($inputs.org)-$($inputs.lab_token)-$Solution-01"
            $target = "subscription $($inputs.subscription_id_avd) ($Tool, $deploymentName)"
            if ($PSCmdlet.ShouldProcess($target, 'Deploy lz-avd')) {
                if ($Tool -eq 'Bicep') {
                    Invoke-LzAvdNative -FilePath 'az' -ArgumentList @('deployment', 'sub', 'create', '--subscription', $inputs.subscription_id_avd, '--location', $inputs.location, '--name', $deploymentName, '--template-file', (Join-Path $bicepDir 'main.bicep'), '--parameters', $bicepParamFile)
                }
                else {
                    if (-not (Test-Path (Join-Path $tfDir "$Solution.tfplan"))) { throw 'No plan file; run the Preview stage first.' }
                    Invoke-LzAvdNative -FilePath 'terraform' -ArgumentList @('apply', '-input=false', "$Solution.tfplan") -WorkingDirectory $tfDir
                }
                Write-LzAvdLog -Message 'Deployment finished. Run Test-AvdLandingZone.ps1 next.'
            }
        }
    }
}
