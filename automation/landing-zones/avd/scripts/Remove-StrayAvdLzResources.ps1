#Requires -Version 7.0
<#
.SYNOPSIS
    STAGE: decommission leftovers in the AVD landing-zone subscription (decision P-10, e.g. a stray Arc machine).
    DESTRUCTIVE. -WhatIf is the default. Deleting needs -Execute, -TenantId and -ConfirmDeleteList <owner-approved JSON>.
.DESCRIPTION
    Phase 0 - discovery (every run, read-only, fails closed): enumerates every resource and resource group in
    -SubscriptionId with the context pinned to that subscription. Candidates = anything whose name does not contain
    -LabToken and whose tags do not carry project=<LabToken>. Candidates whose type is in the ordered deletion type
    list get an order (100..299); every other type is listed as an order-800 BLOCKER (approved=false, never deleted by
    this script). Locks (own and inherited) are recorded per item. The candidate file (-CandidateFile) embeds the
    generation timestamp, the subscription and a SHA-256 of the item list; the owner reviews it, sets approved=true
    per entry (plus removeLock=true / acknowledgePermanent=true where needed) and hands it back as -ConfirmDeleteList.
    Phase 1 - resources (-Execute without -DeleteEmptyResourceGroups): the approved list is validated (objects with
    approved=true and id only; bare strings are an error; subscription match; integrity hash; age <= 24 h and hash
    equal to the current discovery unless -AllowStaleList; tenant and subscription verified on the live context).
    Each approved entry is re-validated against the CURRENT candidate (same id and type) immediately before deletion,
    deleted, and polled to a terminal state (-DeleteTimeoutMinutes, default 10). Locked items are skipped as blocked
    unless -RemoveLocks AND the entry has removeLock=true; removed locks are audited and restored when the delete fails.
    Key Vaults: soft-delete/purge-protection are inspected first; soft-delete disabled needs acknowledgePermanent=true;
    after deletion the vault is awaited in the removed state, purged (unless purge-protected), and the purge verified.
    The run stops at the first failure unless -ContinueOnError.
    Phase 2 - resource groups (-Execute -DeleteEmptyResourceGroups, a separate run): each approved resource group is
    fully re-enumerated (any type; enumeration errors are fatal); only empty, unlocked groups are deleted, each
    confirmed gone by a final re-check. No resource deletion happens in this phase.
    -Execute -WhatIf validates everything and deletes nothing. A durable audit JSON (-AuditFile) is written on every
    run: operator identity, tenant, subscription, mode, reviewed-list hash, every action with timestamp/status/error,
    lock changes, skipped and blocked items and the final state. Never touches another subscription.
.EXAMPLE
    .\Remove-StrayAvdLzResources.ps1 -SubscriptionId <id> -LabToken <lab> -CandidateFile .\stray-candidates.json
.EXAMPLE
    .\Remove-StrayAvdLzResources.ps1 -SubscriptionId <id> -TenantId <tid> -LabToken <lab> -Execute -ConfirmDeleteList .\stray-approved.json
.EXAMPLE
    .\Remove-StrayAvdLzResources.ps1 -SubscriptionId <id> -TenantId <tid> -Execute -ConfirmDeleteList .\stray-approved.json -DeleteEmptyResourceGroups
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId,
    [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TenantId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{2,23}$')][string]$LabToken,
    [string]$CandidateFile = (Join-Path (Get-Location).Path 'lz-avd-stray-candidates.json'),
    [string]$ConfirmDeleteList,
    [string]$AuditFile,
    [switch]$Execute,
    [switch]$RemoveLocks,
    [switch]$AllowStaleList,
    [switch]$DeleteEmptyResourceGroups,
    [switch]$ContinueOnError,
    [ValidateRange(1, 120)][int]$DeleteTimeoutMinutes = 10,
    [ValidateRange(1, 120)][int]$PollSeconds = 15
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LzAvd.Common.ps1')

if (-not $Execute) { $WhatIfPreference = $true }
$whatIfRun = [bool]$WhatIfPreference
$runStart = (Get-Date).ToUniversalTime()
if (-not $AuditFile) { $AuditFile = Join-Path (Get-Location).Path ("lz-avd-stray-audit-{0}.json" -f $runStart.ToString('yyyyMMddTHHmmssZ')) }

foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzResource', 'Get-AzResourceGroup', 'Get-AzResourceLock', 'Remove-AzResource', 'Remove-AzResourceGroup', 'Remove-AzResourceLock', 'New-AzResourceLock') {
    if (-not (Test-LzAvdCommand -Name $cmd)) { throw "Az cmdlet '$cmd' not available (Az.Resources)." }
}

