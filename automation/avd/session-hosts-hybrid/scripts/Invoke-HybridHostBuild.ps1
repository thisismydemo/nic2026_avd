#Requires -Version 7.0
<#
.SYNOPSIS
End-to-end, idempotent build of the AVD Hybrid session hosts (plain Hyper-V VMs on the cluster) from
environment/avd/environment.yml: VM, AD join (D-050), Azure Arc, tags, AVD registration.
.DESCRIPTION
Runs from the operator workstation (jump server) and reaches the cluster nodes over WinRM with the cluster
administrator credential from the vault; the guests are reached over PowerShell Direct from the node that runs them.
For each VM in hybrid.vms (or -VmName):
  1. VM (and 1b, the SDN port profile an unmanaged VM needs on an SDN-enabled switch): when it does not exist, copies the master VHDX (hybrid.master_vhdx, a generalized Windows 11 Enterprise
     single-session image; multi-session is not supported on AVD Hybrid), writes the answer file (computer name,
     local administrator) into the copy, creates a Generation 2 VM (Secure Boot, vTPM with a local key protector,
     static MAC, access VLAN on the compute switch, fixed memory), makes it a clustered role with its preferred owner
     and anti-affinity class, and starts it.
  2. AD join: when the guest is not domain joined, Add-Computer into hybrid.domain_ou_path with the delegated join
     account, then restart and wait.
  3. Azure Arc: when the Arc machine is not Connected, installs the Connected Machine agent in the guest and connects
     it to hybrid.arc_resource_group with a short-lived access token of the operator (no onboarding service principal
     secret exists in this lab; Learn: azcmagent connect --access-token), then merges and reads back the tags.
  4. Registration: Register-HybridHosts.ps1 (CloudDeviceExtension, token only in protected settings, K-7) for hosts
     that are not yet in the host pool.
Secrets are resolved in memory and passed only as PSCredential/SecureString arguments; none is written to a file
outside the mounted guest image (the answer file, which the first boot removes). Without -Execute it reports a plan.
.PARAMETER EnvironmentFile
Path to environment/avd/environment.yml.
.PARAMETER VmName
Limit the run to these VMs (default: every hybrid.vms entry).
.PARAMETER SkipRegistration
Build and onboard only.
.PARAMETER Stage
All (default): the full build above, then 5. ClusterRoles for any VM that is still unclustered.
ClusterRoles: only step 5. Add-ClusterVirtualMachineRole fails from a remote session on these workgroup nodes (access
denied: the cluster call cannot reuse the WinRM credential, the second hop). Step 5 therefore registers a one-time
scheduled task on the task node (default: the owner node of the first VM) that runs as the cluster administrator from
the vault, creates the clustered role of every listed VM with its preferred owner and anti-affinity class, writes a
result file and unregisters itself; the operator side waits for the result and, in a finally block, removes the task
(and with it the stored credential) and its working folder if anything is left. The password is handed to
Register-ScheduledTask inside the node session only and is never written to disk.
.PARAMETER TaskNode
Node address that runs the one-time cluster-roles task (default: owner_node_address of the first VM).
.PARAMETER Execute
Apply. Without it the script lists what it would do.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Values resolved from Key Vault in memory.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$EnvironmentFile,
    [string[]]$VmName,
    [switch]$SkipRegistration,
    [ValidateSet('All', 'ClusterRoles')][string]$Stage = 'All',
    [string]$TaskNode,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module powershell-yaml -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HybridCommon.psm1') -Force
if (-not (Get-Command Resolve-NIC26KeyVaultRef -ErrorAction SilentlyContinue)) {
    Import-Module (Resolve-Path (Join-Path $PSScriptRoot '../../../shared/powershell/NIC26.Automation/NIC26.Automation.psd1')).Path
}

$envData = Get-Content -LiteralPath $EnvironmentFile -Raw | ConvertFrom-Yaml
$h = $envData['hybrid']
$avdSub = [string]$envData['subscription_id_avd']
$refs = $envData['secret_refs']
$vms = @($h['vms'] | Where-Object { -not $VmName -or $VmName -contains $_['name'] })
if ($vms.Count -eq 0) { throw 'No matching hybrid VM in the environment file.' }

