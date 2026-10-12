# Template tokens: {{install_teams_app}}, {{disable_teams_autoupdate}}.
# Teams media optimization: IsWVDEnvironment key, the Remote Desktop WebRTC Redirector Service, and (optionally) the new Teams app.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$installTeamsApp = '{{install_teams_app}}'
$disableTeamsAutoUpdate = '{{disable_teams_autoupdate}}'
if (-not (Get-Variable WebRtcRetainForVerification -ErrorAction SilentlyContinue)) { $WebRtcRetainForVerification = $false }
if (-not (Get-Variable WebRtcVerifyOnly -ErrorAction SilentlyContinue)) { $WebRtcVerifyOnly = $false }
$teamsKey = 'HKLM:\SOFTWARE\Microsoft\Teams'
$webrtcMsi = Join-Path $env:TEMP 'msrdcwebrtcsvc.msi'
$bootstrapper = Join-Path $env:TEMP 'teamsbootstrapper.exe'

if ($installTeamsApp -notin @('true', 'false') -or $disableTeamsAutoUpdate -notin @('true', 'false')) {
    throw 'Teams options must be true or false.'
}

function Test-MicrosoftSignedFile {
    param([Parameter(Mandatory)][string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    return ($signature.Status -eq 'Valid' -and $null -ne $signature.SignerCertificate -and $signature.SignerCertificate.Subject -match '(^|,\s*)O=Microsoft Corporation(,|$)')
}

function Get-WebRtcMsiMetadata {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-MicrosoftSignedFile $Path)) { throw 'WebRTC MSI must have a valid Microsoft signature.' }
    $installer = $null; $database = $null; $view = $null; $record = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.OpenDatabase($Path, 0) # Read-only database; no Win32_Product repair.
        $values = @{}
        foreach ($property in 'ProductVersion', 'ProductName', 'UpgradeCode', 'ProductCode') {
            $view = $database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$property'")
            $null = $view.Execute(); $record = $view.Fetch()
            if ($null -eq $record) { throw "WebRTC MSI property missing: $property." }
            $values[$property] = [string]$record.StringData(1)
            $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($record); $record = $null
            $null = $view.Close(); $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($view); $view = $null
        }
        $null = [version]$values.ProductVersion
        foreach ($property in 'UpgradeCode', 'ProductCode') { $null = [guid]$values[$property] }
        if ($values.ProductName -notmatch 'WebRTC.*Redirector') { throw 'Downloaded MSI is not the WebRTC Redirector family.' }
        $view = $database.OpenView('SELECT `ServiceInstall`.`Name`, `File`.`FileName`, `File`.`Version` FROM `ServiceInstall`, `Component`, `File` WHERE `ServiceInstall`.`Component_` = `Component`.`Component` AND `Component`.`KeyPath` = `File`.`File`')
        $null = $view.Execute()
        $services = @()
        while ($null -ne ($record = $view.Fetch())) {
            $services += [pscustomobject]@{ Name = [string]$record.StringData(1); FileName = ([string]$record.StringData(2) -split '\|')[-1]; Version = [string]$record.StringData(3) }
            $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($record); $record = $null
        }
        if ($services.Count -ne 1 -or $services[0].Name -cne 'RDWebRTCSvc' -or $services[0].FileName -cne 'MsRdcWebRTCSvc.exe' -or [string]::IsNullOrWhiteSpace($services[0].Version)) { throw 'WebRTC MSI service executable metadata is missing, ambiguous or unexpected.' }
        $values.ServiceName = $services[0].Name
        $values.ServiceFileName = $services[0].FileName
        $values.ServiceFileVersion = [version]$services[0].Version
        return [pscustomobject]$values
    }
    finally {
        foreach ($object in $record, $view, $database, $installer) {
            if ($null -ne $object -and [Runtime.InteropServices.Marshal]::IsComObject($object)) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($object) }
        }
    }
}

