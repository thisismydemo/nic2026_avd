#Requires -Version 7.0
<#
.SYNOPSIS
    READ-ONLY validation of the AVD landing zone against design/avd/landing-zone.md section 11.4 (the landing-zone
    items) and the storage/DNS/RBAC facts the realms depend on. Emits pass/fail/skip objects; changes nothing.
.DESCRIPTION
    Expected values come from the generated canonical inputs (terraform.generated.tfvars.json; the example file works
    for a dry run). Private-endpoint DNS is resolved from the host running the script, so run it from the jump server
    and from an Azure session host to cover two realms. Uses Az.* read cmdlets, Resolve-DnsName, Test-NetConnection.
.EXAMPLE
    .\Test-AvdLandingZone.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json -OutputJson .\lz-avd-validation.json
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [string]$OutputJson,
    [switch]$SkipNetworkProbes,
    [string]$StorageDnsSuffix = 'file.core.windows.net'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LzAvd.Common.ps1')

$inputs = Get-LzAvdInputs -InputFile $InputFile
$names = $inputs.names
$sub = $inputs.subscription_id_avd
$results = [System.Collections.Generic.List[object]]::new()

function Invoke-LzAvdCheck {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Test, [switch]$Skip, [string]$SkipReason)
    if ($Skip) {
        $results.Add([pscustomobject]@{ Id = $Id; Check = $Name; Result = 'skip'; Detail = $SkipReason }); return
    }
    try {
        $detail = & $Test
        $results.Add([pscustomobject]@{ Id = $Id; Check = $Name; Result = 'pass'; Detail = "$detail" })
    }
    catch {
        $results.Add([pscustomobject]@{ Id = $Id; Check = $Name; Result = 'fail'; Detail = $_.Exception.Message })
    }
}

function Assert-LzAvd { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzResourceProvider', 'Get-AzResourceGroup', 'Get-AzVirtualNetwork', 'Get-AzVirtualNetworkPeering', 'Get-AzPrivateDnsZone', 'Get-AzPrivateDnsVirtualNetworkLink', 'Get-AzStorageAccount', 'Get-AzRmStorageShare', 'Get-AzPrivateEndpoint', 'Get-AzUserAssignedIdentity', 'Get-AzRoleAssignment', 'Get-AzResource', 'Get-AzPolicyDefinition') {
    if (-not (Test-LzAvdCommand -Name $cmd)) { throw "Az cmdlet '$cmd' not available (Az.Resources, Az.Network, Az.PrivateDns, Az.Storage, Az.ManagedServiceIdentity)." }
}
$context = Get-AzContext
if (-not $context) { throw 'No Azure context. Connect-AzAccount first.' }
if ($context.Subscription.Id -ne $sub) { [void](Set-AzContext -WhatIf:$false -Subscription $sub) }

# 0 informational: cloud-only Entra Kerberos is PREVIEW with OS build requirements (not a pass/fail check)
$previewNote = 'Cloud-only Entra Kerberos for Azure Files is PREVIEW (Learn, 2026-10): session hosts need Windows 11 25H2 with KB5079391 (build 26200.8116) or later / Windows 11 24H2 build 26100.8116+ / Windows Server 2025 with current updates. Verify the image build before the first sign-in.'
Write-LzAvdLog -Level Warning -Message $previewNote
$results.Add([pscustomobject]@{ Id = '0'; Check = 'Entra Kerberos cloud-only preview and OS build requirement'; Result = 'info'; Detail = $previewNote })

# 1 provider
Invoke-LzAvdCheck -Id '1' -Name 'Microsoft.DesktopVirtualization registered' -Test {
    $s = (Get-AzResourceProvider -ProviderNamespace 'Microsoft.DesktopVirtualization' | Select-Object -First 1).RegistrationState
    Assert-LzAvd ($s -eq 'Registered') "state is $s"; $s
}

