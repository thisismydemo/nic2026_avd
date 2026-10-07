#Requires -Version 7.0
<#
.SYNOPSIS
Plans or starts Azure Image Builder templates and waits for their last-run status.
.DESCRIPTION
Starts each template with the 'run' action and polls the template's lastRunStatus until it is Succeeded (returned) or
Failed/Canceled (throws with the run sub-state and message only). A build takes 45-90 minutes: it is recorded, never
shown live. Without -Execute only the plan is printed and nothing is started.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER SubscriptionId
Subscription containing the templates.
.PARAMETER ResourceGroupName
Resource group containing the templates.
.PARAMETER TemplateName
Names of the templates to build, in order.
.PARAMETER TimeoutMinutes
Maximum polling duration per template (one poll per minute).
.PARAMETER Execute
Actually start the builds.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string[]]$TemplateName,

    [ValidateRange(1, 1440)]
    [int]$TimeoutMinutes = 150,

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Start-ImageBuildSleep -ErrorAction SilentlyContinue)) {
    # Seam so tests can skip the real wait.
    function Start-ImageBuildSleep {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mockable wait wrapper; changes no system state.')]
        param([int]$Seconds)
        Start-Sleep -Seconds $Seconds
    }
}

$resourceType = 'Microsoft.VirtualMachineImages/imageTemplates'
$apiVersion = '2025-10-01'
$maximumPolls = $TimeoutMinutes

if (-not $Execute) {
    foreach ($name in $TemplateName) {
        Write-Output "Plan: start image build $name"
    }
    return
}

$null = Set-AzContext -WhatIf:$false -SubscriptionId $SubscriptionId

foreach ($name in $TemplateName) {
    if (-not $PSCmdlet.ShouldProcess($name, 'Start image build')) {
        continue
    }

    # lastRunStatus can still describe an earlier run right after 'run': remember its start time and ignore it.
    $before = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType $resourceType -Name $name -ExpandProperties
    $previousStart = $null
    $previousStatus = $before.Properties.lastRunStatus
    if ($null -ne $previousStatus -and $previousStatus.PSObject.Properties['startTime']) {
        $previousStart = [string]$previousStatus.startTime
    }

    $action = @{
        ResourceGroupName = $ResourceGroupName
        ResourceType      = $resourceType
        ResourceName      = $name
        ApiVersion        = $apiVersion
        Action            = 'run'
        Force             = $true
    }
    $null = Invoke-AzResourceAction @action

    $completed = $false
    for ($poll = 0; $poll -lt $maximumPolls; $poll++) {
        $resource = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType $resourceType -Name $name -ExpandProperties
        $status = $resource.Properties.lastRunStatus
        $isCurrent = $null -ne $status
        if ($isCurrent -and $null -ne $previousStart -and $status.PSObject.Properties['startTime'] -and [string]$status.startTime -eq $previousStart) {
            $isCurrent = $false
        }
        if ($isCurrent) {
            if ($status.runState -eq 'Succeeded') {
                [pscustomobject]@{ TemplateName = $name; LastRunStatus = $status }
                $completed = $true
                break
            }

            if ($status.runState -in @('Failed', 'Canceled')) {
                throw "Image build $name $($status.runState): $($status.runSubState) $($status.message)"
            }
        }

        if ($poll -lt ($maximumPolls - 1)) {
            Start-ImageBuildSleep -Seconds 60
        }
    }

    if (-not $completed) {
        throw "Image build $name timed out after $maximumPolls polls."
    }
}