function Test-WebRtcCompatibility {
    param([Parameter(Mandatory)]$Metadata, [AllowEmptyCollection()][object[]]$Products, [bool]$ServiceProof)
    return ($ServiceProof -and @($Products | Where-Object {
                $_.Installed -and $_.RelatedFamily -and $_.Name -ceq $Metadata.ProductName -and $_.Version -ge [version]$Metadata.ProductVersion
            }).Count -gt 0)
}

function Get-WebRtcProgramFiles64Root {
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'WebRTC requires a 64-bit operating system.' }
    $base = $null; $key = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $key = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion')
        if ($null -eq $key) { throw '64-bit Program Files registry key is unavailable.' }
        $root = [string]$key.GetValue('ProgramFilesDir', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ([string]::IsNullOrWhiteSpace($root) -or $root -notmatch '^[A-Za-z]:\\' -or -not (Test-Path -LiteralPath $root -PathType Container)) { throw '64-bit Program Files registry root is invalid.' }
        return [IO.Path]::GetFullPath($root).TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    }
    finally { if ($null -ne $key) { $key.Dispose() }; if ($null -ne $base) { $base.Dispose() } }
}

function Get-WebRtcInstalledState {
    param([Parameter(Mandatory)]$Metadata)
    $installer = $null
    $binaryVersion = $null; $incomplete = 0
    $reason = [ordered]@{ Process64Bit = [Environment]::Is64BitProcess; ProductCount = 0; NameVersionMatch = $false; ServicePresent = $false; ServiceEnabled = $false; PathParsed = $false; RootValid = $false; PathWithinRoot = $false; BinaryNameMatches = $false; BinaryExists = $false; SignatureValid = $false; FileVersionCompatible = $false }
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $type = $installer.GetType()
        $related = @($type.InvokeMember('RelatedProducts', [Reflection.BindingFlags]::GetProperty, $null, $installer, @($Metadata.UpgradeCode)))
        $products = foreach ($product in @($related + $Metadata.ProductCode | Select-Object -Unique)) {
            try {
                $state = [int]$type.InvokeMember('ProductState', [Reflection.BindingFlags]::GetProperty, $null, $installer, @([string]$product))
                if ($state -ne 5) { continue } # INSTALLSTATE_DEFAULT; advertised alone is insufficient.
                $name = [string]$type.InvokeMember('ProductInfo', [Reflection.BindingFlags]::GetProperty, $null, $installer, @([string]$product, 'ProductName'))
                $version = [version]$type.InvokeMember('ProductInfo', [Reflection.BindingFlags]::GetProperty, $null, $installer, @([string]$product, 'VersionString'))
                $assignment = [int]$type.InvokeMember('ProductInfo', [Reflection.BindingFlags]::GetProperty, $null, $installer, @([string]$product, 'AssignmentType'))
                $publisher = [string]$type.InvokeMember('ProductInfo', [Reflection.BindingFlags]::GetProperty, $null, $installer, @([string]$product, 'Publisher'))
                $code = [guid]([string]$product)
                [pscustomobject]@{ MachineAssigned = ($assignment -eq 1); Code = $code.ToString('B'); Name = $name; Version = $version; Publisher = $publisher; Installed = $true; RelatedFamily = $true }
            }
            catch { $incomplete++; continue } # Incomplete product registration is not proof.
        }
        $reason.ProductCount = @($products).Count
        $reason.NameVersionMatch = Test-WebRtcCompatibility -Metadata $Metadata -Products @($products) -ServiceProof $true
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='RDWebRTCSvc'" -ErrorAction SilentlyContinue
        $serviceProof = $false
        $reason.ServicePresent = $null -ne $service
        $reason.ServiceEnabled = $null -ne $service -and $service.StartMode -ne 'Disabled'
        if ($null -ne $service -and $service.StartMode -ne 'Disabled') {
            $match = [regex]::Match([string]$service.PathName, '^\s*"(?<path>[^"]+\.exe)"|^\s*(?<path>.+?\.exe)(?:\s|$)', 'IgnoreCase')
            if ($match.Success) {
                $binary = $match.Groups['path'].Value
                $reason.PathParsed = $true
                $allowedRoot = Get-WebRtcProgramFiles64Root
                $reason.RootValid = $true
                $reason.PathWithinRoot = [IO.Path]::IsPathRooted($binary) -and [IO.Path]::GetFullPath($binary).StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)
                $reason.BinaryNameMatches = [IO.Path]::GetFileName($binary) -ieq 'MsRdcWebRTCSvc.exe'
                $reason.BinaryExists = Test-Path -LiteralPath $binary -PathType Leaf
                if ($reason.PathWithinRoot -and $reason.BinaryNameMatches -and $reason.BinaryExists) {
                    $reason.SignatureValid = Test-MicrosoftSignedFile $binary
                    if ($reason.SignatureValid) {
                        $file = [Diagnostics.FileVersionInfo]::GetVersionInfo($binary)
                        $binaryVersion = [version]::new($file.FileMajorPart, $file.FileMinorPart, $file.FileBuildPart, $file.FilePrivatePart)
                        $reason.FileVersionCompatible = Test-WebRtcBinaryVersion -Metadata $Metadata -BinaryVersion $binaryVersion
                        $serviceProof = $reason.FileVersionCompatible
                    }
                }
            }
        }
        $reason.IncompleteProductCount = $incomplete
        $reason.ProductVersions = @($products | ForEach-Object { $_.Version.ToString() })
        $reason.ProductNameMatches = @($products | ForEach-Object { $_.Name -ceq $Metadata.ProductName })
        $reason.ProductPublisherMatches = @($products | ForEach-Object { $_.Publisher -ceq 'Microsoft Corporation' })
        $reason.DownloadProductVersion = [string]$Metadata.ProductVersion
        $reason.DownloadFileVersion = [string]$Metadata.ServiceFileVersion
        $reason.InstalledFileVersion = if ($null -ne $binaryVersion) { $binaryVersion.ToString() } else { '' }
        $trustedService = $reason.ServicePresent -and $reason.ServiceEnabled -and $reason.PathParsed -and $reason.RootValid -and $reason.PathWithinRoot -and $reason.BinaryNameMatches -and $reason.BinaryExists -and $reason.SignatureValid
        return [pscustomobject]@{ Products = @($products); IncompleteProductCount = $incomplete; TrustedService = $trustedService; BinaryVersion = $binaryVersion; Compatible = (Test-WebRtcCompatibility -Metadata $Metadata -Products @($products) -ServiceProof $serviceProof) }
    }
    finally {
        Write-Information -MessageData ('WebRTC installed proof: ' + ($reason | ConvertTo-Json -Compress)) -InformationAction Continue
        if ($null -ne $installer) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) }
    }
}

