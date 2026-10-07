#Requires -Version 7.0
# HybridCommon - pure helpers for the session-hosts-hybrid build scripts.
# Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-HybridMacAddress {
    <#
    .SYNOPSIS
    Converts a static MAC address to the format required by Hyper-V.
    .DESCRIPTION
    Accepts twelve hexadecimal digits or six hexadecimal pairs separated by colons or hyphens.
    .PARAMETER MacAddress
    MAC address to convert.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MacAddress
    )

    if ($MacAddress -cnotmatch '^(?:[0-9A-Fa-f]{12}|[0-9A-Fa-f]{2}([:-])(?:[0-9A-Fa-f]{2}\1){4}[0-9A-Fa-f]{2})$') {
        throw 'The MAC address must contain twelve hexadecimal digits or six consistently separated pairs.'
    }

    return $MacAddress.Replace('-', '').Replace(':', '').ToUpperInvariant()
}

function Resolve-HybridPath {
    <#
    .SYNOPSIS
    Resolves a child path beneath an allowed parent.
    .DESCRIPTION
    Uses full paths and a separator-aware comparison to reject traversal and sibling paths.
    .PARAMETER Parent
    Allowed parent directory.
    .PARAMETER Child
    Relative child path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Parent,

        [Parameter(Mandatory)]
        [string]$Child
    )

    $root = [IO.Path]::GetFullPath($Parent).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $resolved = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $Child))
    $prefix = $root + [IO.Path]::DirectorySeparatorChar

    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The resolved path is outside the allowed parent directory.'
    }

    return $resolved
}

function New-HybridUnattendXml {
    <#
    .SYNOPSIS
    Creates Windows unattended setup XML for a hybrid session host.
    .DESCRIPTION
    Obfuscates the administrator password in the Windows unattended-setup format (base64 of the UTF-16LE password plus the literal 'Password').
    .PARAMETER ComputerName
    Computer name, containing at most fifteen letters, digits, or hyphens.
    .PARAMETER TimeZone
    Windows time-zone identifier.
    .PARAMETER LocalAdminUsername
    Local administrator account name.
    .PARAMETER LocalAdminPassword
    Local administrator password.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure function that only builds an XML string.')]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [string]$TimeZone,

        [Parameter(Mandatory)]
        [string]$LocalAdminUsername,

        [Parameter(Mandatory)]
        [securestring]$LocalAdminPassword
    )

    if ($ComputerName -cnotmatch '^[A-Za-z0-9-]{1,15}$') {
        throw 'ComputerName must contain 1-15 letters, digits, or hyphens.'
    }

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($LocalAdminPassword)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($plain + 'Password'))
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        $plain = $null
    }

    $document = [xml]'<unattend xmlns="urn:schemas-microsoft-com:unattend" />'
    $namespace = $document.DocumentElement.NamespaceURI
    $add = {
        param($Parent, [string]$Name, $Value)
        $element = $document.CreateElement($Name, $namespace)
        if ($null -ne $Value) {
            $element.InnerText = [string]$Value
        }
        [void]$Parent.AppendChild($element)
        return $element
    }

    # Components must carry their full identity (architecture, token, language, scope) or Setup cannot match them.
    $wcm = 'http://schemas.microsoft.com/WMIConfig/2002/State'
    $document.DocumentElement.SetAttribute('xmlns:wcm', $wcm)
    $addComponent = {
        param($Parent, [string]$Name)
        $element = & $add $Parent 'component' $null
        $element.SetAttribute('name', $Name)
        $element.SetAttribute('processorArchitecture', 'amd64')
        $element.SetAttribute('publicKeyToken', '31bf3856ad364e35')
        $element.SetAttribute('language', 'neutral')
        $element.SetAttribute('versionScope', 'nonSxS')
        return $element
    }
    $addListItem = {
        param($Parent, [string]$Name)
        $element = & $add $Parent $Name $null
        $attribute = $document.CreateAttribute('wcm', 'action', $wcm)
        $attribute.Value = 'add'
        [void]$element.Attributes.Append($attribute)
        return $element
    }

    $specialize = & $add $document.DocumentElement 'settings' $null
    $specialize.SetAttribute('pass', 'specialize')
    $component = & $addComponent $specialize 'Microsoft-Windows-Shell-Setup'
    [void](& $add $component 'ComputerName' $ComputerName)
    [void](& $add $component 'TimeZone' $TimeZone)

    $deployment = & $addComponent $specialize 'Microsoft-Windows-Deployment'
    $run = & $add $deployment 'RunSynchronous' $null
    $command = & $addListItem $run 'RunSynchronousCommand'
    [void](& $add $command 'Order' '1')
    [void](& $add $command 'Path' 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\Join-Entra.ps1')

    # Learn: do not use SkipMachineOOBE to automate OOBE; use the Hide*/ProtectYourPC settings instead.
    $oobe = & $add $document.DocumentElement 'settings' $null
    $oobe.SetAttribute('pass', 'oobeSystem')
    $shell = & $addComponent $oobe 'Microsoft-Windows-Shell-Setup'
    $settings = & $add $shell 'OOBE' $null
    [void](& $add $settings 'HideEULAPage' 'true')
    [void](& $add $settings 'HideOEMRegistrationScreen' 'true')
    [void](& $add $settings 'HideOnlineAccountScreens' 'true')
    [void](& $add $settings 'HideWirelessSetupInOOBE' 'true')
    [void](& $add $settings 'ProtectYourPC' '3')
    $accounts = & $add $shell 'UserAccounts' $null
    $local = & $add $accounts 'LocalAccounts' $null
    $account = & $addListItem $local 'LocalAccount'
    [void](& $add $account 'Name' $LocalAdminUsername)
    [void](& $add $account 'Group' 'Administrators')
    $password = & $add $account 'Password' $null
    [void](& $add $password 'Value' $encoded)
    [void](& $add $password 'PlainText' 'false')

    return $document.OuterXml
}

