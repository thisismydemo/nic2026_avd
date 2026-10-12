#Requires -Version 7.0
<#
.SYNOPSIS
End-to-end, idempotent build of the Azure Local realm session hosts from environment/avd/environment.yml.
.DESCRIPTION
Reads the azl_session_hosts section of the AVD environment file (and the subscription IDs), resolves every Azure ID
live (custom location, logical network, image, storage paths, DCR), checks the image and logical network are
Succeeded, writes an ARM JSON parameters file to the temp folder (removed after the run), then:
  1. Invoke-SessionHostsAzureLocalDeploy.ps1 (Bicep What-If, or deployment with -Execute): Arc machine, NIC on the
     logical network, VM instance on the host's storage path (API 2026-04-01-preview), AD join through
     JsonADDomainExtension into the AVD OU (D-050), Azure Monitor Agent and the DCR association.
  1b. Guest default route: the SDN host DHCP hands the static NIC its IP and DNS but no default gateway (found 12 Oct
     2026, also on the SOFS VMs), so the guest cannot reach Azure (Arc guest management), the DCs (AD join) or the
     SOFS. While the deployment waits for the join extension, the script adds a persistent 0.0.0.0/0 route to the
     logical network's next hop inside each guest over PowerShell Direct from the node that runs it.
  2. Merges the environment tags (project=nic26 and the realm tags) onto each Arc machine and NIC and reads them back.
  3. Register-AvdSessionHostsAzureLocal.ps1: a fresh registration token per host, passed only as an Arc Run Command
     protected parameter (K-7), then waits for Available.
Re-running is safe: the deployment is incremental and a host that is already Available in the pool is skipped by
the registration step. Without -Execute nothing changes (What-If and a plan of the registration).
.PARAMETER EnvironmentFile
Path to environment/avd/environment.yml.
.PARAMETER VmName
Limit the deployment, route stage and registration to these hosts (Arc machine names). Use it to add a host (for
example the GPU host) without re-sending the existing hosts' VM and join resources.
.PARAMETER GuestRouteOnly
Only apply the guest default route (stage 1b) to hosts that already exist, then stop.
.PARAMETER SkipRegistration
Deploy only; do not register the hosts with the host pool.
.PARAMETER Execute
Apply. Without it only What-If and plans run.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers inside a script that is gated as a whole (-Execute or -WhatIf); they never run on their own.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$EnvironmentFile,
    [switch]$SkipRegistration,
    # Only (re)apply the guest default route on the existing hosts (see stage 1b).
    [string[]]$VmName,
    [switch]$GuestRouteOnly,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

Import-Module powershell-yaml -ErrorAction Stop
if (-not (Get-Command Resolve-NIC26KeyVaultRef -ErrorAction SilentlyContinue)) {
    $module = Join-Path $PSScriptRoot '../../../shared/powershell/NIC26.Automation/NIC26.Automation.psd1'
    Import-Module (Resolve-Path $module).Path -ErrorAction Stop
}

$envData = Get-Content -LiteralPath $EnvironmentFile -Raw | ConvertFrom-Yaml
$cfg = $envData['azl_session_hosts']
if ($null -eq $cfg) { throw 'environment file has no azl_session_hosts section.' }
$azlSub = [string]$envData['subscription_id_azl']
$avdSub = [string]$envData['subscription_id_avd']
$rg = [string]$cfg['resource_group']

function Get-ArmId {
    param([string]$Subscription, [string]$ResourceGroup, [string]$Type, [string]$Name)
    $id = "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/$Type/$Name"
    $resource = Get-AzResource -ResourceId $id -ErrorAction SilentlyContinue
    if ($null -eq $resource) { throw "Not found: $Type/$Name in $ResourceGroup." }
    return $resource
}