function Get-WebRtcInstalledProof {
    param([Parameter(Mandatory)]$Metadata)
    $state = Get-WebRtcInstalledState -Metadata $Metadata
    return [bool]$state.Compatible
}

function Test-WebRtcOlderReplacement {
    param([Parameter(Mandatory)]$Metadata, [Parameter(Mandatory)]$State)
    if ($State.IncompleteProductCount -ne 0 -or @($State.Products).Count -ne 1 -or -not $State.TrustedService -or $null -eq $State.BinaryVersion) { return $false }
    $product = $State.Products[0]
    $parsed = [guid]::Empty
    return ($product.Installed -and $product.MachineAssigned -and $product.RelatedFamily -and $product.Name -ceq $Metadata.ProductName -and $product.Publisher -ceq 'Microsoft Corporation' -and [guid]::TryParse([string]$product.Code, [ref]$parsed) -and $parsed -ne [guid]::Empty -and $product.Version -lt [version]$Metadata.ProductVersion -and $State.BinaryVersion -lt [version]$Metadata.ServiceFileVersion)
}

function Test-WebRtcProductInstalled {
    param([Parameter(Mandatory)][guid]$ProductCode)
    $installer = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $state = [int]$installer.GetType().InvokeMember('ProductState', [Reflection.BindingFlags]::GetProperty, $null, $installer, @($ProductCode.ToString('B')))
        return ($state -eq 5)
    }
    finally { if ($null -ne $installer) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) } }
}

