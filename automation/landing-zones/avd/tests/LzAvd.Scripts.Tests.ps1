#Requires -Version 7.0
<#
    Pester 5 - script safety for lz-avd (automation/CONTRACT.md section 7).
    Static (AST) checks on every script plus behavioural checks on the destructive scripts with stubbed Az cmdlets.
    No Azure call is made.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester 5: BeforeAll variables are consumed inside It and Mock blocks (see shared PSScriptAnalyzerSettings.psd1 note).')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mock bodies resolve $script: to the mocked command scope, so one global list carries the deleted-id state and is removed in AfterAll.')]
param()

BeforeDiscovery {
    $script:solutionRoot = Split-Path -Parent $PSScriptRoot
    $script:scriptsDir = Join-Path $script:solutionRoot 'scripts'
    $script:allScripts = Get-ChildItem -Path $script:scriptsDir -Filter '*.ps1' | Where-Object { $_.Name -ne 'LzAvd.Common.ps1' }
    $script:stateChanging = @('Invoke-LzAvdDeploy.ps1', 'Register-AvdProviders.ps1', 'New-AvdEntraGroups.ps1', 'New-AvdDemoUsers.ps1', 'Set-AvdStorageEntraKerberos.ps1', 'Remove-StrayAvdLzResources.ps1', 'New-AvdLzTeardownPlan.ps1', 'Set-AvdEntraSso.ps1', 'New-AvdConditionalAccess.ps1')
    $script:secretHandling = @('New-AvdEntraGroups.ps1', 'New-AvdDemoUsers.ps1')
}

Describe 'lz-avd script conventions' -ForEach ($allScripts | ForEach-Object { @{ File = $_ } }) {
    BeforeAll {
        $tokens = $null; $parseErrors = $null
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$tokens, [ref]$parseErrors)
        $script:parseErrors = $parseErrors
        $script:content = Get-Content -Path $File.FullName -Raw
        $script:paramBlock = $script:ast.ParamBlock
    }

    It '<File.Name> parses without errors' {
        $script:parseErrors.Count | Should -Be 0
    }

    It '<File.Name> declares #Requires -Version 7.0, StrictMode and ErrorActionPreference Stop' {
        $script:content | Should -Match '#Requires -Version 7\.0'
        $script:content | Should -Match "Set-StrictMode -Version Latest"
        $script:content | Should -Match "\`$ErrorActionPreference = 'Stop'"
    }

    It '<File.Name> has comment-based help with SYNOPSIS' {
        $script:content | Should -Match '\.SYNOPSIS'
    }

    It '<File.Name> never starts a transcript, writes host output or converts plaintext secrets' {
        $script:content | Should -Not -Match 'Start-Transcript'
        $script:content | Should -Not -Match 'Write-Host'
        $script:content | Should -Not -Match 'ConvertTo-SecureString\s+-?\w*\s*-AsPlainText'
    }

    It '<File.Name> contains no tenant-specific literals (the private tenant prefixes)' {
        # patterns are assembled at run time so this file does not itself carry the words it forbids
        $forbidden = '(?i)' + ('tier' + 'point') + '|' + ('tp' + 'poc') + '|[^a-z]' + ('tp' + '-')
        $script:content | Should -Not -Match $forbidden
    }
}