Set-AzContext -WhatIf:$false -SubscriptionId $azlSub -Tenant (Get-AzContext).Tenant.Id | Out-Null
$customLocation = Get-ArmId $azlSub $rg 'Microsoft.ExtendedLocation/customLocations' $cfg['custom_location']
$lnet = Get-ArmId $azlSub $rg 'Microsoft.AzureStackHCI/logicalNetworks' $cfg['logical_network']
$image = Get-ArmId $azlSub $rg 'Microsoft.AzureStackHCI/galleryImages' $cfg['image']
foreach ($pair in @(@($lnet, 'logical network'), @($image, 'image'))) {
    $state = (Get-AzResource -ResourceId $pair[0].ResourceId -ExpandProperties).Properties.provisioningState
    if ($state -ne 'Succeeded') { throw "The $($pair[1]) $($pair[0].Name) is $state, not Succeeded." }
}
$lnetDns = @((Get-AzResource -ResourceId $lnet.ResourceId -ExpandProperties).Properties.dhcpOptions.dnsServers)
$lnetProps = (Get-AzResource -ResourceId $lnet.ResourceId -ExpandProperties).Properties
$gateway = [string](@($lnetProps.subnets[0].properties.routeTable.properties.routes | Where-Object { $_.properties.addressPrefix -eq '0.0.0.0/0' })[0].properties.nextHopIpAddress)

function Set-GuestDefaultRoute {
    # Stage 1b: returns the number of hosts that have the route.
    param([object[]]$HostList)
    if (-not $gateway) { Write-Warning 'The logical network has no default route; guest route skipped.'; return 0 }
    $nodeCred = [pscredential]::new(
        [string](Resolve-NIC26KeyVaultRef -Ref $cfg['node_admin_username_secret'] -AsPlainText),
        (Resolve-NIC26KeyVaultRef -Ref $cfg['node_admin_password_secret']))
    $guestUser = [string](Resolve-NIC26KeyVaultRef -Ref $envData['secret_refs']['sessionhost_local_admin_username'] -AsPlainText)
    $guestPw = Resolve-NIC26KeyVaultRef -Ref $envData['secret_refs']['sessionhost_local_admin_password']
    $done = 0
    foreach ($h in $HostList) {
        $guestCred = [pscredential]::new("$($h['computer_name'])\$guestUser", $guestPw)
        foreach ($node in @($cfg['node_addresses'])) {
            $r = Invoke-Command -ComputerName $node -Credential $nodeCred -ArgumentList $h['name'], $guestCred, $gateway -ScriptBlock {
                param($name, [pscredential]$cred, $g)
                $vm = Get-VM | Where-Object { $_.Name -like "$name-*" -or $_.Name -eq $name } | Where-Object State -EQ 'Running' | Select-Object -First 1
                if (-not $vm) { return $null }
                try {
                    Invoke-Command -VMName $vm.Name -Credential $cred -ArgumentList $g -ErrorAction Stop -ScriptBlock {
                        param($gw)
                        if (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction SilentlyContinue | Where-Object NextHop -EQ $gw) { return 'present' }
                        $if = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })[0]
                        New-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $if.InterfaceIndex -NextHop $gw -RouteMetric 10 | Out-Null
                        'added'
                    }
                }
                catch { "guest not ready: $($_.Exception.Message)" }
            }
            if ($r) { Write-Information "$($h['name']): default route via $gateway $r"; if ($r -in 'present', 'added') { $done++ }; break }
        }
    }
    return $done
}
if ($GuestRouteOnly) { $null = Set-GuestDefaultRoute -HostList @($cfg['hosts'] | Where-Object { -not $VmName -or $VmName -contains [string]$_['name'] }); return }
$dcr = Get-ArmId $avdSub $cfg['dcr_resource_group'] 'Microsoft.Insights/dataCollectionRules' $cfg['dcr_name']