# 2 resource groups + tags
foreach ($key in 'rg_control', 'rg_net', 'rg_hosts', 'rg_img', 'rg_stor', 'rg_mon', 'rg_arc') {
    Invoke-LzAvdCheck -Id "2.$key" -Name "RG $($names[$key]) exists with project tag" -Test {
        $rg = Get-AzResourceGroup -Name $names[$key]
        Assert-LzAvd ($rg.Tags -and $rg.Tags['project'] -eq $inputs.lab_token) 'project tag missing'; $rg.Location
    }
}

# 3 VNet, subnets
Invoke-LzAvdCheck -Id '3' -Name 'Spoke VNet prefix and four subnets' -Test {
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $names.rg_net -Name $names.spoke_vnet
    Assert-LzAvd ($vnet.AddressSpace.AddressPrefixes -contains $inputs.avd_vnet_prefix) "address space $($vnet.AddressSpace.AddressPrefixes -join ',')"
    foreach ($pair in @(@('subnet_hosts', 'hosts'), @('subnet_pe', 'pe'), @('subnet_imgbuild', 'imgbuild'), @('subnet_dnsin', 'dnsin'))) {
        $snet = $vnet.Subnets | Where-Object { $_.Name -eq $names[$pair[0]] }
        Assert-LzAvd ($null -ne $snet) "subnet $($names[$pair[0]]) missing"
        Assert-LzAvd ($snet.AddressPrefix -contains $inputs.avd_subnets[$pair[1]]) "subnet $($snet.Name) prefix $($snet.AddressPrefix)"
    }
    Assert-LzAvd (-not $vnet.DhcpOptions -or -not $vnet.DhcpOptions.DnsServers -or $vnet.DhcpOptions.DnsServers.Count -eq 0) 'VNet has custom DNS servers; design wants Azure-provided DNS'
    "$($vnet.Subnets.Count) subnets"
}

# 4 peerings
Invoke-LzAvdCheck -Id '4' -Name 'Spoke peerings Connected; hub peering uses remote gateways' -Test {
    $hub = Get-AzVirtualNetworkPeering -ResourceGroupName $names.rg_net -VirtualNetworkName $names.spoke_vnet -Name $names.peer_spoke_to_hub
    $azl = Get-AzVirtualNetworkPeering -ResourceGroupName $names.rg_net -VirtualNetworkName $names.spoke_vnet -Name $names.peer_spoke_to_azl
    Assert-LzAvd ($hub.PeeringState -eq 'Connected') "hub peering $($hub.PeeringState)"
    Assert-LzAvd ($hub.UseRemoteGateways) 'useRemoteGateways is false'
    Assert-LzAvd ($azl.PeeringState -eq 'Connected') "azl peering $($azl.PeeringState)"
    'Connected/Connected'
}

# 5 resolver
Invoke-LzAvdCheck -Id '5' -Name 'DNS Private Resolver inbound endpoint IP' -Skip:(-not ($inputs.enable_private_endpoints -and $inputs.enable_dns_private_resolver)) -SkipReason 'private endpoints off (D-029) or enable_dns_private_resolver=false' -Test {
    $ep = Get-AzResource -ResourceGroupName $names.rg_net -ResourceType 'Microsoft.Network/dnsResolvers/inboundEndpoints' -Name "$($names.dns_resolver)/$($names.dns_resolver_inbound)" -ExpandProperties
    $ip = $ep.Properties.ipConfigurations[0].privateIpAddress
    Assert-LzAvd ($ip -eq $inputs.dns_resolver_inbound_ip) "inbound IP is $ip"; $ip
}

# 6 private DNS zone + links
Invoke-LzAvdCheck -Id '6' -Name 'privatelink.file zone linked to AVD, Azure Local and identity VNets' -Skip:(-not $inputs.enable_private_endpoints -or $inputs.privatelink_file_zone_id -ne '') -SkipReason 'private endpoints off (D-029) or zone reused (privatelink_file_zone_id set)' -Test {
    $zone = Get-AzPrivateDnsZone -ResourceGroupName $names.rg_net -Name $names.file_zone
    $links = @(Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $names.rg_net -ZoneName $zone.Name)
    foreach ($l in 'link_avd', 'link_azl', 'link_identity') { Assert-LzAvd (($links.Name) -contains $names[$l]) "link $($names[$l]) missing" }
    "$($links.Count) links"
}