function Get-HybridComputeSwitch {
    <#
    .SYNOPSIS
    Finds exactly one existing Network ATC compute switch.
    .DESCRIPTION
    Never creates or changes a virtual switch.
    .PARAMETER NamePattern
    Wildcard pattern matched against switch names.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$NamePattern
    )

    $found = @(Get-VMSwitch | Where-Object Name -Like $NamePattern)
    if ($found.Count -ne 1) {
        throw "Expected exactly one compute switch matching '$NamePattern'; found $($found.Count)."
    }

    return $found[0]
}

function Get-HybridVmPlan {
    <#
    .SYNOPSIS
    Returns the ordered build plan for one VM.
    .DESCRIPTION
    Produces step objects without making changes or accessing secrets.
    .PARAMETER VmName
    Name of the VM being planned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VmName
    )

    $steps = @(
        'Validate owner, inputs, VM absence, and compute switch'
        'Copy master VHDX'
        'Resize-VHD if required'
        'Mount-VHD'
        'Write unattend, provisioning package, and join script'
        'Dismount-VHD'
        'New-VM'
        'Set-VMProcessor'
        'Set-VMMemory'
        'Set-VMFirmware'
        'Set-VMKeyProtector'
        'Enable-VMTPM'
        'Set-VMNetworkAdapter'
        'Set-VMNetworkAdapterVlan'
        'Set-VM'
        'Add-ClusterVirtualMachineRole'
        'Set-ClusterOwnerNode'
        'Set-HybridAntiAffinity'
        'Start-VM only if requested'
    )
    $order = 0
    return @($steps | ForEach-Object {
            $order++
            [pscustomobject]@{
                Order  = $order
                Step   = $_
                Detail = $VmName
            }
        })
}

Export-ModuleMember -Function ConvertTo-HybridMacAddress, Resolve-HybridPath, New-HybridUnattendXml, Get-HybridComputeSwitch, Get-HybridVmPlan