# Ordered deletion type list (lower first). Anything else is an order-800 blocker.
$deletionOrder = [ordered]@{
    'microsoft.hybridcompute/machines'                      = 100
    'microsoft.compute/virtualmachines'                     = 110
    'microsoft.compute/disks'                               = 120
    'microsoft.compute/snapshots'                           = 121
    'microsoft.compute/images'                              = 122
    'microsoft.network/networkinterfaces'                   = 130
    'microsoft.network/privateendpoints'                    = 140
    'microsoft.network/publicipaddresses'                   = 150
    'microsoft.network/networksecuritygroups'               = 160
    'microsoft.network/routetables'                         = 161
    'microsoft.network/virtualnetworks'                     = 170
    'microsoft.network/privatednszones'                     = 180
    'microsoft.storage/storageaccounts'                     = 200
    'microsoft.keyvault/vaults'                             = 210
    'microsoft.managedidentity/userassignedidentities'      = 220
    'microsoft.insights/datacollectionrules'                = 230
    'microsoft.insights/actiongroups'                       = 231
    'microsoft.operationalinsights/workspaces'              = 240
}
$blockerOrder = 800

# ---------------------------------------------------------------------------------------------------------------------
# audit
# ---------------------------------------------------------------------------------------------------------------------
$audit = [ordered]@{
    schemaVersion    = 1
    script           = 'Remove-StrayAvdLzResources.ps1'
    startedOn        = $runStart.ToString('o')
    operator         = $null
    tenantId         = $null
    subscriptionId   = $SubscriptionId
    mode             = if (-not $Execute) { 'discovery' } elseif ($whatIfRun) { 'execute-whatif' } elseif ($DeleteEmptyResourceGroups) { 'execute-resource-groups' } else { 'execute-resources' }
    approvedListPath = $ConfirmDeleteList
    approvedListHash = $null
    candidateFile    = $CandidateFile
    actions          = [System.Collections.Generic.List[object]]::new()
    blocked          = [System.Collections.Generic.List[object]]::new()
    skipped          = [System.Collections.Generic.List[object]]::new()
    lockChanges      = [System.Collections.Generic.List[object]]::new()
    finalState       = $null
    finishedOn       = $null
    result           = 'running'
}
function Write-LzAvdAudit {
    param([string]$Result)
    $audit.result = $Result
    $audit.finishedOn = (Get-Date).ToUniversalTime().ToString('o')
    $dir = Split-Path -Parent $AuditFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null }
    [pscustomobject]$audit | ConvertTo-Json -Depth 8 | Set-Content -Path $AuditFile -Encoding utf8 -WhatIf:$false
    Write-LzAvdLog -Message "Audit written to $AuditFile ($Result)"
}
function Add-LzAvdAction {
    param([string]$Phase, [string]$Id, [string]$Type, [string]$Action, [string]$Status, [string]$ErrorMessage = '')
    $audit.actions.Add([pscustomobject]@{ timestamp = (Get-Date).ToUniversalTime().ToString('o'); phase = $Phase; id = $Id; type = $Type; action = $Action; status = $Status; error = $ErrorMessage })
    $level = if ($Status -in 'failed', 'purge-failed') { 'Warning' } else { 'Info' }
    Write-LzAvdLog -Level $level -Message "[$Phase] $Action $Id -> $Status $ErrorMessage"
}

# ---------------------------------------------------------------------------------------------------------------------
# context: pinned to the target subscription on every Az call (-DefaultProfile $ctx)
# ---------------------------------------------------------------------------------------------------------------------
$ctx = Get-AzContext
if (-not $ctx) { throw 'No Azure context. Connect-AzAccount first (your own sign-in; no stored credentials).' }
if ($ctx.Subscription.Id -ne $SubscriptionId -or ($TenantId -and $ctx.Tenant.Id -ne $TenantId)) {
    $setArgs = @{ Subscription = $SubscriptionId }
    if ($TenantId) { $setArgs.Tenant = $TenantId }
    $ctx = Set-AzContext -WhatIf:$false @setArgs
}
if ($ctx.Subscription.Id -ne $SubscriptionId) { throw "Context is pinned to subscription $($ctx.Subscription.Id), not $SubscriptionId. Aborting." }
$audit.operator = "$($ctx.Account.Id)"
$audit.tenantId = "$($ctx.Tenant.Id)"
$az = @{ DefaultProfile = $ctx }

# ---------------------------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------------------------
function Test-LzAvdIsLabResource {
    param([Parameter(Mandatory)][string]$Name, $Tags)
    if ($Name -match [regex]::Escape($LabToken)) { return $true }
    if ($Tags -and $Tags.ContainsKey('project') -and $Tags['project'] -eq $LabToken) { return $true }
    return $false
}

function Get-LzAvdErrorClass {
    param([Parameter(Mandatory)][string]$Message)
    if ($Message -match '(?i)AuthorizationFailed|Forbidden|\b403\b|does not have authorization|InvalidAuthenticationToken|\b401\b') { return 'authorization' }
    if ($Message -match '(?i)timed? ?out|name resolution|unable to connect|No such host|SSL|socket|network') { return 'transport' }
    return 'other'
}