$hosts = @($cfg['hosts'] | Where-Object { -not $VmName -or $VmName -contains [string]$_['name'] })
if ($hosts.Count -eq 0) { throw 'No matching host in azl_session_hosts.hosts.' }
$deploymentName = if ($VmName) { "$($cfg['deployment_name'])-$($hosts[0]['computer_name'])" } else { [string]$cfg['deployment_name'] }
$names = [ordered]@{ deployment_name = $deploymentName; dcr_assoc = [string]$cfg['dcr_association_name'] }
$storagePathIds = [System.Collections.Generic.List[string]]::new()
$gpuCounts = [System.Collections.Generic.List[int]]::new()
$vcpuPerHost = [System.Collections.Generic.List[int]]::new()
$memoryPerHost = [System.Collections.Generic.List[int]]::new()
for ($i = 0; $i -lt $hosts.Count; $i++) {
    $h = $hosts[$i]
    $names["vm_azl_$($i + 1)"] = [string]$h['name']
    $names["cn_azl_$($i + 1)"] = [string]$h['computer_name']
    $names["nic_azl_$($i + 1)"] = [string]$h['nic_name']
    $path = Get-ArmId $azlSub $rg 'Microsoft.AzureStackHCI/storageContainers' $h['storage_path']
    $storagePathIds.Add($path.ResourceId)
    $gpuCounts.Add([int]($h['gpu_dda_count'] ?? 0))
    $vcpuPerHost.Add([int]($h['vcpu'] ?? 0))
    $memoryPerHost.Add([int]($h['memory_mb'] ?? 0))
}

$tags = [ordered]@{ project = 'nic26'; environment = 'demo' }
foreach ($key in @($cfg['tags'].Keys)) { $tags[$key] = [string]$cfg['tags'][$key] }

$parameters = [ordered]@{
    org                 = @{ value = 'iic' }
    lab_token           = @{ value = 'nic26' }
    location            = @{ value = $customLocation.Location }
    location_short      = @{ value = 'n/a' }
    tenant_id           = @{ value = (Get-AzContext).Tenant.Id }
    subscription_id_azl = @{ value = $azlSub }
    tags                = @{ value = $tags }
    names               = @{ value = $names }
    host_count          = @{ value = $hosts.Count }
    vcpu                = @{ value = [int]$cfg['vcpu'] }
    memory_mb           = @{ value = [int]$cfg['memory_mb'] }
    custom_location_id  = @{ value = $customLocation.ResourceId }
    logical_network_id  = @{ value = $lnet.ResourceId }
    dns_servers         = @{ value = $lnetDns }
    image_id            = @{ value = $image.ResourceId }
    storage_path_ids    = @{ value = @($storagePathIds) }
    dcr_id              = @{ value = $dcr.ResourceId }
    join_type           = @{ value = [string]$cfg['join_type'] }
    domain_fqdn         = @{ value = [string]($cfg['domain_fqdn'] ?? '') }
    domain_ou_path      = @{ value = [string]($cfg['domain_ou_path'] ?? '') }
    gpu_dda_counts      = @{ value = @($gpuCounts) }
    vcpu_per_host       = @{ value = @($vcpuPerHost) }
    memory_mb_per_host  = @{ value = @($memoryPerHost) }
    enable_monitoring   = @{ value = $true }
    hostpool_name       = @{ value = [string]$cfg['host_pool_name'] }
    hostpool_rg         = @{ value = [string]$cfg['host_pool_resource_group'] }
}
$document = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = $parameters
}
# Written to the user's temp folder (it holds resource IDs) and removed after the run; never into the repo.
$paramFile = Join-Path ([IO.Path]::GetTempPath()) ("azl-session-hosts-{0}.parameters.json" -f [guid]::NewGuid())
$document | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $paramFile -Encoding utf8NoBOM

