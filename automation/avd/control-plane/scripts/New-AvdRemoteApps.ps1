#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.DesktopVirtualization, Az.Resources, powershell-yaml
<#
.SYNOPSIS
    Live demo a3f (owner, 14 Oct): publishes applications with RemoteApp, the same objects the portal's "Create an application
    group" wizard creates (type RemoteApp), on an existing pool. -Remove deletes them again.
.DESCRIPTION
    Inputs (G5, nothing lab-specific in this file): environment/avd/environment.yml
      subscription_id_avd, entra_groups, group_object_ids, host_pools.<key>.preferred_app_group_type,
      remote_apps { host_pool_key, host_pool_name, resource_group, app_group_name, friendly_name, assign_group, workspace_name,
      prefer_remote_app, apps[] { name, start_menu_item, friendly_name }, tags }
    Steps, each idempotent and printed as it runs (the presenter talks over them):
      1. RemoteApp application group on the pool, in the pool's region.
      2. One application per configured Start menu item. The path, icon and arguments come from the Start menu of the pool's
         session hosts (Get-AzWvdStartMenuItem), so they are right for the image; at least one host must be powered on.
      3. The application group added to the workspace's references (existing references kept).
      4. Desktop Virtualization User for assign_group on the application group.
      5. Only when prefer_remote_app is true: the pool's preferred application group type set to RemoteApp. A user assigned to
         both the desktop and a RemoteApp group of one pool sees only the preferred type, so with Desktop preferred the members
         of a group that also has the pool's desktop see the desktop, not these apps. The plan says so.
    Runs as the signed-in account (the presenter on stage; a managed identity or service principal in a pipeline); it needs
    rights to create role assignments on the application group. Default is a plan; -Execute creates.
.PARAMETER EnvironmentFile
    The AVD environment file (default: <repo>/environment/avd/environment.yml).
.PARAMETER Remove
    Remove the role assignment and the workspace reference, delete the application group (and its applications) and set the
    pool's preferred application group type back to host_pools.<key>.preferred_app_group_type (after the session).
.PARAMETER Execute
    Make the changes. Without it the script prints what it would do.
.EXAMPLE
    ./New-AvdRemoteApps.ps1
.EXAMPLE
    ./New-AvdRemoteApps.ps1 -Execute
.EXAMPLE
    ./New-AvdRemoteApps.ps1 -Remove -Execute