function Invoke-LzAvdDiscovery {
    # fails closed: any enumeration error aborts the run with its class
    try {
        $resources = @(Get-AzResource @az)
        $groups = @(Get-AzResourceGroup @az)
        $locks = @(Get-AzResourceLock @az)
    }
    catch {
        $class = Get-LzAvdErrorClass -Message $_.Exception.Message
        throw "Discovery failed ($class): $($_.Exception.Message). Nothing was listed or deleted."
    }
    foreach ($r in $resources) {
        if (-not (Test-LzAvdResourceInSubscription -ResourceId $r.ResourceId -SubscriptionId $SubscriptionId)) { throw "Enumeration returned a resource outside $SubscriptionId ($($r.ResourceId)); aborting." }
    }
    if ($resources.Count -eq 0 -and $groups.Count -eq 0) { Write-LzAvdLog -Message "Subscription $SubscriptionId holds no resources and no resource groups (confirmed empty, not an error)." }

    $items = foreach ($r in $resources) {
        if (Test-LzAvdIsLabResource -Name $r.Name -Tags $r.Tags) { continue }
        $typeKey = $r.ResourceType.ToLowerInvariant()
        $order = if ($deletionOrder.Contains($typeKey)) { $deletionOrder[$typeKey] } else { $blockerOrder }
        $ownLocks = @($locks | Where-Object { $_.ResourceId -and $_.ResourceId.ToLowerInvariant().StartsWith($r.ResourceId.ToLowerInvariant() + '/providers/microsoft.authorization/locks/') })
        $rgId = "/subscriptions/$SubscriptionId/resourceGroups/$($r.ResourceGroupName)"
        $inherited = @($locks | Where-Object { $_.ResourceId -and ($_.ResourceId.ToLowerInvariant().StartsWith($rgId.ToLowerInvariant() + '/providers/microsoft.authorization/locks/') -or $_.ResourceId.ToLowerInvariant().StartsWith("/subscriptions/$($SubscriptionId.ToLowerInvariant())/providers/microsoft.authorization/locks/")) })
        [pscustomobject]@{
            kind                 = 'resource'
            id                   = $r.ResourceId
            name                 = $r.Name
            type                 = $r.ResourceType
            resourceGroup        = $r.ResourceGroupName
            order                = $order
            blocker              = ($order -eq $blockerOrder)
            ownLocks             = @($ownLocks | ForEach-Object { [pscustomobject]@{ name = $_.Name; level = "$($_.Properties.level)"; notes = "$($_.Properties.notes)"; id = $_.ResourceId } })
            inheritedLocks       = @($inherited | ForEach-Object { $_.ResourceId })
            approved             = $false
            removeLock           = $false
            acknowledgePermanent = $false
            purge                = $false
        }
    }
    $rgItems = foreach ($g in $groups) {
        if (Test-LzAvdIsLabResource -Name $g.ResourceGroupName -Tags $g.Tags) { continue }
        $ownLocks = @($locks | Where-Object { $_.ResourceId -and $_.ResourceId.ToLowerInvariant().StartsWith($g.ResourceId.ToLowerInvariant() + '/providers/microsoft.authorization/locks/') })
        [pscustomobject]@{
            kind     = 'resourceGroup'
            id       = $g.ResourceId
            name     = $g.ResourceGroupName
            type     = 'Microsoft.Resources/resourceGroups'
            order    = 900
            blocker  = $false
            ownLocks = @($ownLocks | ForEach-Object { [pscustomobject]@{ name = $_.Name; level = "$($_.Properties.level)"; notes = "$($_.Properties.notes)"; id = $_.ResourceId } })
            approved = $false
        }
    }
    return [pscustomobject]@{ items = @($items | Sort-Object order, id); resourceGroups = @($rgItems | Sort-Object id); locks = $locks }
}