# 7 storage account
Invoke-LzAvdCheck -Id '7' -Name 'Storage: Premium FileStorage, public access per enable_private_endpoints, shared key only when backup needs it, AADKERB, shares' -Test {
    $sa = Get-AzStorageAccount -ResourceGroupName $names.rg_stor -Name $names.fslogix_sa
    Assert-LzAvd ($sa.Kind -eq 'FileStorage' -and $sa.Sku.Name -like 'Premium_*') "kind/sku $($sa.Kind)/$($sa.Sku.Name)"
    $expectPublic = if ($inputs.enable_private_endpoints) { 'Disabled' } else { 'Enabled' }
    Assert-LzAvd ($sa.PublicNetworkAccess -eq $expectPublic) "publicNetworkAccess $($sa.PublicNetworkAccess), expected $expectPublic"
    # Azure Backup for Azure Files needs key access on the source account (Learn support matrix), so the setting follows enable_backup.
    $expectKey = [bool]$inputs.enable_backup
    Assert-LzAvd ([bool]$sa.AllowSharedKeyAccess -eq $expectKey) ('shared key access is {0} but enable_backup is {1}' -f $sa.AllowSharedKeyAccess, $expectKey)
    Assert-LzAvd ($sa.AzureFilesIdentityBasedAuth -and $sa.AzureFilesIdentityBasedAuth.DirectoryServiceOptions -eq 'AADKERB') 'identity source is not AADKERB'
    $shares = @(Get-AzRmStorageShare -ResourceGroupName $names.rg_stor -StorageAccountName $names.fslogix_sa | Select-Object -ExpandProperty Name)
    foreach ($s in $inputs.share_names.Values) { Assert-LzAvd ($shares -contains $s) "share $s missing" }
    "shares: $($shares -join ', ')"
}

# 8 private endpoint + DNS from this host
Invoke-LzAvdCheck -Id '8a' -Name 'Private endpoint provisioned' -Skip:(-not $inputs.enable_private_endpoints) -SkipReason 'private endpoints off (D-029)' -Test {
    $pe = Get-AzPrivateEndpoint -ResourceGroupName $names.rg_stor -Name $names.fslogix_pe
    Assert-LzAvd ($pe.ProvisioningState -eq 'Succeeded') "state $($pe.ProvisioningState)"; $pe.ProvisioningState
}
$fqdn = "$($names.fslogix_sa).$StorageDnsSuffix"
Invoke-LzAvdCheck -Id '8b' -Name "Resolve $fqdn to the PE subnet from $env:COMPUTERNAME" -Skip:($SkipNetworkProbes -or -not $inputs.enable_private_endpoints) -SkipReason 'SkipNetworkProbes or private endpoints off (D-029)' -Test {
    $answers = @(Resolve-DnsName -Name $fqdn -Type A -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | Select-Object -ExpandProperty IPAddress)
    Assert-LzAvd ($answers.Count -gt 0) 'no A record'
    foreach ($ip in $answers) { Assert-LzAvd (Test-LzAvdIpInCidr -IpAddress $ip -Cidr $inputs.avd_subnets.pe) "$fqdn resolves to $ip (public path), not inside $($inputs.avd_subnets.pe)" }
    $answers -join ','
}
Invoke-LzAvdCheck -Id '8c' -Name "TCP 445 to $fqdn from $env:COMPUTERNAME" -Skip:$SkipNetworkProbes -SkipReason 'SkipNetworkProbes' -Test {
    $t = Test-NetConnection -ComputerName $fqdn -Port 445 -WarningAction SilentlyContinue
    Assert-LzAvd ($t.TcpTestSucceeded) 'TcpTestSucceeded=false'; "via $($t.RemoteAddress)"
}