$secretRefs = $envData['secret_refs']
$deploy = @{
    Mode              = 'Bicep'
    SubscriptionId    = $azlSub
    ResourceGroupName = $rg
    ParameterFile     = $paramFile
    AdminUsernameRef  = [string]$secretRefs['sessionhost_local_admin_username']
    AdminPasswordRef  = [string]$secretRefs['sessionhost_local_admin_password']
}
if ($cfg['join_type'] -eq 'AD') {
    $deploy['DomainJoinUsernameRef'] = [string]$cfg['domain_join_username_secret']
    $deploy['DomainJoinPasswordRef'] = [string]$cfg['domain_join_password_secret']
}
Write-Information "Deploying $($hosts.Count) Azure Local session host(s) to $rg (Execute=$([bool]$Execute))."
try {
    if (-not $Execute) {
        & (Join-Path $PSScriptRoot 'Invoke-SessionHostsAzureLocalDeploy.ps1') @deploy
    }
    else {
        # The deployment waits for the AD join extension, which needs the guest route of stage 1b: run it as a job and
        # set the route as soon as each guest answers.
        $deployScript = Join-Path $PSScriptRoot 'Invoke-SessionHostsAzureLocalDeploy.ps1'
        $modulePath = (Get-Module NIC26.Automation | Select-Object -First 1).Path
        $job = Start-ThreadJob -ArgumentList $deployScript, $deploy, $modulePath -ScriptBlock {
            param($script, $arguments, $module)
            Import-Module $module -ErrorAction Stop   # a thread job starts with an empty module table
            & $script @arguments -Execute
        }
        $routed = 0
        while ($job.State -in 'NotStarted', 'Running') {
            Start-Sleep -Seconds 60
            if ($routed -lt $hosts.Count) { $routed = Set-GuestDefaultRoute -HostList $hosts }
        }
        Receive-Job -Job $job -Wait -ErrorAction Stop
    }
}
finally {
    Remove-Item -LiteralPath $paramFile -Force -ErrorAction SilentlyContinue
}
if (-not $Execute) { return }

# Tags: merge onto the Arc machines and NICs (the HCI RP does not always carry template tags to every child), read back.
foreach ($h in $hosts) {
    foreach ($id in @(
            "/subscriptions/$azlSub/resourceGroups/$rg/providers/Microsoft.HybridCompute/machines/$($h['name'])",
            "/subscriptions/$azlSub/resourceGroups/$rg/providers/Microsoft.AzureStackHCI/networkInterfaces/$($h['nic_name'])")) {
        $null = Update-AzTag -ResourceId $id -Tag ([hashtable]$tags) -Operation Merge
        $read = (Get-AzTag -ResourceId $id).Properties.TagsProperty
        if ($read['project'] -ne 'nic26') { throw "Tag project=nic26 missing on $id." }
    }
    $ext = Get-AzConnectedMachineExtension -ResourceGroupName $rg -MachineName $h['name'] -SubscriptionId $azlSub
    Write-Information ("{0}: " -f $h['name'] + (($ext | ForEach-Object { "$($_.Name)=$($_.ProvisioningState)" }) -join ', '))
}

if ($SkipRegistration) { return }
$register = @{
    SubscriptionId         = $azlSub
    ResourceGroupName      = $rg
    HostPoolSubscriptionId = $avdSub
    HostPoolResourceGroup  = [string]$cfg['host_pool_resource_group']
    HostPoolName           = [string]$cfg['host_pool_name']
    MachineName            = @($hosts | ForEach-Object { [string]$_['name'] })
    SessionHostName        = @($hosts | ForEach-Object { [string]$_['computer_name'] })
    TokenScriptPath        = (Resolve-Path (Join-Path $PSScriptRoot '../../control-plane/scripts/New-AvdRegistrationToken.ps1')).Path
    ExpirationHours        = [int]$envData['registration_token_ttl_hours']
    WaitMinutes            = 30
}
# Skip hosts that are already Available (idempotent re-run).
$existing = @(Get-AzWvdSessionHost -SubscriptionId $avdSub -ResourceGroupName $register.HostPoolResourceGroup -HostPoolName $register.HostPoolName -ErrorAction SilentlyContinue)
$todo = for ($i = 0; $i -lt $register.MachineName.Count; $i++) {
    $cn = $register.SessionHostName[$i]
    if (-not ($existing | Where-Object { $_.Name -like "*/$cn.*" -or $_.Name -like "*/$cn" })) { $i }
}
if (@($todo).Count -eq 0) { Write-Information 'All Azure Local session hosts are already registered.'; return }
$register.MachineName = @($todo | ForEach-Object { $register.MachineName[$_] })
$register.SessionHostName = @($todo | ForEach-Object { $register.SessionHostName[$_] })
& (Join-Path $PSScriptRoot 'Register-AvdSessionHostsAzureLocal.ps1') @register -Execute
