# FslogixCommon — plan builders and thin wrappers for the avd-fslogix scripts.
# Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
Set-StrictMode -Version Latest

function Assert-FslogixUnc {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -cnotmatch '^\\\\[^\\]+\\[^\\]+$') {
        throw "Expected a UNC share root without a trailing backslash: $Value"
    }
}

function Invoke-FslogixIcacls {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $lines = @(& icacls.exe @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed (exit code $LASTEXITCODE): $($lines -join '; ')"
    }
    return $lines
}

function Get-FslogixAclRule {
    # Reads the ACL of a path as SIDs (never names: icacls and Get-Acl print resolved names for well-known principals).
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        [pscustomobject]@{
            Sid         = $rule.IdentityReference.Value
            AccessType  = [string]$rule.AccessControlType
            Rights      = [int]$rule.FileSystemRights
            Inheritance = [int]$rule.InheritanceFlags
            Propagation = [int]$rule.PropagationFlags
            Inherited   = [bool]$rule.IsInherited
        }
    }
}

function Get-FslogixMpPreference {
    param()
    return Get-MpPreference -ErrorAction Stop
}

function Add-FslogixMpExclusion {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Thin wrapper; the calling script runs it behind ShouldProcess and -Execute.')]
    param(
        [Parameter(Mandatory)][ValidateSet('ExclusionPath', 'ExclusionProcess')][string]$Kind,
        [Parameter(Mandatory)][string]$Value
    )
    $parameters = @{ $Kind = $Value }
    Add-MpPreference @parameters -ErrorAction Stop
}

<#
.SYNOPSIS
Builds a read-only registry setting plan.
.DESCRIPTION
Resolves share tokens and compares the shared configuration with the selected registry root.
#>
function Get-FslogixSettingPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SettingsPath,
        [Parameter(Mandatory)][string]$ProfileShareUnc,
        [Parameter(Mandatory)][string]$OdfcShareUnc,
        [ValidateSet('Production', 'Rehearsal')][string]$Mode = 'Production',
        [string]$RegistryRoot = 'HKLM:'
    )
    Assert-FslogixUnc $ProfileShareUnc
    Assert-FslogixUnc $OdfcShareUnc
    $raw = Get-Content -LiteralPath $SettingsPath -Raw -ErrorAction Stop
    # JSON-escape the share paths: a UNC path holds backslashes, which must stay valid inside the JSON strings
    $profileEscaped = $ProfileShareUnc.Replace('\', '\\')
    $odfcEscaped = $OdfcShareUnc.Replace('\', '\\')
    $raw = $raw.Replace('{{profile_share_unc}}', $profileEscaped).Replace('{{odfc_share_unc}}', $odfcEscaped)
    $settings = ConvertFrom-Json -InputObject $raw -AsHashtable -ErrorAction Stop
    $areas = [ordered]@{
        kerberos = @{ Relative = 'SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters'; Values = $settings.kerberos }
        azuread  = @{ Relative = 'Software\Policies\Microsoft\AzureADAccount'; Values = $settings.azuread }
        profiles = @{ Relative = 'SOFTWARE\FSLogix\Profiles'; Values = $settings.profiles }
        odfc     = @{ Relative = 'SOFTWARE\Policies\FSLogix\ODFC'; Values = $settings.odfc }
    }
    $modeValues = $settings.profiles_by_mode[$Mode.ToLowerInvariant()]
    foreach ($name in $modeValues.Keys) {
        $areas.profiles.Values[$name] = $modeValues[$name]
    }
    foreach ($area in $areas.Keys) {
        $path = $RegistryRoot.TrimEnd('\') + '\' + $areas[$area].Relative
        $properties = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
        foreach ($name in $areas[$area].Values.Keys) {
            $desired = $areas[$area].Values[$name]
            $type = if ($desired -is [string]) { 'String' } else { 'DWord' }
            $current = $null
            if ($null -ne $properties) {
                $property = $properties.PSObject.Properties[$name]
                if ($null -ne $property) { $current = $property.Value }
            }
            # the registry value KIND must match too (REG_SZ vs REG_EXPAND_SZ, or a string where a DWORD is expected)
            $kindMatches = $true
            if ($null -ne $current) {
                $kindMatches = try { ((Get-Item -LiteralPath $path -ErrorAction Stop).GetValueKind($name)).ToString() -eq $type } catch { $false }
            }
            $isEqual = if ($null -eq $current -or -not $kindMatches) { $false }
            elseif ($type -eq 'DWord') { $current -is [int] -and $current -eq [int]$desired }
            else { $current -is [string] -and $current -ceq $desired }
            [pscustomobject]@{
                Area    = $area
                Path    = $path
                Name    = $name
                Type    = $type
                Desired = $desired
                Current = $current
                Action  = if ($isEqual) { 'none' } else { 'set' }
            }
        }
    }
}

<#
.SYNOPSIS
Converts an Entra group object ID to its S-1-12-1 SID.
#>
function ConvertTo-EntraGroupSid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ObjectId)
    $guid = [guid]::Empty
    if (-not [guid]::TryParseExact($ObjectId, 'D', [ref]$guid)) {
        throw 'ObjectId must be a GUID in D format.'
    }
    $bytes = $guid.ToByteArray()
    $parts = for ($index = 0; $index -lt 16; $index += 4) {
        [BitConverter]::ToUInt32($bytes, $index)
    }
    return 'S-1-12-1-' + ($parts -join '-')
}