# 9 host-pool identity Reader on the Arc RG
Invoke-LzAvdCheck -Id '9' -Name 'Host-pool identity has Reader on the Arc RG' -Test {
    $id = Get-AzUserAssignedIdentity -ResourceGroupName $names.rg_control -Name $names.hostpool_identity
    $scope = "/subscriptions/$sub/resourceGroups/$($names.rg_arc)"
    $ra = Get-AzRoleAssignment -ObjectId $id.PrincipalId -Scope $scope -RoleDefinitionName 'Reader' | Where-Object { $_.Scope -eq $scope }
    Assert-LzAvd ($null -ne $ra) 'no Reader assignment at RG scope'; $id.PrincipalId
}

# 10 monitoring + images + budget + backup
Invoke-LzAvdCheck -Id '10a' -Name 'AVD Insights DCR exists' -Test { (Get-AzResource -ResourceGroupName $names.rg_mon -ResourceType 'Microsoft.Insights/dataCollectionRules' -Name $names.dcr_avd_insights).ResourceId }
Invoke-LzAvdCheck -Id '10b' -Name 'Gallery and two image definitions' -Test {
    $defs = @(Get-AzResource -ResourceGroupName $names.rg_img -ResourceType 'Microsoft.Compute/galleries/images' | Select-Object -ExpandProperty Name)
    foreach ($d in $inputs.image_definitions) { Assert-LzAvd ($defs -contains "$($names.gallery)/$($d.name)") "definition $($d.name) missing" }
    $defs -join ', '
}
Invoke-LzAvdCheck -Id '10c' -Name 'Budget exists' -Test { (Get-AzResource -ResourceId "/subscriptions/$sub/providers/Microsoft.Consumption/budgets/$($names.budget)").Name }
Invoke-LzAvdCheck -Id '10d' -Name 'Recovery Services vault exists' -Skip:(-not $inputs.enable_backup) -SkipReason 'enable_backup=false' -Test { (Get-AzResource -ResourceGroupName $names.rg_stor -ResourceType 'Microsoft.RecoveryServices/vaults' -Name $names.recovery_vault).ResourceId }

# 11 built-in ids used by the Bicep track match their display names (guards against a wrong GUID)
Invoke-LzAvdCheck -Id '11' -Name 'builtin-ids.bicep policy GUIDs match display names' -Skip:(-not $inputs.enable_policy_assignments) -SkipReason 'enable_policy_assignments=false' -Test {
    $file = Join-Path (Get-LzAvdSolutionRoot) 'bicep\modules\builtin-ids.bicep'
    $pairs = Select-String -Path $file -Pattern "^\s+\w+: '([0-9a-f-]{36})' // (.+)$" | ForEach-Object { [pscustomobject]@{ Id = $_.Matches[0].Groups[1].Value; Name = $_.Matches[0].Groups[2].Value.Trim() } }
    $policyNames = 'Allowed locations', 'Require a tag on resource groups', 'Inherit a tag from the resource group if missing', 'Storage accounts should disable public network access', 'Secure transfer to storage accounts should be enabled', 'Network interfaces should not have public IPs'
    foreach ($p in ($pairs | Where-Object { $policyNames -contains $_.Name })) {
        $def = Get-AzPolicyDefinition -Id "/providers/Microsoft.Authorization/policyDefinitions/$($p.Id)"
        $display = if ($def.PSObject.Properties['DisplayName']) { $def.DisplayName } else { $def.Properties.DisplayName }
        Assert-LzAvd ($display -eq $p.Name) "$($p.Id) is '$display', expected '$($p.Name)'"
    }
    "$(@($pairs).Count) ids checked"
}

$pass = @($results | Where-Object { $_.Result -eq 'pass' }).Count
$fail = @($results | Where-Object { $_.Result -eq 'fail' }).Count
$skip = @($results | Where-Object { $_.Result -eq 'skip' }).Count
Write-LzAvdLog -Message "Validation: $pass pass, $fail fail, $skip skip"
if ($OutputJson) { $results | ConvertTo-Json -Depth 4 | Set-Content -Path $OutputJson -Encoding utf8 }
$results
