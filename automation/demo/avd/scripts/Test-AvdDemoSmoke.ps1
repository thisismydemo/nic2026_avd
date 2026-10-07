#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-session smoke test for the AVD Anywhere live beats (outline §0, §2-§5, §8): pools, hosts, routing groups,
    FSLogix path, Arc machines, Insights, recordings. Pass/fail list and exit code. Read-only.
.DESCRIPTION
    Checks: no transcript, Az context, no session-host fault lock; workspace and the three host pools exist; every pool
    has >= 2 hosts and all are Available with no lingering sessions; each demo user is routed to at most one realm
    group (Graph); the FSLogix storage account resolves (to a private address when enable_private_endpoints is true) and TCP 445 is reachable from the jump
    server; the Hybrid Arc machines are Connected with the CloudDeviceExtension Succeeded; AVD Insights has a recent
    heartbeat from every host; the fallback recordings folder exists.
.PARAMETER SkipGraph
    Skip the group-membership check.
.PARAMETER SkipAzure
    Skip every Azure read (offline authoring).
.PARAMETER PassThru
    Return the check rows instead of exiting.
.EXAMPLE
    ./Test-AvdDemoSmoke.ps1
#>
[CmdletBinding()]
[OutputType([pscustomobject[]])]
param(
    [switch] $SkipGraph,
    [switch] $SkipAzure,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoCommon = Join-Path $PSScriptRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1'
if (-not (Get-Module -Name DemoCommon)) { Import-Module $demoCommon -Global }

$config = Get-DemoConfig -Scope 'avd'
Initialize-DemoScreenHygiene -Config $config
$names = Get-DemoAvdNameSet -Config $config
$checks = [System.Collections.Generic.List[pscustomobject]]::new()
$realms = @('azure', 'azl', 'hybrid')

$checks.Add((New-DemoCheck -Section '0 console' -Name 'No transcript active' -Passed (-not (Test-DemoTranscriptActive))))
$checks.Add((New-DemoCheck -Section '0 console' -Name 'Az context' -Passed ($SkipAzure -or (Test-DemoAzContext)) -Skipped:$SkipAzure))
$locks = @(Get-DemoFaultLock -Scope 'avd')
$checks.Add((New-DemoCheck -Section '0 console' -Name 'No session-host fault active' -Passed ($locks.Count -eq 0) -Detail $(if ($locks.Count -eq 0) { 'clean' } else { (@($locks | ForEach-Object { "$($_.Fault) on $($_.Target)" }) -join '; ') })))

# FSLogix path (public endpoint by default, D-029; private endpoint when enable_private_endpoints is true)
$org = Get-DemoConfigValue -Config $config -Key 'org'; $token = Get-DemoConfigValue -Config $config -Key 'token'; $region = Get-DemoConfigValue -Config $config -Key 'location_short'
$storage = New-NIC26ResourceName -Type st -Purpose 'fslogix' -Org $org -Token $token -Region $region
$fqdn = "$storage.file.core.windows.net"
$addresses = @(Resolve-DemoDnsName -Name $fqdn)
$usePrivate = [bool](Get-DemoConfigValue -Config $config -Key 'enable_private_endpoints')
$private = ($addresses.Count -gt 0 -and @($addresses | Where-Object { -not (Test-DemoPrivateAddress -Address $_) }).Count -eq 0)
$resolvedOk = if ($usePrivate) { $private } else { $addresses.Count -gt 0 }
$resolveName = if ($usePrivate) { "$storage resolves to the private endpoint" } else { "$storage resolves (public endpoint, D-029)" }
$checks.Add((New-DemoCheck -Section '6 profiles' -Name $resolveName -Passed $resolvedOk -Detail $(if ($addresses.Count -eq 0) { 'does not resolve' } elseif ($private) { 'private address' } else { 'public address' })))
$checks.Add((New-DemoCheck -Section '6 profiles' -Name 'SMB 445 reachable from the jump server' -Passed ($addresses.Count -gt 0 -and (Test-DemoTcpPort -ComputerName $fqdn -Port 445))))

if (-not $SkipAzure) {
    try {
        $ws = Get-DemoWorkspace -ResourceGroupName $names.HostPoolResourceGroup -Name $names.Workspace
        $checks.Add((New-DemoCheck -Section '2 foundation' -Name "Workspace $($names.Workspace)" -Passed ($ws.AppGroupCount -ge 3) -Detail "$($ws.AppGroupCount) app group(s) (3 expected)"))
    }
    catch { $checks.Add((New-DemoCheck -Section '2 foundation' -Name "Workspace $($names.Workspace)" -Passed $false -Detail (($_.Exception.Message -split "`n")[0]))) }

    $allHosts = @()
    foreach ($r in $realms) {
        $pool = $names.Realms[$r].HostPool
        try {
            $null = Get-DemoHostPool -ResourceGroupName $names.HostPoolResourceGroup -Name $pool
            $hosts = @(Get-DemoSessionHostList -ResourceGroupName $names.HostPoolResourceGroup -HostPoolName $pool)
            $allHosts += $hosts
            $avail = @($hosts | Where-Object { $_.Status -eq 'Available' -and $_.AllowNewSession })
            $checks.Add((New-DemoCheck -Section "8.1 $r" -Name "$pool has >= 2 hosts, all Available" -Passed ($hosts.Count -ge 2 -and $avail.Count -eq $hosts.Count) -Detail ((@($hosts | ForEach-Object { "$($_.Name)=$($_.Status)" })) -join ', ')))
            $sessions = @(Get-DemoUserSessionList -ResourceGroupName $names.HostPoolResourceGroup -HostPoolName $pool)
            $checks.Add((New-DemoCheck -Section "8.1 $r" -Name "$pool has no lingering session" -Passed ($sessions.Count -eq 0) -Detail "$($sessions.Count) session(s)"))
        }
        catch { $checks.Add((New-DemoCheck -Section "8.1 $r" -Name "$pool reachable" -Passed $false -Detail (($_.Exception.Message -split "`n")[0]))) }
    }

    # Hybrid Arc machines
    try {
        $machines = @(Get-DemoAzResourceList -ResourceGroupName $names.ArcResourceGroup -ResourceType 'Microsoft.HybridCompute/machines')
        $hybridVms = @(Get-DemoConfigValue -Config $config -Key 'hybrid.vms' | ForEach-Object { [string](Get-DemoConfigValue -Config $_ -Key 'name') })
        foreach ($vmName in $hybridVms) {
            $m = @($machines | Where-Object { $_.Name -eq $vmName }) | Select-Object -First 1
            $status = if ($m -and $m.Properties) { [string](Get-DemoConfigValue -Config $m.Properties -Key 'status') } else { 'not found' }
            $checks.Add((New-DemoCheck -Section '5 hybrid' -Name "Arc machine $vmName Connected" -Passed ($status -eq 'Connected') -Detail $status))
        }
        $extensions = @(Get-DemoAzResourceList -ResourceGroupName $names.ArcResourceGroup -ResourceType 'Microsoft.HybridCompute/machines/extensions' | Where-Object { $_.Name -like '*CloudDeviceExtension*' })
        $okExt = @($extensions | Where-Object { $_.Properties -and (Get-DemoConfigValue -Config $_.Properties -Key 'provisioningState') -eq 'Succeeded' })
        $checks.Add((New-DemoCheck -Section '5 hybrid' -Name 'CloudDeviceExtension Succeeded on every Hybrid host' -Passed ($hybridVms.Count -gt 0 -and $okExt.Count -ge $hybridVms.Count) -Detail "$($okExt.Count)/$($hybridVms.Count)"))
    }
    catch { $checks.Add((New-DemoCheck -Section '5 hybrid' -Name 'Arc machines' -Passed $false -Detail (($_.Exception.Message -split "`n")[0]))) }

    # Insights heartbeat
    $wsId = [string](Get-DemoConfigValue -Config $config -Key 'log_analytics_workspace_id')
    if ($wsId -and $allHosts.Count -gt 0) {
        try {
            $rows = @(Invoke-DemoLogQuery -WorkspaceId $wsId -Query 'Heartbeat | where TimeGenerated > ago(15m) | summarize LastBeat = max(TimeGenerated) by Computer' -TimespanHours 1)
            $seen = @($rows | ForEach-Object { ([string]$_.Computer -split '\.')[0].ToLowerInvariant() })
            $missing = @($allHosts | ForEach-Object { $_.Name.ToLowerInvariant() } | Where-Object { $_ -notin $seen })
            $checks.Add((New-DemoCheck -Section '8.5 insights' -Name 'AVD Insights heartbeat from every host (< 15 min)' -Passed ($missing.Count -eq 0) -Detail $(if ($missing.Count -eq 0) { "$($allHosts.Count) host(s)" } else { "missing: $($missing -join ', ')" })))
        }
        catch { $checks.Add((New-DemoCheck -Section '8.5 insights' -Name 'AVD Insights heartbeat' -Passed $false -Detail (($_.Exception.Message -split "`n")[0]))) }
    }
    else {
        $checks.Add((New-DemoCheck -Section '8.5 insights' -Name 'AVD Insights heartbeat' -Passed $false -Detail $(if (-not $wsId) { 'log_analytics_workspace_id empty' } else { 'no hosts listed' })))
    }

    # routing: each demo user in at most one realm group
    if (-not $SkipGraph) {
        try {
            $members = @{}
            foreach ($r in $realms) { $members[$r] = @(Get-DemoGroupMemberIdList -GroupId (Get-DemoGroupId -DisplayName $names.Realms[$r].Group)) }
            foreach ($u in @(Get-DemoConfigValue -Config $config -Key 'demo_users')) {
                $upn = [string](Get-DemoConfigValue -Config $u -Key 'upn')
                $userRealm = [string](Get-DemoConfigValue -Config $u -Key 'realm')
                if ($userRealm -notin $realms) { continue }
                $id = Get-DemoUserId -UserPrincipalName $upn
                $in = @($realms | Where-Object { $id -in $members[$_] })
                $checks.Add((New-DemoCheck -Section '8.2 routing' -Name ("{0} routed to one realm" -f ($upn -split '@')[0]) -Passed ($in.Count -le 1) -Detail $(if ($in.Count -eq 0) { 'no realm yet (Switch-UserHostPool assigns live)' } else { $in -join ', ' })))
            }
        }
        catch { $checks.Add((New-DemoCheck -Section '8.2 routing' -Name 'Realm group membership' -Passed $false -Detail (($_.Exception.Message -split "`n")[0]))) }
    }
}

$fallback = Join-Path $PSScriptRoot '..' '..' '..' '..' 'presentation' 'avd' 'fallback'
$clips = if (Test-Path -LiteralPath $fallback) { @(Get-ChildItem -Path $fallback -File -ErrorAction SilentlyContinue).Count } else { -1 }
$checks.Add((New-DemoCheck -Section 'fallback' -Name 'Recorded backups folder' -Passed ($clips -gt 0) -Detail $(if ($clips -lt 0) { 'presentation/avd/fallback missing' } else { "$clips file(s)" })))

$all = $checks.ToArray()
Write-DemoCheckTable -Check $all -Title 'AVD Anywhere smoke test'
$code = Get-DemoCheckExitCode -Check $all
if ($PassThru) { return $all }
exit $code