Describe 'state-changing scripts' -ForEach ($stateChanging | ForEach-Object { @{ Name = $_ } }) {
    BeforeAll {
        $path = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\$Name"
        $tokens = $null; $errors = $null
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $script:content = Get-Content -Path $path -Raw
    }

    It '<Name> uses [CmdletBinding(SupportsShouldProcess)]' {
        $attr = $script:ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
        $attr | Should -Not -BeNullOrEmpty
        ($attr.NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' }) | Should -Not -BeNullOrEmpty
    }

    It '<Name> exposes an -Execute switch and defaults to WhatIf without it' {
        $execute = $script:ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Execute' }
        $execute | Should -Not -BeNullOrEmpty
        $execute.StaticType.Name | Should -Be 'SwitchParameter'
        $script:content | Should -Match 'if \(-not \$Execute\) \{ \$WhatIfPreference = \$true \}'
    }

    It '<Name> guards every change with ShouldProcess' {
        $script:content | Should -Match '\$PSCmdlet\.ShouldProcess\('
    }
}

Describe 'secret-handling scripts' -ForEach ($secretHandling | ForEach-Object { @{ Name = $_ } }) {
    It '<Name> insists on the Windows jump server before touching values' {
        $content = Get-Content -Path (Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\$Name") -Raw
        $content | Should -Match 'Assert-LzAvdWindowsHost'
        $content | Should -Match 'Clear-LzAvdCharArray'
        $content | Should -Not -Match 'Write-LzAvdLog[^\n]*\$passwordChars'
    }
}

Describe 'LzAvd.Common helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\LzAvd.Common.ps1')
    }

    It 'Test-LzAvdResourceInSubscription accepts only the exact subscription' {
        $sub = '00000000-0000-0000-0000-000000000000'
        Test-LzAvdResourceInSubscription -ResourceId "/subscriptions/$sub/resourceGroups/rg-x" -SubscriptionId $sub | Should -BeTrue
        Test-LzAvdResourceInSubscription -ResourceId "/subscriptions/${sub}1/resourceGroups/rg-x" -SubscriptionId $sub | Should -BeFalse
        Test-LzAvdResourceInSubscription -ResourceId '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-x' -SubscriptionId $sub | Should -BeFalse
    }

    It 'Test-LzAvdIpInCidr matches the private endpoint subnet' {
        Test-LzAvdIpInCidr -IpAddress '10.100.9.5' -Cidr '10.100.9.0/26' | Should -BeTrue
        Test-LzAvdIpInCidr -IpAddress '10.100.9.70' -Cidr '10.100.9.0/26' | Should -BeFalse
    }

    It 'New-LzAvdRandomPassword yields a complex in-memory password and Clear zeroes it' {
        $chars = New-LzAvdRandomPassword -Length 24 -Confirm:$false
        $chars.Length | Should -Be 24
        ([string]::new($chars)) | Should -Match '[A-Z]'
        ([string]::new($chars)) | Should -Match '[a-z]'
        ([string]::new($chars)) | Should -Match '[0-9]'
        Clear-LzAvdCharArray -Characters $chars -Confirm:$false
        @($chars | Where-Object { $_ -ne [char]0 }).Count | Should -Be 0
    }
}