function Test-WebRtcBinaryVersion {
    param([Parameter(Mandatory)]$Metadata, [Parameter(Mandatory)][version]$BinaryVersion)
    return ($BinaryVersion -ge [version]$Metadata.ServiceFileVersion)
}

function Install-WebRtcMsi {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Metadata)
    if (Get-WebRtcInstalledProof $Metadata) { Write-Output 'Compatible signed WebRTC Redirector already installed; keeping its version.'; return }
    $state = Get-WebRtcInstalledState -Metadata $Metadata
    $replaced = $false
    if (Test-WebRtcOlderReplacement -Metadata $Metadata -State $state) {
        # Re-read immediately: only the single exact proven older family product may be removed.
        $fresh = Get-WebRtcInstalledState -Metadata $Metadata
        if (-not (Test-WebRtcOlderReplacement -Metadata $Metadata -State $fresh) -or $fresh.Products[0].Code -cne $state.Products[0].Code -or $fresh.Products[0].Version -ne $state.Products[0].Version -or $fresh.BinaryVersion -ne $state.BinaryVersion) { throw 'WebRTC older-product evidence changed; replacement refused.' }
        $removal = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $fresh.Products[0].Code, '/quiet', '/norestart') -Wait -PassThru
        if ($removal.ExitCode -notin @(0, 3010)) { throw "WebRTC exact older-product removal failed with code $($removal.ExitCode)." }
        if (Test-WebRtcProductInstalled -ProductCode ([guid]$fresh.Products[0].Code)) { throw 'WebRTC older product remains installed after removal.' }
        $replaced = $true
    }
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$Path`"", '/quiet', '/norestart') -Wait -PassThru
    if ($process.ExitCode -eq 1638) {
        if ($replaced) { throw 'WebRTC replacement installation returned 1638; replacement rejected.' }
        if (Get-WebRtcInstalledProof $Metadata) { Write-Output 'WebRTC 1638 independently verified as a compatible signed installed version.'; return }
        throw 'WebRTC installer returned 1638 without compatible installed-product and service proof.'
    }
    if ($process.ExitCode -notin @(0, 3010)) { throw "WebRTC installer exited with code $($process.ExitCode)." }
    if (-not (Get-WebRtcInstalledProof $Metadata)) { throw 'WebRTC installation completed without fresh compatible signed-product and service proof.' }
}

function Get-WebRtcVerificationCache {
    param([switch]$Create)
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    if ($programData -notmatch '^[A-Za-z]:\\' -or -not (Test-Path -LiteralPath $programData -PathType Container)) { throw 'Trusted ProgramData root unavailable.' }
    $ancestor = Get-Item -LiteralPath $programData -Force
    while ($null -ne $ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'ProgramData ancestors cannot use reparse points.' }
        $ancestor = $ancestor.Parent
    }
    $root = Join-Path $programData 'WebRtcImageBuildCache'
    $existingRoot = Get-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
    if ($null -ne $existingRoot -and ($existingRoot.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Verification cache cannot be a reparse point.' }
    if ($Create -and $null -eq $existingRoot) {
        $null = New-Item -ItemType Directory -Path $root
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $null = $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
            $identity = [Security.Principal.SecurityIdentifier]::new($sid)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $null = $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $root -AclObject $acl
    }
    $item = Get-Item -LiteralPath $root -Force
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Verification cache cannot use reparse points.' }
        $item = $item.Parent
    }
    $acl = Get-Acl -LiteralPath $root
    $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($ownerSid -notin @('S-1-5-18', 'S-1-5-32-544')) { throw 'Verification cache owner must be SYSTEM or Administrators.' }
    if (-not $acl.AreAccessRulesProtected) { throw 'Verification cache permissions must be protected.' }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-18', 'S-1-5-32-544')) { throw 'Verification cache has unexpected access.' }
    }
    return $root
}

try {
    if ($WebRtcVerifyOnly) {
        $cache = Get-WebRtcVerificationCache
        $cachedMsi = Join-Path $cache 'reviewed.msi'
        $cachedHash = Join-Path $cache 'reviewed.sha256'
        foreach ($path in $cachedMsi, $cachedHash) {
            if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Verification cache file cannot be a reparse point.' }
        }
        try {
            $expected = (Get-Content -LiteralPath $cachedHash -Raw).Trim()
            if ($expected -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $cachedMsi -Algorithm SHA256).Hash -cne $expected) { throw 'Retained WebRTC MSI changed before final verification.' }
            $retainedMetadata = Get-WebRtcMsiMetadata -Path $cachedMsi
            if (-not (Get-WebRtcInstalledProof -Metadata $retainedMetadata)) { throw 'Post-restart WebRTC signed product and service verification failed.' }
            Write-Output 'Post-restart WebRTC verification passed.'
        }
        finally { Remove-Item -LiteralPath $cachedMsi, $cachedHash -Force -ErrorAction SilentlyContinue }
        return
    }
    # Never use -Force on an existing key: it would wipe the values it holds.
    if (-not (Test-Path -LiteralPath $teamsKey)) {
        $null = New-Item -Path $teamsKey
    }

    $null = New-ItemProperty -LiteralPath $teamsKey -Name IsWVDEnvironment -PropertyType DWord -Value 1 -Force
    if ($disableTeamsAutoUpdate -eq 'true') {
        $null = New-ItemProperty -LiteralPath $teamsKey -Name disableAutoUpdate -PropertyType DWord -Value 1 -Force
    }

    Invoke-WebRequest -Uri 'https://aka.ms/msrdcwebrtcsvc/msi' -OutFile $webrtcMsi -UseBasicParsing
    $metadata = Get-WebRtcMsiMetadata -Path $webrtcMsi
    if ($WebRtcRetainForVerification) {
        $cache = Get-WebRtcVerificationCache -Create
        $cachedMsi = Join-Path $cache 'reviewed.msi'
        $cachedHash = Join-Path $cache 'reviewed.sha256'
        $existingMsi = Get-Item -LiteralPath $cachedMsi -Force -ErrorAction SilentlyContinue
        $existingHash = Get-Item -LiteralPath $cachedHash -Force -ErrorAction SilentlyContinue
        if ($null -ne $existingMsi -or $null -ne $existingHash) { throw 'Verification cache already contains a retained installer.' }
        Copy-Item -LiteralPath $webrtcMsi -Destination $cachedMsi
        $hash = (Get-FileHash -LiteralPath $webrtcMsi -Algorithm SHA256).Hash
        if ((Get-FileHash -LiteralPath $cachedMsi -Algorithm SHA256).Hash -cne $hash) { throw 'Retained WebRTC MSI hash mismatch.' }
        Set-Content -LiteralPath $cachedHash -Value $hash -Encoding ascii
    }
    Install-WebRtcMsi -Path $webrtcMsi -Metadata $metadata

    if ($installTeamsApp -eq 'true') {
        Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409' -OutFile $bootstrapper -UseBasicParsing
        $process = Start-Process -FilePath $bootstrapper -ArgumentList '-p' -Wait -PassThru
        if ($process.ExitCode -notin @(0, 3010)) {
            throw "Teams bootstrapper exited with code $($process.ExitCode)."
        }
    }

    Write-Output 'Teams and WebRTC configuration completed'
}
finally {
    if (-not $WebRtcVerifyOnly) { Remove-Item -LiteralPath $webrtcMsi, $bootstrapper -Force -ErrorAction SilentlyContinue }
}