#>
[CmdletBinding()]
param(
    [string]$EnvironmentFile,
    [switch]$Remove,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
if (-not $EnvironmentFile) { $EnvironmentFile = Join-Path $repo 'environment\avd\environment.yml' }
$env = Get-Content -Raw -Path $EnvironmentFile | ConvertFrom-Yaml
$c = $env.remote_apps
if (-not $c) { throw "remote_apps is missing in $EnvironmentFile" }
function Step([string]$m) { Write-Information -MessageData "[remote-apps] $m" -InformationAction Continue }

$null = Set-AzContext -Subscription $env.subscription_id_avd -Scope Process -WhatIf:$false
$rg = $c.resource_group
$role = 'Desktop Virtualization User'
$preferRemoteApp = [bool]$c['prefer_remote_app']
$poolPreferred = if ($env.host_pools -and $env.host_pools[$c.host_pool_key] -and $env.host_pools[$c.host_pool_key]['preferred_app_group_type']) { [string]$env.host_pools[$c.host_pool_key]['preferred_app_group_type'] } else { 'Desktop' }

# Group object id from the environment file (entra_groups key -> group_object_ids); Entra lookup only when it is not there.
$groupKey = @($env.entra_groups.Keys | Where-Object { $env.entra_groups[$_] -eq $c.assign_group }) | Select-Object -First 1
$groupId = if ($groupKey -and $env.group_object_ids[$groupKey]) { [string]$env.group_object_ids[$groupKey] } else { (Get-AzADGroup -DisplayName $c.assign_group).Id }
if (-not $groupId) { throw "Group $($c.assign_group) not found in group_object_ids or Entra ID" }

$hp = Get-AzWvdHostPool -ResourceGroupName $rg -Name $c.host_pool_name
$ws = Get-AzWvdWorkspace -ResourceGroupName $rg -Name $c.workspace_name
$sub = $env.subscription_id_avd
$agId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.DesktopVirtualization/applicationGroups/$($c.app_group_name)"
$refs = @($ws.ApplicationGroupReference | Where-Object { $_ })
$ag = Get-AzWvdApplicationGroup -ResourceGroupName $rg -Name $c.app_group_name -ErrorAction SilentlyContinue

# Can the signed-in account write role assignments in the resource group? (Owner, User Access Administrator, RBAC
# Administrator.) Without it the assignment step is skipped with a message instead of failing half-way on stage.
$want = 'Microsoft.Authorization/roleAssignments/write'
$perm = Invoke-AzRestMethod -Method GET -Path "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
$canAssign = $true
if ($perm.StatusCode -eq 200) {
    $canAssign = [bool](@(($perm.Content | ConvertFrom-Json).value | Where-Object {
                @($_.actions | Where-Object { $want -like $_ }).Count -and -not @($_.notActions | Where-Object { $want -like $_ }).Count }).Count)
}
$noAssignMsg = "the signed-in account cannot write role assignments in $rg; run as an Owner or User Access Administrator, or assign $($c.assign_group) in the portal (Application groups > $($c.app_group_name) > Assignments > + Add)"

if ($Remove) {
    Step "Remove: $role for $($c.assign_group), $($c.app_group_name) from $($c.workspace_name), then the application group and its applications"
    if ($hp.PreferredAppGroupType -ne $poolPreferred) { Step "   and set $($c.host_pool_name) back to preferred type $poolPreferred" }
    if (-not $Execute) { Step 'Plan only. Run with -Execute to delete.'; return }
    $ra = @(if ($ag) { Get-AzRoleAssignment -Scope $ag.Id -ObjectId $groupId -RoleDefinitionName $role -ErrorAction SilentlyContinue | Where-Object { $_.Scope -eq $ag.Id } })
    if ($ra.Count -and $canAssign) { $null = Remove-AzRoleAssignment -Scope $ag.Id -ObjectId $groupId -RoleDefinitionName $role }
    elseif ($ra.Count) { Write-Warning "Role assignment left in place (it becomes orphaned when the group is deleted): $noAssignMsg" }
    $keep = @($refs | Where-Object { $_ -ne $agId })
    if ($keep.Count -ne $refs.Count) { $null = Update-AzWvdWorkspace -ResourceGroupName $rg -Name $c.workspace_name -ApplicationGroupReference $keep }
    if ($ag) { Remove-AzWvdApplicationGroup -ResourceGroupName $rg -Name $c.app_group_name }
    if ($hp.PreferredAppGroupType -ne $poolPreferred) { $null = Update-AzWvdHostPool -ResourceGroupName $rg -Name $c.host_pool_name -PreferredAppGroupType $poolPreferred }
    Step "Removed. Workspace $($c.workspace_name) references $(@((Get-AzWvdWorkspace -ResourceGroupName $rg -Name $c.workspace_name).ApplicationGroupReference).Count) application groups."
    return
}

# Start menu items of the pool's hosts: read through the new group once it exists, through any group of the pool before that.
$menuGroup = if ($ag) { $c.app_group_name } else {
    @(Get-AzWvdApplicationGroup -ResourceGroupName $rg | Where-Object { $_.HostPoolArmPath -eq $hp.Id } | Select-Object -ExpandProperty Name) | Select-Object -First 1
}
if (-not $menuGroup) { throw "No application group on $($c.host_pool_name) to read the Start menu through; create the desktop group first" }
$menu = @(Get-AzWvdStartMenuItem -ResourceGroupName $rg -ApplicationGroupName $menuGroup)
if ($menu.Count -eq 0) { throw "No Start menu items returned for $($c.host_pool_name): is at least one session host powered on and Available?" }
$apps = foreach ($a in $c.apps) {
    $item = $menu | Where-Object { ($_.Name -split '/')[-1] -eq $a.start_menu_item } | Select-Object -First 1
    if (-not $item) { throw "Start menu item '$($a.start_menu_item)' not found on $($c.host_pool_name). Available: $((($menu.Name | ForEach-Object { ($_ -split '/')[-1] }) | Sort-Object) -join ', ')" }
    [pscustomobject]@{ Name = $a.name; FriendlyName = $(if ($a['friendly_name']) { $a.friendly_name } else { $a.start_menu_item }); Item = $item }
}

$assigned = if ($ag) { [bool](@(Get-AzRoleAssignment -Scope $ag.Id -ObjectId $groupId -RoleDefinitionName $role -ErrorAction SilentlyContinue | Where-Object { $_.Scope -eq $ag.Id })) } else { $false }
Step "1. RemoteApp application group $($c.app_group_name) ('$($c.friendly_name)') on $($c.host_pool_name), region $($hp.Location)$(if ($ag) { ' (exists)' })"
Step "2. Publish $($apps.Count) applications from the hosts' Start menu:"
foreach ($a in $apps) { Step "     $($a.FriendlyName): $($a.Item.FilePath)$(if ($a.Item.CommandLineArgument) { ' ' + $a.Item.CommandLineArgument })" }
Step "3. Register it in workspace $($c.workspace_name) ($($refs.Count) groups there now)"
Step "4. Assign $role to $($c.assign_group)$(if ($assigned) { ' (exists)' } elseif (-not $canAssign) { " - SKIPPED: $noAssignMsg" })"
if ($preferRemoteApp) {
    Step "5. Set $($c.host_pool_name) preferred application group type to RemoteApp (now $($hp.PreferredAppGroupType)); the pool's desktop leaves the feed of users who have both"
}
elseif ($hp.PreferredAppGroupType -ne 'RemoteApp') {
    Step "   Note: $($c.host_pool_name) prefers $($hp.PreferredAppGroupType). Members of $($c.assign_group) who also have its desktop see the desktop, not these apps (remote_apps.prefer_remote_app)."
}
if (-not $Execute) { Step 'Plan only. Run with -Execute to create.'; return }

$tags = @{}; if ($c['tags']) { foreach ($k in $c.tags.Keys) { $tags[$k] = [string]$c.tags[$k] } }
if (-not $ag) {
    $ag = New-AzWvdApplicationGroup -ResourceGroupName $rg -Name $c.app_group_name -Location $hp.Location -HostPoolArmPath $hp.Id `
        -ApplicationGroupType RemoteApp -FriendlyName $c.friendly_name -Tag $tags
}
Step "   application group: $($ag.Id)"
foreach ($a in $apps) {
    if (Get-AzWvdApplication -ResourceGroupName $rg -GroupName $c.app_group_name -Name $a.Name -ErrorAction SilentlyContinue) { Step "   application $($a.Name): exists"; continue }
    $p = @{
        ResourceGroupName = $rg; GroupName = $c.app_group_name; Name = $a.Name; FriendlyName = $a.FriendlyName
        FilePath = $a.Item.FilePath; IconPath = $a.Item.IconPath; IconIndex = [int]$a.Item.IconIndex; ShowInPortal = $true
        CommandLineSetting = 'DoNotAllow'
    }
    if ($a.Item.CommandLineArgument) { $p.CommandLineSetting = 'Require'; $p.CommandLineArgument = $a.Item.CommandLineArgument }
    $null = New-AzWvdApplication @p
    Step "   application $($a.Name): published"
}
if ($refs -notcontains $ag.Id) { $null = Update-AzWvdWorkspace -ResourceGroupName $rg -Name $c.workspace_name -ApplicationGroupReference (@($refs) + $ag.Id) }
Step "   workspace $($c.workspace_name) now references $(@((Get-AzWvdWorkspace -ResourceGroupName $rg -Name $c.workspace_name).ApplicationGroupReference).Count) application groups"
if (@(Get-AzRoleAssignment -Scope $ag.Id -ObjectId $groupId -RoleDefinitionName $role -ErrorAction SilentlyContinue | Where-Object { $_.Scope -eq $ag.Id }).Count) {
    Step "   $role for $($c.assign_group) on the application group (exists)"
}
elseif ($canAssign) {
    $null = New-AzRoleAssignment -Scope $ag.Id -ObjectId $groupId -ObjectType Group -RoleDefinitionName $role
    Step "   $role for $($c.assign_group) on the application group"
}
else { Write-Warning "Assignment skipped: $noAssignMsg" }
if ($preferRemoteApp -and $hp.PreferredAppGroupType -ne 'RemoteApp') {
    $null = Update-AzWvdHostPool -ResourceGroupName $rg -Name $c.host_pool_name -PreferredAppGroupType RemoteApp
    Step "   $($c.host_pool_name) now prefers RemoteApp"
}
Step "Done. Next: refresh Windows App; '$($c.friendly_name)' lists the apps."