Describe 'Remove-StrayAvdLzResources safety' {
    BeforeAll {
        $script:scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Remove-StrayAvdLzResources.ps1'
        $sub = '00000000-0000-0000-0000-000000000000'
        $otherSub = '11111111-1111-1111-1111-111111111111'
        $tenant = '00000000-0000-0000-0000-000000000000'
        # Stub the Az surface the script needs (every call carries -DefaultProfile), then mock it.
        function global:Get-AzContext { [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'operator@contoso.com' }; Tenant = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000000' }; Subscription = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000000' } } }
        function global:Set-AzContext { param($Subscription, $Tenant) Get-AzContext }
        function global:Get-AzResource { param($DefaultProfile, $ResourceId, $ResourceGroupName, $ErrorAction) }
        function global:Get-AzResourceGroup { param($DefaultProfile, $Id, $ErrorAction) }
        function global:Get-AzResourceLock { param($DefaultProfile) }
        function global:Remove-AzResource { param($DefaultProfile, $ResourceId, [switch]$Force) }
        function global:Remove-AzResourceGroup { param($DefaultProfile, $Id, [switch]$Force) }
        function global:Remove-AzResourceLock { param($DefaultProfile, $LockId, [switch]$Force) }
        function global:Get-AzKeyVault { param($DefaultProfile, $VaultName, $ResourceGroupName, $Location, [switch]$InRemovedState) }
        function global:Remove-AzKeyVault { param($DefaultProfile, $VaultName, $ResourceGroupName, $Location, [switch]$InRemovedState, [switch]$Force) }
        function global:New-AzResourceLock { param($DefaultProfile, $LockName, $LockLevel, $LockNotes, $Scope, [switch]$Force) }
        $stray = [pscustomobject]@{ ResourceId = "/subscriptions/$sub/resourceGroups/rg-old/providers/Microsoft.HybridCompute/machines/OLD-MACHINE"; Name = 'OLD-MACHINE'; ResourceType = 'Microsoft.HybridCompute/machines'; ResourceGroupName = 'rg-old'; Tags = @{} }
        $lockedDisk = [pscustomobject]@{ ResourceId = "/subscriptions/$sub/resourceGroups/rg-old/providers/Microsoft.Compute/disks/OLD-DISK"; Name = 'OLD-DISK'; ResourceType = 'Microsoft.Compute/disks'; ResourceGroupName = 'rg-old'; Tags = @{} }
        $blocker = [pscustomobject]@{ ResourceId = "/subscriptions/$sub/resourceGroups/rg-old/providers/Microsoft.RecoveryServices/vaults/OLD-RSV"; Name = 'OLD-RSV'; ResourceType = 'Microsoft.RecoveryServices/vaults'; ResourceGroupName = 'rg-old'; Tags = @{} }
        $lab = [pscustomobject]@{ ResourceId = "/subscriptions/$sub/resourceGroups/rg-iic-nic26-avd-eus-01/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-iic-nic26-avd-hostpool-eus-01"; Name = 'id-iic-nic26-avd-hostpool-eus-01'; ResourceType = 'Microsoft.ManagedIdentity/userAssignedIdentities'; ResourceGroupName = 'rg-iic-nic26-avd-eus-01'; Tags = @{ project = 'nic26' } }
        $tagged = [pscustomobject]@{ ResourceId = "/subscriptions/$sub/resourceGroups/rg-other/providers/Microsoft.Storage/storageAccounts/plainname"; Name = 'plainname'; ResourceType = 'Microsoft.Storage/storageAccounts'; ResourceGroupName = 'rg-other'; Tags = @{ project = 'nic26' } }
        $oldRg = [pscustomobject]@{ ResourceId = "/subscriptions/$sub/resourceGroups/rg-old"; ResourceGroupName = 'rg-old'; Tags = @{} }
        $emptyRg = [pscustomobject]@{ ResourceId = "/subscriptions/$sub/resourceGroups/rg-empty"; ResourceGroupName = 'rg-empty'; Tags = @{} }
        $diskLock = [pscustomobject]@{ Name = 'keep'; ResourceId = "$($lockedDisk.ResourceId)/providers/Microsoft.Authorization/locks/keep"; Properties = [pscustomobject]@{ level = 'CanNotDelete'; notes = 'test' } }
        $allResources = @($stray, $lockedDisk, $blocker, $lab, $tagged)
        $allGroups = @($oldRg, $emptyRg)

        function New-ApprovedList {
            # builds an owner-approved list from a discovery run and a per-id edit block
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper that builds an in-memory object; changes no state.')]
            param([string]$CandidatePath, [string]$OutPath, [hashtable]$Edits = @{}, [string]$GeneratedOn, [string]$SubscriptionOverride, [switch]$Tamper)
            $doc = Get-Content $CandidatePath -Raw | ConvertFrom-Json -AsHashtable
            foreach ($entry in @($doc.items) + @($doc.resourceGroups)) {
                if ($Edits.ContainsKey($entry.id)) { foreach ($k in $Edits[$entry.id].Keys) { $entry[$k] = $Edits[$entry.id][$k] } }
            }
            $doc.approvedBy = 'owner'; $doc.approvedOn = '2026-10-03'
            if ($GeneratedOn) { $doc.generatedOn = $GeneratedOn }
            if ($SubscriptionOverride) { $doc.subscriptionId = $SubscriptionOverride }
            if ($Tamper) { $doc.items += @{ kind = 'resource'; id = "/subscriptions/$sub/resourceGroups/rg-old/providers/Microsoft.Compute/disks/INJECTED"; type = 'Microsoft.Compute/disks'; approved = $true; order = 120 } }
            $doc | ConvertTo-Json -Depth 8 | Set-Content $OutPath
            return $OutPath
        }
        function Invoke-Discovery {
            param([string]$CandidatePath, [string]$AuditPath)
            return (& $script:scriptPath -SubscriptionId $sub -LabToken 'nic26' -CandidateFile $CandidatePath -AuditFile $AuditPath 6>$null 3>$null)
        }
    }
    AfterAll {
        Remove-Variable -Name Nic26TestDeletedIds, Nic26TestLockCalls, Nic26TestVault, Nic26TestPurged -Scope Global -ErrorAction SilentlyContinue
        foreach ($f in 'Get-AzKeyVault', 'Remove-AzKeyVault', 'Get-AzContext', 'Set-AzContext', 'Get-AzResource', 'Get-AzResourceGroup', 'Get-AzResourceLock', 'Remove-AzResource', 'Remove-AzResourceGroup', 'Remove-AzResourceLock', 'New-AzResourceLock') { Remove-Item -Path "function:global:$f" -ErrorAction SilentlyContinue }
    }
    BeforeEach {
        $global:Nic26TestDeletedIds = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Get-AzResource -MockWith {
            if ($ResourceId) { if ($global:Nic26TestDeletedIds -contains $ResourceId) { return $null } else { return ($allResources | Where-Object { $_.ResourceId -eq $ResourceId }) } }
            if ($ResourceGroupName) { return @($allResources | Where-Object { $_.ResourceGroupName -eq $ResourceGroupName -and $global:Nic26TestDeletedIds -notcontains $_.ResourceId }) }
            return @($allResources | Where-Object { $global:Nic26TestDeletedIds -notcontains $_.ResourceId })
        }
        Mock -CommandName Get-AzResourceGroup -MockWith { if ($Id) { return ($allGroups | Where-Object { $_.ResourceId -eq $Id -and $global:Nic26TestDeletedIds -notcontains $_.ResourceId }) } ; return @($allGroups | Where-Object { $global:Nic26TestDeletedIds -notcontains $_.ResourceId }) }
        Mock -CommandName Get-AzResourceLock -MockWith { @($diskLock) }
        Mock -CommandName Remove-AzResource -MockWith { $global:Nic26TestDeletedIds.Add($ResourceId) }
        Mock -CommandName Remove-AzResourceGroup -MockWith { $global:Nic26TestDeletedIds.Add($Id) }
        Mock -CommandName Remove-AzResourceLock -MockWith { }
        Mock -CommandName New-AzResourceLock -MockWith { }
        $script:cand = Join-Path $TestDrive 'candidates.json'
        $script:audit = Join-Path $TestDrive 'audit.json'
    }

    It 'discovery lists stray resources with order, marks unknown types as order-800 blockers, writes a hashed candidate file and deletes nothing' {
        $result = Invoke-Discovery -CandidatePath $script:cand -AuditPath $script:audit
        $result.Mode | Should -Be 'WhatIf'
        @($result.Candidates).Count | Should -Be 3
        ($result.Candidates | Where-Object { $_.name -eq 'OLD-MACHINE' }).order | Should -Be 100
        ($result.Candidates | Where-Object { $_.name -eq 'OLD-RSV' }).order | Should -Be 800
        ($result.Candidates | Where-Object { $_.name -eq 'OLD-RSV' }).blocker | Should -BeTrue
        ($result.Candidates | Where-Object { $_.name -eq 'OLD-DISK' }).ownLocks.Count | Should -Be 1
        @($result.ResourceGroups).Count | Should -Be 2
        @($result.Blocked).Count | Should -Be 1
        $doc = Get-Content $script:cand -Raw | ConvertFrom-Json
        $doc.itemsHash | Should -Match '^[0-9a-f]{64}$'
        $doc.subscriptionId | Should -Be $sub
        $doc.generatedOn | Should -Not -BeNullOrEmpty
        ($doc.items | ForEach-Object { $_.approved }) | Should -Not -Contain $true
        (Get-Content $script:audit -Raw | ConvertFrom-Json).result | Should -Be 'discovery-complete'
        Should -Invoke -CommandName Remove-AzResource -Times 0
        Should -Invoke -CommandName Remove-AzResourceGroup -Times 0
        Should -Invoke -CommandName Remove-AzResourceLock -Times 0
    }

    It 'discovery fails closed on an authorization error' {
        Mock -CommandName Get-AzResource -MockWith { throw 'AuthorizationFailed: the client does not have authorization to perform action Microsoft.Resources/subscriptions/resources/read' }
        { Invoke-Discovery -CandidatePath $script:cand -AuditPath $script:audit } | Should -Throw '*Discovery failed (authorization)*'
        (Get-Content $script:audit -Raw | ConvertFrom-Json).result | Should -Be 'failed'
    }

    It 'refuses -Execute without -TenantId or without an approved list' {
        { & $script:scriptPath -SubscriptionId $sub -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -Confirm:$false 6>$null 3>$null } | Should -Throw '*TenantId*'
        { & $script:scriptPath -SubscriptionId $sub -TenantId $tenant -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -Confirm:$false 6>$null 3>$null } | Should -Throw '*ConfirmDeleteList*'
        Should -Invoke -CommandName Remove-AzResource -Times 0
    }

    It 'rejects an approved list made of bare strings' {
        $list = Join-Path $TestDrive 'bare.json'
        Invoke-Discovery -CandidatePath $script:cand -AuditPath $script:audit | Out-Null
        $doc = Get-Content $script:cand -Raw | ConvertFrom-Json -AsHashtable
        $doc.items = @($stray.ResourceId); $doc.approvedBy = 'owner'; $doc.approvedOn = '2026-10-03'
        $doc | ConvertTo-Json -Depth 8 | Set-Content $list
        { & $script:scriptPath -SubscriptionId $sub -TenantId $tenant -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -ConfirmDeleteList $list -Confirm:$false 6>$null 3>$null } | Should -Throw '*is not an object*'
        Should -Invoke -CommandName Remove-AzResource -Times 0
    }

    It 'refuses a list for another subscription, a tampered list and a stale list (unless -AllowStaleList)' {
        Invoke-Discovery -CandidatePath $script:cand -AuditPath $script:audit | Out-Null
        $edits = @{ $stray.ResourceId = @{ approved = $true } }
        $wrong = New-ApprovedList -CandidatePath $script:cand -OutPath (Join-Path $TestDrive 'wrong.json') -Edits $edits -SubscriptionOverride $otherSub
        { & $script:scriptPath -SubscriptionId $sub -TenantId $tenant -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -ConfirmDeleteList $wrong -Confirm:$false 6>$null 3>$null } | Should -Throw '*is for subscription*'
        $tampered = New-ApprovedList -CandidatePath $script:cand -OutPath (Join-Path $TestDrive 'tampered.json') -Edits $edits -Tamper
        { & $script:scriptPath -SubscriptionId $sub -TenantId $tenant -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -ConfirmDeleteList $tampered -Confirm:$false 6>$null 3>$null } | Should -Throw '*itemsHash does not match*'
        $stale = New-ApprovedList -CandidatePath $script:cand -OutPath (Join-Path $TestDrive 'stale.json') -Edits $edits -GeneratedOn ((Get-Date).ToUniversalTime().AddHours(-30).ToString('o'))
        { & $script:scriptPath -SubscriptionId $sub -TenantId $tenant -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -ConfirmDeleteList $stale -Confirm:$false 6>$null 3>$null } | Should -Throw '*stale*'
        Should -Invoke -CommandName Remove-AzResource -Times 0
        $result = & $script:scriptPath -SubscriptionId $sub -TenantId $tenant -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -ConfirmDeleteList $stale -AllowStaleList -Confirm:$false 6>$null 3>$null
        $result.Deleted | Should -Be @($stray.ResourceId)
        Should -Invoke -CommandName Remove-AzResource -Times 1 -Exactly
    }

    It 'deletes only approved, re-validated, unlocked, in-subscription stray resources; blockers, locked and foreign ids are refused or blocked; resource groups untouched' {
        Invoke-Discovery -CandidatePath $script:cand -AuditPath $script:audit | Out-Null
        $foreign = "/subscriptions/$otherSub/resourceGroups/rg-old/providers/Microsoft.HybridCompute/machines/FOREIGN"
        $list = New-ApprovedList -CandidatePath $script:cand -OutPath (Join-Path $TestDrive 'approved.json') -Edits @{
            $stray.ResourceId      = @{ approved = $true }
            $lockedDisk.ResourceId = @{ approved = $true }          # locked, no removeLock -> blocked
            $blocker.ResourceId    = @{ approved = $true }          # order 800 -> refused
            $oldRg.ResourceId      = @{ approved = $true }          # resource groups never in this pass
        }
        # add a foreign id and a vanished id by hand, keeping the hash valid is impossible -> use -AllowStaleList path? No: integrity hash covers items; inject through the live set instead.
        $doc = Get-Content $list -Raw | ConvertFrom-Json -AsHashtable
        $doc.items += @{ kind = 'resource'; id = $foreign; type = 'Microsoft.HybridCompute/machines'; approved = $true; order = 100 }
        $hashInput = @($doc.items) + @($doc.resourceGroups) | ForEach-Object { "$($_.kind)|$($_.id)|$($_.type)".ToLowerInvariant() } | Sort-Object
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $doc.itemsHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($hashInput -join "`n") + "`n" + $sub))) -replace '-', '').ToLowerInvariant()
        $doc | ConvertTo-Json -Depth 8 | Set-Content $list
        $result = & $script:scriptPath -SubscriptionId $sub -TenantId $tenant -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -ConfirmDeleteList $list -AllowStaleList -Confirm:$false 6>$null 3>$null
        $result.Deleted | Should -Be @($stray.ResourceId)
        ($result.Refused | Where-Object { $_.Id -eq $foreign }).Reason | Should -Match 'outside the target subscription'
        ($result.Refused | Where-Object { $_.Id -eq $blocker.ResourceId }).Reason | Should -Match 'blocker'
        ($result.Blocked | Where-Object { $_.id -eq $lockedDisk.ResourceId }).reason | Should -Match 'locked'
        Should -Invoke -CommandName Remove-AzResource -Times 1 -Exactly -ParameterFilter { $ResourceId -eq $stray.ResourceId }
        Should -Invoke -CommandName Remove-AzResourceGroup -Times 0
        Should -Invoke -CommandName Remove-AzResourceLock -Times 0
        $auditDoc = Get-Content $script:audit -Raw | ConvertFrom-Json
        $auditDoc.operator | Should -Be 'operator@contoso.com'
        $auditDoc.mode | Should -Be 'execute-resources'
        ($auditDoc.actions | Where-Object { $_.status -eq 'deleted' }).id | Should -Be $stray.ResourceId
        $auditDoc.finalState.candidatesRemaining | Should -Be 2
    }

    It 'removes a lock only with -RemoveLocks plus removeLock=true, audits it and restores it when the delete fails' {
        Invoke-Discovery -CandidatePath $script:cand -AuditPath $script:audit | Out-Null
        $list = New-ApprovedList -CandidatePath $script:cand -OutPath (Join-Path $TestDrive 'locks.json') -Edits @{ $lockedDisk.ResourceId = @{ approved = $true; removeLock = $true } }
        Mock -CommandName Remove-AzResource -MockWith { throw 'Conflict: disk is attached' }
        { & $script:scriptPath -SubscriptionId $sub -TenantId $tenant -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -ConfirmDeleteList $list -RemoveLocks -Confirm:$false 6>$null 3>$null } | Should -Throw '*Stopped at first failure*'
        Should -Invoke -CommandName Remove-AzResourceLock -Times 1 -Exactly
        Should -Invoke -CommandName New-AzResourceLock -Times 1 -Exactly -ParameterFilter { $LockName -eq 'keep' -and $LockLevel -eq 'CanNotDelete' }
        $auditDoc = Get-Content $script:audit -Raw | ConvertFrom-Json
        ($auditDoc.lockChanges | ForEach-Object { $_.action }) | Should -Be @('removed', 'restored')
        $auditDoc.result | Should -Be 'failed'
    }

    It 'refuses to delete a resource that became lab-tagged after discovery (live re-read before acting)' {
        Invoke-Discovery -CandidatePath $script:cand -AuditPath $script:audit | Out-Null
        $list = New-ApprovedList -CandidatePath $script:cand -OutPath (Join-Path $TestDrive 'toctou-tag.json') -Edits @{ $stray.ResourceId = @{ approved = $true } }
        Mock -CommandName Get-AzResource -ParameterFilter { $ResourceId } -MockWith { [pscustomobject]@{ ResourceId = $ResourceId; Name = 'OLD-MACHINE'; ResourceType = 'Microsoft.HybridCompute/machines'; ResourceGroupName = 'rg-old'; Tags = @{ project = 'nic26' } } }
        $result = & $script:scriptPath -SubscriptionId $sub -TenantId $tenant -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -ConfirmDeleteList $list -AllowStaleList -Confirm:$false 6>$null 3>$null
        @($result.Deleted).Count | Should -Be 0
        ($result.Refused | Where-Object { $_.Id -eq $stray.ResourceId }).Reason | Should -Match 'changed since discovery'
        Should -Invoke -CommandName Remove-AzResource -Times 0 -Exactly
    }
    It 'refuses to delete a resource that gained a lock after discovery' {
        $global:Nic26TestLockCalls = 0
        Invoke-Discovery -CandidatePath $script:cand -AuditPath $script:audit | Out-Null
        $list = New-ApprovedList -CandidatePath $script:cand -OutPath (Join-Path $TestDrive 'toctou-lock.json') -Edits @{ $stray.ResourceId = @{ approved = $true } }
        $global:Nic26TestLockCalls = 0
        # first read (the run's own discovery) sees only the disk lock; every later read also sees a new lock on the stray machine
        Mock -CommandName Get-AzResourceLock -MockWith {
            $global:Nic26TestLockCalls++
            if ($global:Nic26TestLockCalls -le 1) { return @($diskLock) }
            return @($diskLock, [pscustomobject]@{ Name = 'new'; ResourceId = "$($stray.ResourceId)/providers/Microsoft.Authorization/locks/new"; Properties = [pscustomobject]@{ level = 'CanNotDelete'; notes = '' } })
        }
        $result = & $script:scriptPath -SubscriptionId $sub -TenantId $tenant -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -ConfirmDeleteList $list -AllowStaleList -Confirm:$false 6>$null 3>$null
        @($result.Deleted).Count | Should -Be 0
        ($result.Refused | Where-Object { $_.Id -eq $stray.ResourceId }).Reason | Should -Match 'locks changed since discovery'
        Should -Invoke -CommandName Remove-AzResource -Times 0 -Exactly
    }
    It 'deletes a soft-deleted vault but purges it only when the approved entry says purge=true' {
        $global:Nic26TestVault = [pscustomobject]@{ ResourceId = "/subscriptions/$sub/resourceGroups/rg-old/providers/Microsoft.KeyVault/vaults/OLD-KV"; Name = 'OLD-KV'; ResourceType = 'Microsoft.KeyVault/vaults'; ResourceGroupName = 'rg-old'; Tags = @{} }
        $global:Nic26TestPurged = $false
        Mock -CommandName Get-AzResource -MockWith {
            if ($ResourceId) { if ($global:Nic26TestDeletedIds -contains $ResourceId) { return $null } return $global:Nic26TestVault }
            if ($global:Nic26TestDeletedIds -contains $global:Nic26TestVault.ResourceId) { return @() }
            return @($global:Nic26TestVault)
        }
        Mock -CommandName Get-AzResourceGroup -MockWith { @() }
        Mock -CommandName Get-AzResourceLock -MockWith { @() }
        Mock -CommandName Get-AzKeyVault -MockWith {
            if ($InRemovedState) { if ($global:Nic26TestPurged) { return $null } return [pscustomobject]@{ VaultName = 'OLD-KV' } }
            return [pscustomobject]@{ VaultName = 'OLD-KV'; Location = 'eastus'; EnableSoftDelete = $true; EnablePurgeProtection = $false }
        }
        Mock -CommandName Remove-AzKeyVault -MockWith { if ($InRemovedState) { $global:Nic26TestPurged = $true } else { $global:Nic26TestDeletedIds.Add($global:Nic26TestVault.ResourceId) } }
        Invoke-Discovery -CandidatePath $script:cand -AuditPath $script:audit | Out-Null
        $noPurge = New-ApprovedList -CandidatePath $script:cand -OutPath (Join-Path $TestDrive 'vault-nopurge.json') -Edits @{ $global:Nic26TestVault.ResourceId = @{ approved = $true } }
        $r1 = & $script:scriptPath -SubscriptionId $sub -TenantId $tenant -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -ConfirmDeleteList $noPurge -AllowStaleList -Confirm:$false 6>$null 3>$null
        $r1.Deleted | Should -Be @($global:Nic26TestVault.ResourceId)
        Should -Invoke -CommandName Remove-AzKeyVault -Times 1 -Exactly -ParameterFilter { -not $InRemovedState }
        Should -Invoke -CommandName Remove-AzKeyVault -Times 0 -Exactly -ParameterFilter { $InRemovedState }
        $global:Nic26TestPurged | Should -BeFalse
        # second run: vault is back (a fresh test state), now with purge=true
        $global:Nic26TestDeletedIds.Clear()
        Invoke-Discovery -CandidatePath $script:cand -AuditPath $script:audit | Out-Null
        $withPurge = New-ApprovedList -CandidatePath $script:cand -OutPath (Join-Path $TestDrive 'vault-purge.json') -Edits @{ $global:Nic26TestVault.ResourceId = @{ approved = $true; purge = $true } }
        $null = & $script:scriptPath -SubscriptionId $sub -TenantId $tenant -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -ConfirmDeleteList $withPurge -AllowStaleList -Confirm:$false 6>$null 3>$null
        Should -Invoke -CommandName Remove-AzKeyVault -Times 1 -Exactly -ParameterFilter { $InRemovedState }
        $global:Nic26TestPurged | Should -BeTrue
    }

    It '-Execute -WhatIf validates the approved list but deletes nothing' {
        Invoke-Discovery -CandidatePath $script:cand -AuditPath $script:audit | Out-Null
        $list = New-ApprovedList -CandidatePath $script:cand -OutPath (Join-Path $TestDrive 'whatif.json') -Edits @{ $stray.ResourceId = @{ approved = $true } }
        $result = & $script:scriptPath -SubscriptionId $sub -TenantId $tenant -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -ConfirmDeleteList $list -WhatIf 6>$null 3>$null
        $result.Mode | Should -Be 'execute-whatif'
        @($result.Deleted).Count | Should -Be 0
        Should -Invoke -CommandName Remove-AzResource -Times 0
        $auditDoc = Get-Content $script:audit -Raw | ConvertFrom-Json
        ($auditDoc.actions | Where-Object { $_.status -eq 'whatif' }).id | Should -Be $stray.ResourceId
        $bad = New-ApprovedList -CandidatePath $script:cand -OutPath (Join-Path $TestDrive 'whatif-bad.json') -Edits @{ $stray.ResourceId = @{ approved = $true } } -Tamper
        { & $script:scriptPath -SubscriptionId $sub -TenantId $tenant -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -ConfirmDeleteList $bad -WhatIf 6>$null 3>$null } | Should -Throw '*itemsHash*'
    }

    It 'the resource-group phase only deletes approved, empty, unlocked groups after full re-enumeration and never deletes resources' {
        Invoke-Discovery -CandidatePath $script:cand -AuditPath $script:audit | Out-Null
        $list = New-ApprovedList -CandidatePath $script:cand -OutPath (Join-Path $TestDrive 'rgs.json') -Edits @{
            $stray.ResourceId   = @{ approved = $true }   # must be ignored in this phase
            $oldRg.ResourceId   = @{ approved = $true }   # not empty -> skipped
            $emptyRg.ResourceId = @{ approved = $true }   # empty -> deleted
        }
        $result = & $script:scriptPath -SubscriptionId $sub -TenantId $tenant -LabToken 'nic26' -CandidateFile $script:cand -AuditFile $script:audit -Execute -ConfirmDeleteList $list -DeleteEmptyResourceGroups -Confirm:$false 6>$null 3>$null
        $result.Mode | Should -Be 'execute-resource-groups'
        $result.Deleted | Should -Be @($emptyRg.ResourceId)
        ($result.Skipped | Where-Object { $_.id -eq $oldRg.ResourceId }).reason | Should -Match 'not empty'
        Should -Invoke -CommandName Remove-AzResource -Times 0
        Should -Invoke -CommandName Remove-AzResourceGroup -Times 1 -Exactly -ParameterFilter { $Id -eq $emptyRg.ResourceId }
        Should -Invoke -CommandName Get-AzResource -ParameterFilter { $ResourceGroupName -eq 'rg-empty' } -Times 1
    }
}