function Get-Secret([string]$Ref) {
    $value = Resolve-NIC26KeyVaultRef -Ref $Ref
    if ($value -is [securestring]) { return $value }
    return (ConvertTo-SecureString ([string]$value) -AsPlainText -Force)
}
function Get-PlainSecret([string]$Ref) {
    $value = Resolve-NIC26KeyVaultRef -Ref $Ref
    if ($value -is [securestring]) { return [Net.NetworkCredential]::new('', $value).Password }
    return [string]$value
}

if (-not $TaskNode) { $TaskNode = [string]$vms[0]['owner_node_address'] }
if (-not $Execute) {
    foreach ($vm in $vms) {
        $steps = if ($Stage -eq 'ClusterRoles') { "clustered role via one-time task on $TaskNode" } else { 'VM, AD join, Arc, tags, cluster role, registration' }
        [pscustomobject]@{ VmName = $vm['name']; Node = $vm['owner_node']; Steps = $steps; Status = 'Planned' }
    }
    return
}

$nodeCred = [pscredential]::new((Get-PlainSecret $h['node_admin_username_secret']), (Get-Secret $h['node_admin_password_secret']))
$guestUser = Get-PlainSecret $refs['hybrid_local_admin_username']
$guestPassword = Get-Secret $refs['hybrid_local_admin_password']
$guestCred = [pscredential]::new(".\$guestUser", $guestPassword)
$joinCred = [pscredential]::new((Get-PlainSecret $h['domain_join_username_secret']), (Get-Secret $h['domain_join_password_secret']))

function Invoke-Guest {
    param([string]$Node, [string]$Vm, [pscredential]$Credential, [scriptblock]$ScriptBlock, [object[]]$ArgumentList = @())
    # The guest credential is rebuilt on the node from the user name and the SecureString (a PSCredential that crossed
    # the WinRM hop does not authenticate PowerShell Direct reliably).
    Invoke-Command -ComputerName $Node -Credential $nodeCred -ScriptBlock {
        param($vmName, $user, $secret, $text, $arguments)
        $cred = [pscredential]::new($user, $secret)
        Invoke-Command -VMName $vmName -Credential $cred -ScriptBlock ([scriptblock]::Create($text)) -ArgumentList $arguments -ErrorAction Stop
    } -ArgumentList $Vm, $Credential.UserName, $Credential.Password, $ScriptBlock.ToString(), $ArgumentList
}
function Wait-Guest {
    param([string]$Node, [string]$Vm, [pscredential]$Credential, [int]$Minutes = 20)
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        try {
            $ok = Invoke-Guest -Node $Node -Vm $Vm -Credential $Credential -ScriptBlock { $env:COMPUTERNAME }
            if ($ok) { return $ok }
        }
        catch { Start-Sleep -Seconds 20 }
    }
    throw "Guest $Vm did not answer over PowerShell Direct within $Minutes minutes."
}