<#
.SYNOPSIS
Builds ordered icacls arguments for both share roots.
#>
function Get-FslogixAclPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfileShareUnc,
        [Parameter(Mandatory)][string]$OdfcShareUnc,
        [Parameter(Mandatory)][string]$UsersGroupObjectId,
        [Parameter(Mandatory)][string]$AdminsGroupObjectId
    )
    Assert-FslogixUnc $ProfileShareUnc
    Assert-FslogixUnc $OdfcShareUnc
    $users = ConvertTo-EntraGroupSid $UsersGroupObjectId
    $admins = ConvertTo-EntraGroupSid $AdminsGroupObjectId
    foreach ($share in @(
            @{ Name = 'profiles'; Root = $ProfileShareUnc },
            @{ Name = 'odfc'; Root = $OdfcShareUnc }
        )) {
        [pscustomobject]@{
            Share     = $share.Name
            Root      = $share.Root
            Arguments = [string[]]@(
                $share.Root, '/inheritance:r',
                '/remove', '*S-1-5-11', '*S-1-5-32-545',
                '/grant:r',
                '*S-1-5-18:(OI)(CI)F',
                "*$($admins):(OI)(CI)F",
                "*$($users):(M)",
                '*S-1-3-0:(OI)(CI)(IO)M'
            )
        }
    }
}

<#
.SYNOPSIS
Compares the ACL rules of a share root with the permitted set and returns the problems found.
.DESCRIPTION
The permitted DACL is exactly four allow entries: SYSTEM and the admins group (Full control, this folder, subfolders and files),
the users group (Modify, this folder only) and CREATOR OWNER (Modify, subfolders and files only). Any other principal, any deny
entry, any inherited entry, a missing entry, or a wrong right or inheritance setting is reported. Pure function: no file access.
#>
function Test-FslogixAclRule {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Rules,
        [Parameter(Mandatory)][string]$UsersSid,
        [Parameter(Mandatory)][string]$AdminsSid
    )
    $fullControl = 0x1F01FF
    $modify = 0x1301BF
    $containerObject = 3   # ContainerInherit, ObjectInherit
    $inheritOnly = 2
    $expected = @(
        @{ Sid = 'S-1-5-18'; Name = 'SYSTEM'; Mask = $fullControl; Inheritance = $containerObject; Propagation = 0 },
        @{ Sid = $AdminsSid; Name = 'admins group'; Mask = $fullControl; Inheritance = $containerObject; Propagation = 0 },
        @{ Sid = $UsersSid; Name = 'users group'; Mask = $modify; Inheritance = 0; Propagation = 0 },
        @{ Sid = 'S-1-3-0'; Name = 'CREATOR OWNER'; Mask = $modify; Inheritance = $containerObject; Propagation = $inheritOnly }
    )
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($rule in $Rules) {
        if (@($expected | Where-Object { $_.Sid -ieq $rule.Sid }).Count -eq 0) {
            $problems.Add("unexpected principal $($rule.Sid) ($($rule.AccessType))")
        }
        elseif ($rule.AccessType -ne 'Allow') {
            $problems.Add("deny entry for $($rule.Sid)")
        }
        elseif ($rule.Inherited) {
            $problems.Add("inherited entry for $($rule.Sid)")
        }
    }
    foreach ($want in $expected) {
        $mine = @($Rules | Where-Object { $_.Sid -ieq $want.Sid -and $_.AccessType -eq 'Allow' -and -not $_.Inherited })
        if ($mine.Count -eq 0) { $problems.Add("missing entry for $($want.Name) ($($want.Sid))"); continue }
        if ($mine.Count -gt 1) { $problems.Add("more than one entry for $($want.Name)") }
        foreach ($entry in $mine) {
            if (($entry.Rights -band $want.Mask) -ne $want.Mask) { $problems.Add("$($want.Name): rights are not the expected set") }
            if ($entry.Inheritance -ne $want.Inheritance -or $entry.Propagation -ne $want.Propagation) { $problems.Add("$($want.Name): inheritance or propagation differs") }
        }
    }
    return [string[]]$problems.ToArray()
}

Export-ModuleMember -Function Get-FslogixSettingPlan, ConvertTo-EntraGroupSid, Get-FslogixAclPlan, Test-FslogixAclRule