Describe 'New-AvdLzTeardownPlan safety' {
    BeforeAll {
        $script:scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\New-AvdLzTeardownPlan.ps1'
        $script:example = Join-Path (Split-Path -Parent $PSScriptRoot) 'terraform\terraform.example.tfvars.json'
        function global:Remove-AzResource { param($ResourceId, [switch]$Force) }
        function global:Remove-AzResourceGroup { param($Id, [switch]$Force) }
    }
    AfterAll {
        foreach ($f in 'Remove-AzResource', 'Remove-AzResourceGroup') { Remove-Item -Path "function:global:$f" -ErrorAction SilentlyContinue }
    }

    It 'produces an ordered plan without deleting anything by default' {
        Mock -CommandName Remove-AzResource -MockWith { }
        Mock -CommandName Remove-AzResourceGroup -MockWith { }
        $plan = Join-Path $TestDrive 'plan.json'
        $result = & $script:scriptPath -InputFile $script:example -OutputPlan $plan 6>$null
        $result.Mode | Should -Be 'WhatIf'
        Test-Path $plan | Should -BeTrue
        $items = $result.Items
        @($items | Where-Object Kind -EQ 'resourceGroup').Count | Should -Be 7
        @($items | Where-Object Kind -EQ 'peering').Count | Should -Be 2
        # resource groups come before subscription-scope objects, hub peering before resource groups
        ($items | Where-Object Kind -EQ 'peering' | Select-Object -First 1).Order | Should -BeLessThan ($items | Where-Object Kind -EQ 'resourceGroup' | Select-Object -First 1).Order
        ($items | Where-Object Kind -EQ 'resourceGroup' | Select-Object -Last 1).Order | Should -BeLessThan ($items | Where-Object Kind -EQ 'budget').Order
        # every item carries the lab token
        @($items | Where-Object { $_.Id -notmatch 'nic26' }).Count | Should -Be 0
        Should -Invoke -CommandName Remove-AzResource -Times 0
        Should -Invoke -CommandName Remove-AzResourceGroup -Times 0
    }
}