function Set-HybridClusterRole {
    # Step 5: clustered roles through a one-time scheduled task on the task node (see .PARAMETER Stage). Idempotent:
    # VMs that already have a cluster group only get their preferred owner and anti-affinity class re-applied.
    [CmdletBinding(SupportsShouldProcess)]
    param([object[]]$Vm, [string]$Node)
    $specs = @($Vm | ForEach-Object { @{ Name = [string]$_['name']; OwnerNode = [string]$_['owner_node']; AntiAffinity = [string]$h['anti_affinity_class'] } })
    $names = @($specs | ForEach-Object { $_.Name })
    if (-not $PSCmdlet.ShouldProcess(($names -join ', '), "Clustered VM roles via a one-time scheduled task on $Node")) { return }
    $result = Invoke-Command -ComputerName $Node -Credential $nodeCred -ArgumentList $specs, $nodeCred.UserName, $nodeCred.Password -ScriptBlock {
        param($specs, $user, $secret)
        $ErrorActionPreference = 'Stop'
        $taskName = 'avd-hybrid-cluster-roles'
        $dir = Join-Path $env:ProgramData 'avd-hybrid-cluster-roles'
        $resultFile = Join-Path $dir 'result.json'
        try {
            [void][IO.Directory]::CreateDirectory($dir)
            Remove-Item -LiteralPath $resultFile -ErrorAction SilentlyContinue
            ConvertTo-Json -InputObject @($specs) -Depth 4 | Set-Content -LiteralPath (Join-Path $dir 'specs.json') -Encoding UTF8
            $body = @'
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $PSCommandPath
$items = Get-Content -LiteralPath (Join-Path $dir 'specs.json') -Raw | ConvertFrom-Json   # Windows PowerShell: assign, then enumerate
$out = foreach ($s in $items) {
    try {
        if (-not (Get-ClusterGroup -Name $s.Name -ErrorAction SilentlyContinue)) { $null = Add-ClusterVirtualMachineRole -VMName $s.Name -Name $s.Name }
        Set-ClusterOwnerNode -Group $s.Name -Owners $s.OwnerNode
        $g = Get-ClusterGroup -Name $s.Name
        $g.AntiAffinityClassNames = [string[]]@($s.AntiAffinity)
        if ([string]$g.State -ne 'Online') { $null = Start-ClusterGroup -Name $s.Name }
        [pscustomobject]@{ Name = $s.Name; Ok = $true; Error = '' }
    }
    catch { [pscustomobject]@{ Name = $s.Name; Ok = $false; Error = $_.Exception.Message } }
}
ConvertTo-Json -InputObject @($out) | Set-Content -LiteralPath (Join-Path $dir 'result.json') -Encoding UTF8
Unregister-ScheduledTask -TaskName 'avd-hybrid-cluster-roles' -Confirm:$false -ErrorAction SilentlyContinue
'@
            $scriptFile = Join-Path $dir 'Set-ClusterRoles.ps1'
            Set-Content -LiteralPath $scriptFile -Value $body -Encoding UTF8
            $account = if ($user -match '[\\@]') { $user } else { "$env:COMPUTERNAME\$user" }
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptFile`""
            $plain = [Net.NetworkCredential]::new('', $secret).Password
            try { $null = Register-ScheduledTask -TaskName $taskName -Action $action -User $account -Password $plain -RunLevel Highest -Force }
            finally { $plain = $null }
            Start-ScheduledTask -TaskName $taskName
            $deadline = (Get-Date).AddMinutes(5)
            while (-not (Test-Path -LiteralPath $resultFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
            if (-not (Test-Path -LiteralPath $resultFile)) {
                $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
                throw "The cluster-roles task wrote no result within 5 minutes (last task result: $(if ($info) { $info.LastTaskResult } else { 'n/a' }))."
            }
            Start-Sleep -Seconds 3
            Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        }
        finally {
            # Never leave the task (it holds the stored credential) or its files behind.
            if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($r in @($result)) { Write-Information "$($r.Name) clustered role: $(if ($r.Ok) { 'OK' } else { "FAILED - $($r.Error)" })" }
    $readBack = Invoke-Command -ComputerName $Node -Credential $nodeCred -ArgumentList (, $names) -ScriptBlock {
        param($vmNames)
        [pscustomobject]@{
            TaskLeft   = [bool](Get-ScheduledTask -TaskName 'avd-hybrid-cluster-roles' -ErrorAction SilentlyContinue)
            FolderLeft = (Test-Path -LiteralPath (Join-Path $env:ProgramData 'avd-hybrid-cluster-roles'))
            Groups     = @(foreach ($n in $vmNames) {
                    $g = Get-ClusterGroup -Name $n -ErrorAction SilentlyContinue
                    if ($g) {
                        [pscustomobject]@{
                            Name = [string]$g.Name; State = [string]$g.State; OwnerNode = [string]$g.OwnerNode; GroupType = [string]$g.GroupType
                            PreferredOwners = (@((Get-ClusterOwnerNode -Group $n).OwnerNodes | ForEach-Object { [string]$_.Name }) -join ',')
                            AntiAffinity = (@($g.AntiAffinityClassNames) -join ',')
                        }
                    }
                    else { [pscustomobject]@{ Name = $n; State = 'not clustered'; OwnerNode = ''; GroupType = ''; PreferredOwners = ''; AntiAffinity = '' } }
                })
        }
    }
    if ($readBack.TaskLeft -or $readBack.FolderLeft) { throw "Cluster-roles task or folder still present on $Node." }
    $readBack.Groups | Select-Object Name, State, OwnerNode, GroupType, PreferredOwners, AntiAffinity
    if (@($result | Where-Object { -not $_.Ok }).Count -gt 0) { throw 'One or more clustered roles were not created (see above).' }
}

if ($Stage -eq 'ClusterRoles') {
    Set-HybridClusterRole -Vm $vms -Node $TaskNode
    return
}

foreach ($vm in $vms) {
    $name = [string]$vm['name']
    $node = [string]$vm['owner_node_address']
    Write-Information "== $name on $($vm['owner_node']) ($node)"

    # 1. VM -------------------------------------------------------------------------------------------------------------
    $exists = Invoke-Command -ComputerName $node -Credential $nodeCred -ScriptBlock { param($n) [bool](Get-ClusterGroup -Name $n -ErrorAction SilentlyContinue) -or [bool](Get-VM -Name $n -ErrorAction SilentlyContinue) } -ArgumentList $name
    if (-not $exists) {
        $xml = New-HybridUnattendXml -ComputerName $name -TimeZone $h['time_zone'] -LocalAdminUsername $guestUser -LocalAdminPassword $guestPassword
        $spec = @{
            Name = $name; OwnerNode = [string]$vm['owner_node']; Mac = (ConvertTo-HybridMacAddress -MacAddress $vm['mac_address'])
            Root = (Join-Path (Join-Path $h['csv_path'] 'hyperv') $name); Master = [string]$h['master_vhdx']
            Switch = [string]$h['compute_switch_name']; Vlan = [int]$h['vlan_id']; Cpu = [int]$h['vcpu']
            MemoryBytes = [long]$h['memory_gb'] * 1GB; DiskBytes = [long]$h['disk_gb'] * 1GB
            AntiAffinity = [string]$h['anti_affinity_class']; Notes = "AVD Hybrid session host ($($envData['realms']['hybrid']['friendly_name'])); project=nic26"
        }
        if ($PSCmdlet.ShouldProcess($name, 'Create clustered Hyper-V VM')) {
            Invoke-Command -ComputerName $node -Credential $nodeCred -ScriptBlock {
                param($s, $unattend)
                $ErrorActionPreference = 'Stop'
                $disk = Join-Path $s.Root "Virtual Hard Disks\$($s.Name).vhdx"
                if (-not (Test-Path -LiteralPath $s.Master)) { throw "Master VHDX not found: $($s.Master)" }
                if (Test-Path -LiteralPath $disk) { throw "Disk $disk exists without a VM; remove the folder and re-run." }
                [void][IO.Directory]::CreateDirectory((Split-Path $disk))
                Copy-Item -LiteralPath $s.Master -Destination $disk
                if ((Get-VHD -Path $disk).Size -lt $s.DiskBytes) { Resize-VHD -Path $disk -SizeBytes $s.DiskBytes }
                $mounted = Mount-VHD -Path $disk -Passthru
                try {
                    $windows = Get-Partition -DiskNumber $mounted.Number | Where-Object DriveLetter |
                        ForEach-Object { "$($_.DriveLetter):\Windows" } | Where-Object { Test-Path $_ } | Select-Object -First 1
                    if (-not $windows) { throw 'No Windows partition in the master image.' }
                    $target = Join-Path $windows 'Panther\Unattend\Unattend.xml'
                    [void][IO.Directory]::CreateDirectory((Split-Path $target))
                    [IO.File]::WriteAllText($target, $unattend)
                    # Remove the answer file after setup (it carries the obfuscated local administrator password).
                    $setup = Join-Path $windows 'Setup\Scripts\SetupComplete.cmd'
                    [void][IO.Directory]::CreateDirectory((Split-Path $setup))
                    [IO.File]::WriteAllText($setup, "del /q /f %WINDIR%\Panther\Unattend\Unattend.xml`r`ndel /q /f %WINDIR%\Panther\unattend.xml`r`n")
                }
                finally { Dismount-VHD -Path $disk }
                $null = New-VM -Name $s.Name -Generation 2 -MemoryStartupBytes $s.MemoryBytes -VHDPath $disk -Path $s.Root -SwitchName $s.Switch
                Set-VMProcessor -VMName $s.Name -Count $s.Cpu
                Set-VMMemory -VMName $s.Name -DynamicMemoryEnabled $false -StartupBytes $s.MemoryBytes
                Set-VMFirmware -VMName $s.Name -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
                Set-VMKeyProtector -VMName $s.Name -NewLocalKeyProtector
                Enable-VMTPM -VMName $s.Name
                Set-VMNetworkAdapter -VMName $s.Name -StaticMacAddress $s.Mac
                Set-VMNetworkAdapterVlan -VMName $s.Name -Access -VlanId $s.Vlan
                Set-VM -Name $s.Name -CheckpointType Disabled -AutomaticStartAction Start -AutomaticStopAction ShutDown -Notes $s.Notes
                try {
                    $null = Add-ClusterVirtualMachineRole -VMName $s.Name -ErrorAction Stop
                    Set-ClusterOwnerNode -Group $s.Name -Owners $s.OwnerNode
                    $group = Get-ClusterGroup -Name $s.Name
                    $group.AntiAffinityClassNames = [string[]]@($s.AntiAffinity)
                    Start-ClusterGroup -Name $s.Name | Out-Null
                }
                catch {
                    # A remote session can lack the delegation the cluster cmdlets need; the VM still runs on its node.
                    Write-Warning "Clustered role not created for $($s.Name): $($_.Exception.Message). Starting the VM unclustered."
                    Start-VM -Name $s.Name
                }
            } -ArgumentList $spec, $xml
        }
        $xml = $null
    }
    # 1b. SDN port profile: with SDN enabled by Arc the VFP switch extension blocks the port of a VM created outside the
    # Azure interfaces until it carries a port profile (Learn: SDN FAQ and "VMs created outside of Windows Admin
    # Center": Set-SdnVMNetworkAdapterPortProfile -ProfileId [guid]::Empty -ProfileData 2). Runs on the node that owns
    # the VM; idempotent. A live migration keeps the port settings.
    $owner = Invoke-Command -ComputerName $node -Credential $nodeCred -ArgumentList $name -ScriptBlock {
        param($n)
        $g = Get-ClusterGroup -Name $n -ErrorAction SilentlyContinue
        if ($g) { [string]$g.OwnerNode } else { $env:COMPUTERNAME }
    }
    $ownerAddress = @($h['vms'] | Where-Object { $_['owner_node'] -eq $owner } | ForEach-Object { $_['owner_node_address'] })[0]
    if (-not $ownerAddress) { $ownerAddress = $node }
    if ($PSCmdlet.ShouldProcess($name, 'SDN port profile for an unmanaged VM')) {
        $pp = Invoke-Command -ComputerName $ownerAddress -Credential $nodeCred -ArgumentList $name -ScriptBlock {
            param($n)
            Import-Module SdnDiagnostics -ErrorAction Stop
            $adapter = Get-SdnVMNetworkAdapterPortProfile -VMName $n
            if ([string]$adapter.ProfileData -eq '2') { return 'present' }
            $mac = (Get-VMNetworkAdapter -VMName $n | Select-Object -First 1).MacAddress
            Set-SdnVMNetworkAdapterPortProfile -VMName $n -MacAddress $mac -ProfileId ([guid]::Empty) -ProfileData 2
            'set'
        }
        Write-Information "$name SDN port profile: $pp"
    }
    $null = Wait-Guest -Node $node -Vm $name -Credential $guestCred -Minutes 30

    # 2. AD join -----------------------------------------------------------------------------------------------------
    $joined = Invoke-Guest -Node $node -Vm $name -Credential $guestCred -ScriptBlock { (Get-CimInstance Win32_ComputerSystem).PartOfDomain }
    if (-not $joined -and $PSCmdlet.ShouldProcess($name, "Join $($h['domain_fqdn'])")) {
        Invoke-Guest -Node $node -Vm $name -Credential $guestCred -ScriptBlock {
            param($domain, $ou, $user, $secret)
            Add-Computer -DomainName $domain -OUPath $ou -Credential ([pscredential]::new($user, $secret)) -Force -ErrorAction Stop
        } -ArgumentList $h['domain_fqdn'], $h['domain_ou_path'], $joinCred.UserName, $joinCred.Password
        Invoke-Command -ComputerName $node -Credential $nodeCred -ScriptBlock { param($n) Restart-VM -Name $n -Force } -ArgumentList $name
        Start-Sleep -Seconds 60
        $null = Wait-Guest -Node $node -Vm $name -Credential $guestCred -Minutes 20
        $joined = Invoke-Guest -Node $node -Vm $name -Credential $guestCred -ScriptBlock { (Get-CimInstance Win32_ComputerSystem).PartOfDomain }
        if (-not $joined) { throw "$name did not join $($h['domain_fqdn'])." }
    }
    Write-Information "$name domain joined: $joined"

    # 3. Azure Arc ---------------------------------------------------------------------------------------------------
    $arc = Get-AzConnectedMachine -SubscriptionId $avdSub -ResourceGroupName $h['arc_resource_group'] -Name $name -ErrorAction SilentlyContinue
    if (($null -eq $arc -or $arc.Status -ne 'Connected') -and $PSCmdlet.ShouldProcess($name, 'Connect Azure Arc')) {
        $token = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -AsSecureString).Token
        $tags = @{ project = 'nic26'; environment = 'demo'; workload = 'avd'; 'managed-by' = 'script' }
        foreach ($k in @($h['arc_tags'].Keys)) { $tags[$k] = [string]$h['arc_tags'][$k] }
        $tagList = ($tags.Keys | Sort-Object | ForEach-Object { "$_=$($tags[$_])" }) -join ','
        try {
            Invoke-Guest -Node $node -Vm $name -Credential $guestCred -ScriptBlock {
                param($secureToken, $tenant, $subscription, $rg, $location, $resource, $tagText)
                $ErrorActionPreference = 'Stop'
                $agent = Join-Path $env:ProgramW6432 'AzureConnectedMachineAgent\azcmagent.exe'
                if (-not (Test-Path $agent)) {
                    $msi = Join-Path $env:TEMP 'AzureConnectedMachineAgent.msi'
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest -Uri 'https://aka.ms/AzureConnectedMachineAgent' -OutFile $msi -UseBasicParsing
                    $p = Start-Process msiexec.exe -ArgumentList @('/i', $msi, '/qn', '/norestart') -Wait -PassThru
                    if ($p.ExitCode -notin 0, 3010) { throw "Arc agent install failed ($($p.ExitCode))." }
                }
                $plain = [Net.NetworkCredential]::new('', $secureToken).Password
                $null = & $agent connect --access-token $plain --tenant-id $tenant --subscription-id $subscription --resource-group $rg --location $location --resource-name $resource --tags $tagText 2>&1
                $plain = $null
                if ($LASTEXITCODE -ne 0) { throw 'azcmagent connect failed.' }
            } -ArgumentList $token, (Get-AzContext).Tenant.Id, $avdSub, $h['arc_resource_group'], $h['location'], $name, $tagList
        }
        finally { $token = $null }
        $arc = Get-AzConnectedMachine -SubscriptionId $avdSub -ResourceGroupName $h['arc_resource_group'] -Name $name
        if ($arc.Status -ne 'Connected') { throw "$name is not Connected in Azure Arc." }
    }
    # 3b. Monitoring: Azure Monitor Agent as an Arc extension and the AVD Insights DCR association (same DCR as the
    # other realms; AVD landing zone section 9).
    $ama = Get-AzConnectedMachineExtension -SubscriptionId $avdSub -ResourceGroupName $h['arc_resource_group'] -MachineName $name -Name 'AzureMonitorWindowsAgent' -ErrorAction SilentlyContinue
    if ((-not $ama -or $ama.ProvisioningState -ne 'Succeeded') -and $PSCmdlet.ShouldProcess($name, 'Azure Monitor Agent')) {
        $null = New-AzConnectedMachineExtension -SubscriptionId $avdSub -ResourceGroupName $h['arc_resource_group'] -MachineName $name -Location $h['location'] `
            -Name 'AzureMonitorWindowsAgent' -Publisher 'Microsoft.Azure.Monitor' -ExtensionType 'AzureMonitorWindowsAgent' -EnableAutomaticUpgrade
    }
    $dcrId = "/subscriptions/$avdSub/resourceGroups/$($h['dcr_resource_group'])/providers/Microsoft.Insights/dataCollectionRules/$($h['dcr_name'])"
    $assocUri = "$($arc.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($h['dcr_association_name'])?api-version=2023-03-11"
    $assoc = Invoke-AzRestMethod -Method GET -Path $assocUri
    if ($assoc.StatusCode -ne 200 -and $PSCmdlet.ShouldProcess($name, 'DCR association')) {
        $put = Invoke-AzRestMethod -Method PUT -Path $assocUri -Payload (@{ properties = @{ dataCollectionRuleId = $dcrId } } | ConvertTo-Json)
        if ($put.StatusCode -notin 200, 201) { throw "DCR association failed for $name ($($put.StatusCode))." }
    }
    $null = Update-AzTag -ResourceId $arc.Id -Tag @{ project = 'nic26'; environment = 'demo'; workload = 'avd'; 'managed-by' = 'script'; realm = 'hybrid' } -Operation Merge
    $readTags = (Get-AzTag -ResourceId $arc.Id).Properties.TagsProperty
    Write-Information "$name Arc: $($arc.Status); project=$($readTags['project'])"
}

# 5. Clustered roles for any VM the remote session could not cluster in step 1 ------------------------------------------
$unclustered = @($vms | Where-Object {
        -not (Invoke-Command -ComputerName $TaskNode -Credential $nodeCred -ScriptBlock { param($x) [bool](Get-ClusterGroup -Name $x -ErrorAction SilentlyContinue) } -ArgumentList ([string]$_['name']))
    })
if ($unclustered.Count -gt 0) { Set-HybridClusterRole -Vm $unclustered -Node $TaskNode }

if ($SkipRegistration) { return }
$pool = [string]$h['host_pool_name']
$poolRg = [string]$h['host_pool_resource_group']
$existing = @(Get-AzWvdSessionHost -SubscriptionId $avdSub -ResourceGroupName $poolRg -HostPoolName $pool -ErrorAction SilentlyContinue)
$todo = @($vms | ForEach-Object { [string]$_['name'] } | Where-Object { $n = $_; -not ($existing | Where-Object { $_.Name -like "*/$n.*" -or $_.Name -like "*/$n" }) })
if ($todo.Count -eq 0) { Write-Information 'All hybrid hosts are already registered.'; return }
& (Join-Path $PSScriptRoot 'Register-HybridHosts.ps1') -SubscriptionId $avdSub -ArcResourceGroup $h['arc_resource_group'] `
    -HostPoolResourceGroup $poolRg -HostPoolName $pool -MachineName $todo `
    -TokenScriptPath (Resolve-Path (Join-Path $PSScriptRoot '../../control-plane/scripts/New-AvdRegistrationToken.ps1')).Path `
    -ExpirationHours ([int]$envData['registration_token_ttl_hours']) -WaitMinutes 20 -Execute
