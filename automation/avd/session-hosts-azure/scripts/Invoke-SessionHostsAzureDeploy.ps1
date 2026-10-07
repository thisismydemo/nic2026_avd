#Requires -Version 7.0
<#
.SYNOPSIS
Plans or deploys the Azure AVD session-host VMs.
.DESCRIPTION
Resolves the keyvault:// administrator references in memory with Resolve-NIC26KeyVaultRef (NIC26.Automation must be
imported) and hands them to the deployment as secure parameters. Never supplies a host-pool registration token to
infrastructure-as-code (K-7). Without -Execute: Bicep runs a What-If, Terraform runs a plan.
For Bicep, -ParameterFile is an ARM JSON parameters file (build it from the .bicepparam with 'az bicep build-params'),
because Az PowerShell cannot combine a .bicepparam with secure values supplied at run time.
.PARAMETER Mode
Bicep or Terraform.
.PARAMETER SubscriptionId
Subscription that holds the session-host resource group.
.PARAMETER ResourceGroupName
Resource group that receives the VMs.
.PARAMETER ParameterFile
Bicep: ARM JSON parameters file. Terraform: tfvars JSON file.
.PARAMETER AdminUsernameRef
keyvault:// reference of the local administrator user name.
.PARAMETER AdminPasswordRef
keyvault:// reference of the local administrator password.
.PARAMETER Execute
Apply the change. Without it only a What-If / plan runs.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'AdminPasswordRef', Justification = 'A keyvault:// reference (a name), not a password; the value is resolved in memory.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The value was just resolved from Key Vault in memory; New-AzResourceGroupDeployment needs a SecureString for the template @secure() parameters.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('Bicep', 'Terraform')][string]$Mode,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$ParameterFile,
    [Parameter(Mandatory)][ValidatePattern('^keyvault://')][string]$AdminUsernameRef,
    [Parameter(Mandatory)][ValidatePattern('^keyvault://')][string]$AdminPasswordRef,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Resolve-NIC26KeyVaultRef -ErrorAction SilentlyContinue)) {
    throw 'Import NIC26.Automation before running this script.'
}

function ConvertFrom-ResolvedSecret {
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [securestring]) { return [System.Net.NetworkCredential]::new('', $Value).Password }
    if ($Value -is [string]) { return $Value }
    throw 'The secret resolver returned an unsupported value type.'
}

$user = $null
$password = $null
try {
    $user = ConvertFrom-ResolvedSecret (Resolve-NIC26KeyVaultRef -Ref $AdminUsernameRef)
    $password = ConvertFrom-ResolvedSecret (Resolve-NIC26KeyVaultRef -Ref $AdminPasswordRef)
    $file = (Resolve-Path -LiteralPath $ParameterFile).Path

    if ($Mode -eq 'Bicep') {
        $arguments = @{
            ResourceGroupName     = $ResourceGroupName
            TemplateFile          = (Join-Path $PSScriptRoot '../bicep/main.bicep')
            TemplateParameterFile = $file
            adminUsername         = (ConvertTo-SecureString $user -AsPlainText -Force)
            adminPassword         = (ConvertTo-SecureString $password -AsPlainText -Force)
        }
        Set-AzContext -WhatIf:$false -SubscriptionId $SubscriptionId | Out-Null
        if (-not $Execute) {
            New-AzResourceGroupDeployment @arguments -WhatIf
        }
        elseif ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Deploy AVD session hosts')) {
            New-AzResourceGroupDeployment @arguments | Out-Null
        }
    }
    else {
        $directory = (Resolve-Path (Join-Path $PSScriptRoot '../terraform')).Path
        $command = if ($Execute) { 'apply' } else { 'plan' }
        if (-not $Execute -or $PSCmdlet.ShouldProcess($ResourceGroupName, 'Apply Terraform session hosts')) {
            $start = [System.Diagnostics.ProcessStartInfo]::new('terraform')
            $start.WorkingDirectory = $directory
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            foreach ($argument in @($command, '-input=false', "-var-file=$file")) { [void]$start.ArgumentList.Add($argument) }
            if ($Execute) { [void]$start.ArgumentList.Add('-auto-approve') }
            # ProcessStartInfo.Environment affects only the child process, never this one.
            $start.Environment['TF_VAR_local_admin_username'] = $user
            $start.Environment['TF_VAR_local_admin_password'] = $password
            $start.Environment['TF_VAR_resource_group_name'] = $ResourceGroupName
            $start.Environment['ARM_SUBSCRIPTION_ID'] = $SubscriptionId
            $process = [System.Diagnostics.Process]::Start($start)
            try {
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                $process.WaitForExit()
                # Terraform masks sensitive values in its own output.
                Write-Output $stdout.GetAwaiter().GetResult()
                if ($process.ExitCode -ne 0) {
                    Write-Error $stderr.GetAwaiter().GetResult() -ErrorAction Continue
                    throw "Terraform $command failed with exit code $($process.ExitCode)."
                }
            }
            finally { $process.Dispose() }
        }
    }
}
finally {
    $user = $null
    $password = $null
}
