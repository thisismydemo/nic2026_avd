#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the ordered teardown plan for lz-avd (design/avd/landing-zone.md section 11.3) and, only with -Execute,
    runs it. -WhatIf is the default: the plan is printed and written to -OutputPlan, nothing is deleted.
.DESCRIPTION
    Order: backup items (vault must be empty) -> hub-side peering (connectivity subscription) -> Azure Local-side
    peering -> the seven resource groups (hosts, arc, mon, img, stor, net, control; zone links are children of the
    zone and go with rg-*-net) -> subscription-scope objects (policy assignments, budget, custom roles, sub-scope role
    assignment). Filter: every item must carry the lab token in its name or sit in a lab resource group; shared hub,
    VPN, DCs, Bastion and the Azure Local landing zone are never touched. With -Tool Terraform the plan is
    `terraform plan -destroy` and -Execute applies it. Session-host, control-plane and image solutions must be torn
    down first (they live inside these resource groups).
.EXAMPLE
    .\New-AvdLzTeardownPlan.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json -OutputPlan .\lz-avd-teardown.json
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [ValidateSet('Bicep', 'Terraform')][string]$Tool = 'Bicep',
    [string]$BackendConfig,
    [string]$OutputPlan,
    [switch]$Execute,
    [int]$RetrySeconds = 300
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LzAvd.Common.ps1')

if (-not $Execute) { $WhatIfPreference = $true }

$inputs = Get-LzAvdInputs -InputFile $InputFile
$names = $inputs.names
$sub = $inputs.subscription_id_avd
$token = $inputs.lab_token

$hubSegments = $inputs.hub_vnet_id -split '/'
$azlSegments = $inputs.azl_spoke_vnet_id -split '/'

$plan = [System.Collections.Generic.List[object]]::new()
function Add-LzAvdPlanItem {
    param([int]$Order, [string]$Kind, [string]$Id, [string]$Note)
    $plan.Add([pscustomobject]@{ Order = $Order; Kind = $Kind; Id = $Id; Note = $Note })
}

Add-LzAvdPlanItem -Order 10 -Kind 'backup-items' -Id "/subscriptions/$sub/resourceGroups/$($names.rg_stor)/providers/Microsoft.RecoveryServices/vaults/$($names.recovery_vault)" -Note 'Stop protection with delete data for both shares; vault must be empty before the RG goes'
Add-LzAvdPlanItem -Order 20 -Kind 'peering' -Id "$($inputs.hub_vnet_id)/virtualNetworkPeerings/$($names.peer_hub_to_spoke)" -Note "Hub side (subscription $($hubSegments[2])): the only hub change this landing zone made"
Add-LzAvdPlanItem -Order 21 -Kind 'peering' -Id "$($inputs.azl_spoke_vnet_id)/virtualNetworkPeerings/$($names.peer_azl_to_spoke)" -Note "Azure Local side (subscription $($azlSegments[2]))"
$order = 30
foreach ($rgKey in 'rg_hosts', 'rg_arc', 'rg_mon', 'rg_img', 'rg_stor', 'rg_net', 'rg_control') {
    Add-LzAvdPlanItem -Order $order -Kind 'resourceGroup' -Id "/subscriptions/$sub/resourceGroups/$($names[$rgKey])" -Note 'All contents, including zone links and the private endpoint'
    $order++
}
foreach ($asg in @("$($names.asg_allowed_locations)") + ('project', 'workload', 'environment', 'owner', 'lifecycle' | ForEach-Object { "$($names.asg_require_tags)-$_"; "$($names.asg_inherit_tags)-$_" }) + @("$($names.asg_storage_hygiene)-1", "$($names.asg_storage_hygiene)-2")) {
    Add-LzAvdPlanItem -Order 40 -Kind 'policyAssignment' -Id "/subscriptions/$sub/providers/Microsoft.Authorization/policyAssignments/$asg" -Note 'subscription scope'
}
Add-LzAvdPlanItem -Order 41 -Kind 'budget' -Id "/subscriptions/$sub/providers/Microsoft.Consumption/budgets/$($names.budget)" -Note ''
Add-LzAvdPlanItem -Order 42 -Kind 'roleDefinition' -Id "/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions/$($names.role_aib_image)" -Note 'custom role (looked up by its name, the last segment)'
Add-LzAvdPlanItem -Order 42 -Kind 'roleDefinition' -Id "/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions/$($names.role_aib_network)" -Note 'custom role (looked up by its name, the last segment)'