function Get-LzAvdItemHash {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries, [Parameter(Mandatory)][string]$Subscription)
    $canonical = (@($Entries | ForEach-Object { "$($_.kind)|$($_.id)|$($_.type)".ToLowerInvariant() } | Sort-Object) -join "`n") + "`n" + $Subscription.ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Wait-LzAvdResourceGone {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][int]$TimeoutMinutes)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        $still = $null
        try { $still = Get-AzResource @az -ResourceId $Id -ErrorAction Stop }
        catch {
            if ($_.Exception.Message -match '(?i)not ?found|does not exist|could not be found|404') { return $true }
            throw
        }
        if (-not $still) { return $true }
        if ((Get-Date) -gt $deadline) { throw "Timeout after $TimeoutMinutes min: $Id still exists (provisioning state: $($still.Properties.provisioningState))." }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Test-LzAvdApprovedList {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Current)
    if (-not (Test-Path -Path $Path)) { throw "Approved list '$Path' not found. Nothing deleted." }
    $raw = Get-Content -Path $Path -Raw
    $approval = $raw | ConvertFrom-Json -AsHashtable
    foreach ($key in 'generatedOn', 'subscriptionId', 'itemsHash', 'items', 'approvedBy', 'approvedOn') {
        if (-not $approval.ContainsKey($key) -or $null -eq $approval[$key]) { throw "Approved list lacks '$key' (review the candidate file, set approved=true, add approvedBy/approvedOn). Nothing deleted." }
    }
    if ($approval.subscriptionId -ne $SubscriptionId) { throw "Approved list is for subscription $($approval.subscriptionId), not $SubscriptionId. Nothing deleted." }
    $entries = @($approval.items) + @($(if ($approval.ContainsKey('resourceGroups')) { $approval.resourceGroups } else { @() }))
    foreach ($e in $entries) {
        if ($e -isnot [System.Collections.IDictionary]) { throw "Approved list entry '$e' is not an object; every entry must be { id, type, kind, approved: true|false, ... }. Nothing deleted." }
        foreach ($k in 'id', 'approved', 'kind', 'type') { if (-not $e.ContainsKey($k)) { throw "Approved list entry '$($e['id'])' lacks '$k'. Nothing deleted." } }
        if ($e['approved'] -isnot [bool]) { throw "Approved list entry '$($e['id'])': approved must be boolean true/false. Nothing deleted." }
    }
    $integrity = Get-LzAvdItemHash -Entries @($entries | ForEach-Object { [pscustomobject]@{ kind = $_['kind']; id = $_['id']; type = $_['type'] } }) -Subscription $SubscriptionId
    if ($integrity -ne $approval.itemsHash) { throw "Approved list itemsHash does not match its own items (edited after generation?). Nothing deleted." }
    $generated = [datetime]::Parse($approval.generatedOn, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    $ageHours = ((Get-Date).ToUniversalTime() - $generated).TotalHours
    $liveHash = Get-LzAvdItemHash -Entries (@($Current.items) + @($Current.resourceGroups)) -Subscription $SubscriptionId
    $stale = @()
    if ($ageHours -gt 24) { $stale += "generated $([math]::Round($ageHours, 1)) h ago (> 24 h)" }
    if ($liveHash -ne $approval.itemsHash) { $stale += 'the live candidate set differs from the reviewed one' }
    if ($stale.Count -gt 0 -and -not $AllowStaleList) { throw "Approved list is stale: $($stale -join '; '). Re-run discovery and re-approve, or pass -AllowStaleList (per-item re-validation still applies). Nothing deleted." }
    if ($stale.Count -gt 0) { Write-LzAvdLog -Level Warning -Message "Stale approved list accepted (-AllowStaleList): $($stale -join '; ')" }
    $audit.approvedListHash = $approval.itemsHash
    return [pscustomobject]@{ approval = $approval; entries = $entries; rawHash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function Get-LzAvdCurrentCandidate {
    # immediate re-validation: same id and type in the CURRENT candidate set
    param([Parameter(Mandatory)][hashtable]$Entry, [Parameter(Mandatory)][object]$Current)
    $set = if ($Entry['kind'] -eq 'resourceGroup') { $Current.resourceGroups } else { $Current.items }
    return @($set | Where-Object { $_.id -ieq $Entry['id'] -and $_.type -ieq $Entry['type'] }) | Select-Object -First 1
}

function Test-LzAvdStillEligible {
    # Re-reads the LIVE resource and its locks immediately before acting. Returns $null when it is still a stray with the same protection
    # it had at discovery, otherwise the reason it must not be deleted. Read errors are fatal (fail closed).
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)][object]$Live)
    $now = Get-AzResource @az -ResourceId $Id -ErrorAction Stop
    if (-not $now) { return 'the resource no longer exists' }
    if ($now.ResourceType -ine $Type) { return "its type is now '$($now.ResourceType)'" }
    if (Test-LzAvdIsLabResource -Name $now.Name -Tags $now.Tags) { return "it now contains '$LabToken' or is tagged project=$LabToken" }
    $locksNow = @(Get-AzResourceLock @az)
    $own = @($locksNow | Where-Object { $_.ResourceId -and $_.ResourceId.ToLowerInvariant().StartsWith($Id.ToLowerInvariant() + '/providers/microsoft.authorization/locks/') } | ForEach-Object { $_.ResourceId.ToLowerInvariant() } | Sort-Object)
    $rgId = "/subscriptions/$SubscriptionId/resourceGroups/$($now.ResourceGroupName)".ToLowerInvariant()
    $inherited = @($locksNow | Where-Object { $_.ResourceId -and ($_.ResourceId.ToLowerInvariant().StartsWith($rgId + '/providers/microsoft.authorization/locks/') -or $_.ResourceId.ToLowerInvariant().StartsWith("/subscriptions/$($SubscriptionId.ToLowerInvariant())/providers/microsoft.authorization/locks/")) })
    if ($inherited.Count -gt 0) { return 'an inherited lock appeared since discovery' }
    $before = @($Live.ownLocks | ForEach-Object { $_.id.ToLowerInvariant() } | Sort-Object)
    if ((($own -join '|') -ne ($before -join '|'))) { return 'its locks changed since discovery' }
    return $null
}

function Restore-LzAvdLock {
    param([Parameter(Mandatory)][object]$Lock, [Parameter(Mandatory)][string]$Scope)
    try {
        [void](New-AzResourceLock @az -LockName $Lock.name -LockLevel $Lock.level -LockNotes $Lock.notes -Scope $Scope -Force)
        $audit.lockChanges.Add([pscustomobject]@{ timestamp = (Get-Date).ToUniversalTime().ToString('o'); scope = $Scope; lock = $Lock.name; action = 'restored'; status = 'ok' })
    }
    catch {
        $audit.lockChanges.Add([pscustomobject]@{ timestamp = (Get-Date).ToUniversalTime().ToString('o'); scope = $Scope; lock = $Lock.name; action = 'restored'; status = 'failed'; error = $_.Exception.Message })
        Write-LzAvdLog -Level Warning -Message "Could not restore lock $($Lock.name) on $Scope after a failed delete: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# phase 0: discovery + candidate file
# ---------------------------------------------------------------------------------------------------------------------
try {
    $current = Invoke-LzAvdDiscovery
    $hash = Get-LzAvdItemHash -Entries (@($current.items) + @($current.resourceGroups)) -Subscription $SubscriptionId
    $candidateDoc = [ordered]@{
        schemaVersion  = 1
        generatedOn    = $runStart.ToString('o')
        generatedBy    = $audit.operator
        tenantId       = $audit.tenantId
        subscriptionId = $SubscriptionId
        labToken       = $LabToken
        itemsHash      = $hash
        approvedBy     = ''
        approvedOn     = ''
        items          = $current.items
        resourceGroups = $current.resourceGroups
    }
    $cdir = Split-Path -Parent $CandidateFile
    if ($cdir -and -not (Test-Path $cdir)) { New-Item -ItemType Directory -Path $cdir -Force -WhatIf:$false | Out-Null }
    [pscustomobject]$candidateDoc | ConvertTo-Json -Depth 8 | Set-Content -Path $CandidateFile -Encoding utf8 -WhatIf:$false
    $blockers = @($current.items | Where-Object blocker)
    Write-LzAvdLog -Message "Candidates in ${SubscriptionId}: $(@($current.items).Count) resources ($($blockers.Count) blockers, order 800), $(@($current.resourceGroups).Count) resource groups. Candidate file: $CandidateFile (hash $hash)"
    $current.items + $current.resourceGroups | Format-Table order, kind, name, type, @{ n = 'locks'; e = { @($_.ownLocks).Count } } -AutoSize | Out-String | ForEach-Object { Write-LzAvdLog -Message $_ }
    foreach ($b in $blockers) { $audit.blocked.Add([pscustomobject]@{ id = $b.id; type = $b.type; reason = 'type not in the deletion type list (order 800); handle by hand or extend the list' }) }
}
catch {
    Add-LzAvdAction -Phase 'discovery' -Id $SubscriptionId -Type 'subscription' -Action 'enumerate' -Status 'failed' -ErrorMessage $_.Exception.Message
    Write-LzAvdAudit -Result 'failed'
    throw
}

if (-not $Execute) {
    Write-LzAvdLog -Message 'Discovery only: nothing deleted. Have the owner approve entries in the candidate file, then re-run with -Execute -TenantId -ConfirmDeleteList.'
    Write-LzAvdAudit -Result 'discovery-complete'
    return [pscustomobject]@{ SubscriptionId = $SubscriptionId; Mode = 'WhatIf'; Candidates = $current.items; ResourceGroups = $current.resourceGroups; Deleted = @(); Refused = @(); Blocked = @($audit.blocked); CandidateFile = $CandidateFile; AuditFile = $AuditFile }
}

# ---------------------------------------------------------------------------------------------------------------------
# gates for the destructive phases
# ---------------------------------------------------------------------------------------------------------------------
$deleted = [System.Collections.Generic.List[string]]::new()
$refused = [System.Collections.Generic.List[object]]::new()
try {
    if (-not $TenantId) { throw '-Execute requires -TenantId so tenant and subscription are verified before anything is deleted. Nothing deleted.' }
    if ("$($ctx.Tenant.Id)" -ne $TenantId) { throw "Live context tenant $($ctx.Tenant.Id) differs from -TenantId $TenantId. Nothing deleted." }
    if (-not $ConfirmDeleteList) { throw '-Execute requires -ConfirmDeleteList <owner-approved JSON>. Nothing deleted.' }
    $validated = Test-LzAvdApprovedList -Path $ConfirmDeleteList -Current $current
    $approval = $validated.approval
    Write-LzAvdLog -Message "Approved list OK: approvedBy=$($approval.approvedBy) approvedOn=$($approval.approvedOn) hash=$($approval.itemsHash) file-sha256=$($validated.rawHash)"
}
catch {
    Add-LzAvdAction -Phase 'validate' -Id $SubscriptionId -Type 'approved-list' -Action 'validate' -Status 'failed' -ErrorMessage $_.Exception.Message
    Write-LzAvdAudit -Result 'refused'
    throw
}

function Stop-LzAvdOnFailure {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Throws or logs only; changes no state.')]
    param([string]$Message)
    if (-not $ContinueOnError) { throw "Stopped at first failure (pass -ContinueOnError to keep going): $Message" }
    Write-LzAvdLog -Level Warning -Message "Continuing after failure (-ContinueOnError): $Message"
}

# ---------------------------------------------------------------------------------------------------------------------
# phase 2 (separate run): empty resource groups only
# ---------------------------------------------------------------------------------------------------------------------
if ($DeleteEmptyResourceGroups) {
    $approvedGroups = @($validated.entries | Where-Object { $_['kind'] -eq 'resourceGroup' -and $_['approved'] -eq $true })
    Write-LzAvdLog -Message "Resource-group phase: $($approvedGroups.Count) approved group(s); no resources are deleted in this phase."
    foreach ($entry in $approvedGroups) {
        $id = [string]$entry['id']
        try {
            if (-not (Test-LzAvdResourceInSubscription -ResourceId $id -SubscriptionId $SubscriptionId)) { $refused.Add([pscustomobject]@{ Id = $id; Reason = 'outside the target subscription' }); Add-LzAvdAction -Phase 'rg' -Id $id -Type 'resourceGroup' -Action 'validate' -Status 'refused' -ErrorMessage 'outside the target subscription'; continue }
            $live = Get-LzAvdCurrentCandidate -Entry $entry -Current $current
            if (-not $live) { $refused.Add([pscustomobject]@{ Id = $id; Reason = 'not a live stray resource group (missing, renamed or lab-tagged)' }); Add-LzAvdAction -Phase 'rg' -Id $id -Type 'resourceGroup' -Action 'validate' -Status 'refused' -ErrorMessage 'not a live candidate'; continue }
            if (@($live.ownLocks).Count -gt 0) { $audit.blocked.Add([pscustomobject]@{ id = $id; type = $live.type; reason = 'locked resource group (locks are never removed in the resource-group phase)' }); Add-LzAvdAction -Phase 'rg' -Id $id -Type 'resourceGroup' -Action 'validate' -Status 'blocked' -ErrorMessage 'locked'; continue }
            # full re-enumeration of the group, any type; errors are fatal for the run
            $remaining = @(Get-AzResource @az -ResourceGroupName $live.name)
            if ($remaining.Count -gt 0) { $audit.skipped.Add([pscustomobject]@{ id = $id; reason = "not empty ($($remaining.Count) resource(s) remain: $(($remaining | Select-Object -First 5 -ExpandProperty ResourceId) -join ', '))" }); Add-LzAvdAction -Phase 'rg' -Id $id -Type 'resourceGroup' -Action 'enumerate' -Status 'skipped' -ErrorMessage "$($remaining.Count) resource(s) remain"; continue }
            if (-not $PSCmdlet.ShouldProcess($id, "DELETE empty resource group approved by $($approval.approvedBy) on $($approval.approvedOn)")) { Add-LzAvdAction -Phase 'rg' -Id $id -Type 'resourceGroup' -Action 'delete' -Status 'whatif'; continue }
            [void](Remove-AzResourceGroup @az -Id $id -Force)
            # final re-check
            $gone = $false
            try { $check = Get-AzResourceGroup @az -Id $id -ErrorAction Stop; $gone = ($null -eq $check) } catch { if ($_.Exception.Message -match '(?i)not ?found|does not exist|could not be found|404') { $gone = $true } else { throw } }
            if (-not $gone) { throw "Resource group $id still exists after deletion." }
            $deleted.Add($id)
            Add-LzAvdAction -Phase 'rg' -Id $id -Type 'resourceGroup' -Action 'delete' -Status 'deleted'
        }
        catch {
            Add-LzAvdAction -Phase 'rg' -Id $id -Type 'resourceGroup' -Action 'delete' -Status 'failed' -ErrorMessage $_.Exception.Message
            if ($_.Exception.Message -match 'Discovery failed|enumerat') { Write-LzAvdAudit -Result 'failed'; throw }
            try { Stop-LzAvdOnFailure -Message $_.Exception.Message } catch { Write-LzAvdAudit -Result 'failed'; throw }
        }
    }
    $audit.finalState = [pscustomobject]@{ resourceGroupsRemaining = @(Get-AzResourceGroup @az).Count }
    Write-LzAvdAudit -Result $(if ($whatIfRun) { 'execute-whatif-complete' } else { 'complete' })
    return [pscustomobject]@{ SubscriptionId = $SubscriptionId; Mode = $audit.mode; Candidates = $current.items; ResourceGroups = $current.resourceGroups; Deleted = $deleted.ToArray(); Refused = $refused.ToArray(); Blocked = @($audit.blocked); Skipped = @($audit.skipped); CandidateFile = $CandidateFile; AuditFile = $AuditFile }
}

# ---------------------------------------------------------------------------------------------------------------------
# phase 1: resources (never resource groups)
# ---------------------------------------------------------------------------------------------------------------------
$approvedItems = @($validated.entries | Where-Object { $_['kind'] -eq 'resource' -and $_['approved'] -eq $true } | Sort-Object { [int]$_['order'] }, { $_['id'] })
Write-LzAvdLog -Message "Resource phase: $($approvedItems.Count) approved entr$(if ($approvedItems.Count -eq 1) { 'y' } else { 'ies' }); resource groups are never deleted in this phase (use -DeleteEmptyResourceGroups in a separate run)."
foreach ($entry in $approvedItems) {
    $id = [string]$entry['id']
    $type = [string]$entry['type']
    $removedLocks = @()
    try {
        if (-not (Test-LzAvdResourceInSubscription -ResourceId $id -SubscriptionId $SubscriptionId)) { $refused.Add([pscustomobject]@{ Id = $id; Reason = 'outside the target subscription' }); Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'validate' -Status 'refused' -ErrorMessage 'outside the target subscription'; continue }
        # re-validate against the CURRENT candidate immediately before acting (same id and type)
        $live = Get-LzAvdCurrentCandidate -Entry $entry -Current $current
        if (-not $live) { $refused.Add([pscustomobject]@{ Id = $id; Reason = "not a live stray candidate with type '$type' (contains '$LabToken', tagged project=$LabToken, type changed, or gone)" }); Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'validate' -Status 'refused' -ErrorMessage 'not a live candidate'; continue }
        if ($live.blocker) { $refused.Add([pscustomobject]@{ Id = $id; Reason = 'blocker: type is not in the deletion type list (order 800)' }); Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'validate' -Status 'refused' -ErrorMessage 'blocker type'; continue }
        if (@($live.inheritedLocks).Count -gt 0) { $audit.blocked.Add([pscustomobject]@{ id = $id; type = $type; reason = "inherited lock(s) at resource-group/subscription scope are never removed: $($live.inheritedLocks -join ', ')" }); Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'validate' -Status 'blocked' -ErrorMessage 'inherited lock'; continue }
        $wantsLockRemoval = $RemoveLocks -and $entry.ContainsKey('removeLock') -and $entry['removeLock'] -eq $true
        if (@($live.ownLocks).Count -gt 0 -and -not $wantsLockRemoval) { $audit.blocked.Add([pscustomobject]@{ id = $id; type = $type; reason = "locked ($(@($live.ownLocks | ForEach-Object { $_.name }) -join ', ')); needs -RemoveLocks and removeLock=true in the approved entry" }); Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'validate' -Status 'blocked' -ErrorMessage 'locked'; continue }

        $isVault = ($type -ieq 'Microsoft.KeyVault/vaults')
        $vault = $null
        if ($isVault) {
            foreach ($cmd in 'Get-AzKeyVault', 'Remove-AzKeyVault') { if (-not (Test-LzAvdCommand -Name $cmd)) { throw "Az.KeyVault cmdlet '$cmd' not available." } }
            $vault = Get-AzKeyVault @az -VaultName $live.name -ResourceGroupName $live.resourceGroup
            if (-not $vault) { throw "Key Vault $($live.name) not readable." }
            $softDelete = [bool]$vault.EnableSoftDelete
            $purgeProtection = [bool]$vault.EnablePurgeProtection
            Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'inspect-keyvault' -Status 'ok' -ErrorMessage "softDelete=$softDelete purgeProtection=$purgeProtection"
            if (-not $softDelete -and -not ($entry.ContainsKey('acknowledgePermanent') -and $entry['acknowledgePermanent'] -eq $true)) {
                $audit.blocked.Add([pscustomobject]@{ id = $id; type = $type; reason = 'soft-delete is disabled: deletion is permanent and needs acknowledgePermanent=true in the approved entry' })
                Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'validate' -Status 'blocked' -ErrorMessage 'permanent deletion not acknowledged'
                continue
            }
        }

        # discovery is a snapshot: re-read the live resource and its locks right before acting (tags, type, locks can change after discovery)
        $why = Test-LzAvdStillEligible -Id $id -Type $type -Live $live
        if ($why) { $refused.Add([pscustomobject]@{ Id = $id; Reason = "changed since discovery: $why" }); Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'validate' -Status 'refused' -ErrorMessage "changed since discovery: $why"; continue }

        if (-not $PSCmdlet.ShouldProcess($id, "DELETE $type approved by $($approval.approvedBy) on $($approval.approvedOn)")) { Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'delete' -Status 'whatif'; continue }

        foreach ($lock in @($live.ownLocks)) {
            [void](Remove-AzResourceLock @az -LockId $lock.id -Force)
            $removedLocks += $lock
            $audit.lockChanges.Add([pscustomobject]@{ timestamp = (Get-Date).ToUniversalTime().ToString('o'); scope = $id; lock = $lock.name; level = $lock.level; action = 'removed'; status = 'ok' })
            Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action "remove-lock $($lock.name)" -Status 'ok'
        }

        if ($isVault) {
            [void](Remove-AzKeyVault @az -VaultName $live.name -ResourceGroupName $live.resourceGroup -Force)
            [void](Wait-LzAvdResourceGone -Id $id -TimeoutMinutes $DeleteTimeoutMinutes)
            Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'delete' -Status 'deleted'
            $deleted.Add($id)
            $wantsPurge = $entry.ContainsKey('purge') -and $entry['purge'] -eq $true
            if ([bool]$vault.EnableSoftDelete -and -not $wantsPurge) {
                Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'purge' -Status 'skipped' -ErrorMessage 'soft-deleted vault left recoverable; set purge=true on the approved entry to purge it permanently (the name stays reserved until then)'
            }
            elseif ([bool]$vault.EnableSoftDelete) {
                if ([bool]$vault.EnablePurgeProtection) {
                    Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'purge' -Status 'skipped' -ErrorMessage 'purge protection on: name reusable after the retention period only'
                }
                else {
                    try {
                        $deadline = (Get-Date).AddMinutes($DeleteTimeoutMinutes)
                        do {
                            $removed = Get-AzKeyVault @az -VaultName $live.name -Location $vault.Location -InRemovedState
                            if ($removed) { break }
                            if ((Get-Date) -gt $deadline) { throw 'vault never appeared in the removed state' }
                            Start-Sleep -Seconds $PollSeconds
                        } while ($true)
                        [void](Remove-AzKeyVault @az -VaultName $live.name -Location $vault.Location -InRemovedState -Force)
                        $deadline = (Get-Date).AddMinutes($DeleteTimeoutMinutes)
                        do {
                            $removed = Get-AzKeyVault @az -VaultName $live.name -Location $vault.Location -InRemovedState
                            if (-not $removed) { break }
                            if ((Get-Date) -gt $deadline) { throw 'vault still listed in the removed state after purge' }
                            Start-Sleep -Seconds $PollSeconds
                        } while ($true)
                        Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'purge' -Status 'purged'
                    }
                    catch {
                        Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'purge' -Status 'purge-failed' -ErrorMessage $_.Exception.Message
                        Stop-LzAvdOnFailure -Message "purge of $($live.name) failed: $($_.Exception.Message)"
                    }
                }
            }
            continue
        }

        [void](Remove-AzResource @az -ResourceId $id -Force)
        [void](Wait-LzAvdResourceGone -Id $id -TimeoutMinutes $DeleteTimeoutMinutes)
        $deleted.Add($id)
        Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'delete' -Status 'deleted'
        if ($type -ieq 'Microsoft.HybridCompute/machines') {
            Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'note' -Status 'info' -ErrorMessage 'Azure record deleted only: the Connected Machine agent and its extensions keep running on the host until removed there (azcmagent disconnect --force-local-only, then uninstall).'
        }
    }
    catch {
        Add-LzAvdAction -Phase 'resources' -Id $id -Type $type -Action 'delete' -Status 'failed' -ErrorMessage $_.Exception.Message
        foreach ($lock in $removedLocks) { Restore-LzAvdLock -Lock $lock -Scope $id }
        try { Stop-LzAvdOnFailure -Message $_.Exception.Message } catch { Write-LzAvdAudit -Result 'failed'; throw }
    }
}

try {
    $after = Invoke-LzAvdDiscovery
    $audit.finalState = [pscustomobject]@{ candidatesRemaining = @($after.items).Count; blockersRemaining = @($after.items | Where-Object blocker).Count; resourceGroupsRemaining = @($after.resourceGroups).Count }
}
catch {
    $audit.finalState = [pscustomobject]@{ error = $_.Exception.Message }
}
Write-LzAvdAudit -Result $(if ($whatIfRun) { 'execute-whatif-complete' } else { 'complete' })
[pscustomobject]@{ SubscriptionId = $SubscriptionId; Mode = $audit.mode; Candidates = $current.items; ResourceGroups = $current.resourceGroups; Deleted = $deleted.ToArray(); Refused = $refused.ToArray(); Blocked = @($audit.blocked); Skipped = @($audit.skipped); CandidateFile = $CandidateFile; AuditFile = $AuditFile }