# Safety filter: only lab objects (token in the name) or objects inside this subscription's lab RGs.
$filtered = @($plan | Where-Object {
        $isCrossSub = $_.Kind -eq 'peering'
        $inLabSub = Test-LzAvdResourceInSubscription -ResourceId $_.Id -SubscriptionId $sub
        ($_.Id -match [regex]::Escape($token)) -and ($inLabSub -or $isCrossSub)
    } | Sort-Object Order)
$dropped = @($plan | Where-Object { $filtered -notcontains $_ })
if ($dropped.Count -gt 0) { Write-LzAvdLog -Level Warning -Message "Dropped $($dropped.Count) item(s) that failed the lab-token/subscription filter." }

$filtered | Format-Table Order, Kind, Id -AutoSize | Out-String | ForEach-Object { Write-LzAvdLog -Message $_ }
if ($OutputPlan) {
    # The plan file is a local artifact (names and ids only); writing it is allowed in WhatIf mode.
    [pscustomobject]@{ generatedOn = (Get-Date).ToUniversalTime().ToString('o'); subscriptionId = $sub; tool = $Tool; items = $filtered } | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPlan -Encoding utf8 -WhatIf:$false
    Write-LzAvdLog -Message "Plan written to $OutputPlan"
}

if (-not $Execute) {
    Write-LzAvdLog -Message 'WhatIf mode: nothing deleted. Re-run with -Execute after owner approval.'
    return [pscustomobject]@{ Mode = 'WhatIf'; Tool = $Tool; Items = $filtered }
}

if ($Tool -eq 'Terraform') {
    if (-not $BackendConfig) { throw 'Terraform teardown needs -BackendConfig.' }
    $tfDir = Join-Path (Get-LzAvdSolutionRoot) 'terraform'
    $varFile = Join-Path $tfDir 'terraform.generated.tfvars.json'
    Push-Location $tfDir
    try {
        & terraform init -input=false "-backend-config=$BackendConfig"; if ($LASTEXITCODE -ne 0) { throw 'terraform init failed' }
        & terraform plan -destroy -input=false "-var-file=$varFile" '-out=lz-avd.destroy.tfplan'; if ($LASTEXITCODE -ne 0) { throw 'terraform plan -destroy failed' }
        if ($PSCmdlet.ShouldProcess("subscription $sub", 'terraform apply lz-avd.destroy.tfplan')) {
            & terraform apply -input=false 'lz-avd.destroy.tfplan'; if ($LASTEXITCODE -ne 0) { throw 'terraform apply (destroy) failed' }
        }
    }
    finally { Pop-Location }
    return [pscustomobject]@{ Mode = 'Execute'; Tool = $Tool; Items = $filtered }
}

foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Remove-AzResource', 'Remove-AzResourceGroup', 'Remove-AzPolicyAssignment', 'Remove-AzRoleDefinition', 'Get-AzRoleDefinition') {
    if (-not (Test-LzAvdCommand -Name $cmd)) { throw "Az cmdlet '$cmd' not available." }
}
$context = Get-AzContext
if (-not $context -or $context.Subscription.Id -ne $sub) { [void](Set-AzContext -WhatIf:$false -Subscription $sub) }

foreach ($item in $filtered) {
    if (-not $PSCmdlet.ShouldProcess($item.Id, "DELETE $($item.Kind)")) { continue }
    Invoke-LzAvdWithRetry -Activity "delete $($item.Kind)" -MaxSeconds $RetrySeconds -ScriptBlock {
        switch ($item.Kind) {
            'backup-items' { Write-LzAvdLog -Level Warning -Message 'Backup items: run Disable-AzRecoveryServicesBackupProtection -RemoveRecoveryPoints for both shares before the RG deletion proceeds; the RG step will fail while items exist.' }
            'peering' { [void](Remove-AzResource -ResourceId $item.Id -Force) }
            'resourceGroup' { [void](Remove-AzResourceGroup -Id $item.Id -Force) }
            'policyAssignment' { [void](Remove-AzPolicyAssignment -Id $item.Id -ErrorAction SilentlyContinue) }
            'budget' { [void](Remove-AzResource -ResourceId $item.Id -Force -ErrorAction SilentlyContinue) }
            'roleDefinition' { $def = Get-AzRoleDefinition -Name ($item.Id -split '/')[-1] -ErrorAction SilentlyContinue; if ($def) { [void](Remove-AzRoleDefinition -Id $def.Id -Force) } }
        }
    } | Out-Null
    Write-LzAvdLog -Message "Done: $($item.Kind) $($item.Id)"
}
[pscustomobject]@{ Mode = 'Execute'; Tool = $Tool; Items = $filtered }
