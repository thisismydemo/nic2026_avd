#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
BeforeAll {
    $source = Join-Path $PSScriptRoot '../customizers/02-Install-TeamsWebRtc.ps1'
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Customizer syntax invalid' }
    foreach ($fn in $ast.FindAll({ param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    $script:metadata=[pscustomobject]@{ProductName='Remote Desktop WebRTC Redirector Service'; ProductVersion='1.5.0.0' }
}
Describe 'WebRTC compatibility and MSI conflict handling' {
    BeforeEach { Mock Get-WebRtcInstalledState { [pscustomobject]@{Products=@(); IncompleteProductCount=0; TrustedService=$false; BinaryVersion=$null; Compatible=$false } } }
    It 'compares executable versions independently of the MSI product version' {
        $m = [pscustomobject]@{ ProductVersion = '1.56.0'; ServiceFileVersion = [version]'10.1.2603.20001' }
        Test-WebRtcBinaryVersion $m ([version]'10.1.2603.20000') | Should -BeFalse
        Test-WebRtcBinaryVersion $m ([version]'10.1.2603.20001') | Should -BeTrue
        Test-WebRtcBinaryVersion $m ([version]'10.1.2603.20002') | Should -BeTrue
    }
    It 'uses the MSI internal service name rather than its executable stem' {
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../customizers/02-Install-TeamsWebRtc.ps1') -Raw) | Should -Match "Name='RDWebRTCSvc'"
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../customizers/02-Install-TeamsWebRtc.ps1') -Raw) | Should -Not -Match "Name='MsRdcWebRTCSvc'"
    }
    It 'requires an installed related product at the same or newer version and signed service proof' -ForEach @(
        @{Version='1.4.0.0'; Installed=$true; Related=$true; Service=$true; Expected=$false }
        @{Version='1.5.0.0'; Installed=$true; Related=$true; Service=$true; Expected=$true }
        @{Version='1.6.0.0'; Installed=$true; Related=$true; Service=$true; Expected=$true }
        @{Version='1.6.0.0'; Installed=$false; Related=$true; Service=$true; Expected=$false }
        @{Version='1.6.0.0'; Installed=$true; Related=$false; Service=$true; Expected=$false }
        @{Version='1.6.0.0'; Installed=$true; Related=$true; Service=$false; Expected=$false }
    ) {
        $product=[pscustomobject]@{Name=$metadata.ProductName; Version=[version]$Version; Installed=$Installed; RelatedFamily=$Related }
        Test-WebRtcCompatibility -Metadata $metadata -Products @($product) -ServiceProof $Service | Should -Be $Expected
    }
    It 'rejects missing product evidence even when a service exists' {
        Test-WebRtcCompatibility -Metadata $metadata -Products @() -ServiceProof $true | Should -BeFalse
    }
    It 'skips installation when compatible evidence is already proven' {
        Mock Get-WebRtcInstalledProof { $true }
        Mock Start-Process { throw 'Installer must not run' }
        Install-WebRtcMsi -Path 'C:\Temp\example.msi' -Metadata $metadata
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'rejects 1638 when the independent post-install proof is absent' {
        Mock Get-WebRtcInstalledProof { $false }
        Mock Start-Process { [pscustomobject]@{ExitCode=1638 } }
        { Install-WebRtcMsi -Path 'C:\Temp\example.msi' -Metadata $metadata } | Should -Throw '*1638 without compatible*'
        Should -Invoke Get-WebRtcInstalledProof -Times 2 -Exactly
    }
    It 'accepts 1638 only after a fresh independent proof succeeds' {
        $script:proofCalls=0
        Mock Get-WebRtcInstalledProof { $script:proofCalls++; $script:proofCalls -eq 2 }
        Mock Start-Process { [pscustomobject]@{ExitCode=1638 } }
        { Install-WebRtcMsi -Path 'C:\Temp\example.msi' -Metadata $metadata } | Should -Not -Throw
        Should -Invoke Get-WebRtcInstalledProof -Times 2 -Exactly
    }
    It 'does not forgive another installer failure' {
        Mock Get-WebRtcInstalledProof { $false }
        Mock Start-Process { [pscustomobject]@{ExitCode=1603 } }
        { Install-WebRtcMsi -Path 'C:\Temp\example.msi' -Metadata $metadata } | Should -Throw '*1603*'
    }
}

# Supply a signed Microsoft MSI fixture locally; CI does not download or install software.
Describe 'Windows Installer metadata output contract' {
    It 'returns exactly one complete metadata object from native COM' -Skip:([string]::IsNullOrWhiteSpace($env:NIC26_WEBRTC_TEST_MSI)) {
        $output = @(Get-WebRtcMsiMetadata -Path $env:NIC26_WEBRTC_TEST_MSI)
        $output.Count | Should -Be 1
        foreach ($key in 'ProductName', 'ProductVersion', 'ProductCode', 'UpgradeCode', 'ServiceName', 'ServiceFileName', 'ServiceFileVersion') {
            $output[0].PSObject.Properties.Name | Should -Contain $key
            [string]::IsNullOrWhiteSpace([string]$output[0].PSObject.Properties[$key].Value) | Should -BeFalse
        }
    }
}
Describe 'Native installed-proof output contract' {
    It 'uses the same existing 64-bit root and emits one Boolean plus safe information' -Skip:([string]::IsNullOrWhiteSpace($env:NIC26_WEBRTC_TEST_MSI)) {
        $root = @(Get-WebRtcProgramFiles64Root)
        $root.Count | Should -Be 1
        [IO.Path]::IsPathRooted($root[0]) | Should -BeTrue
        Test-Path -LiteralPath $root[0] -PathType Container | Should -BeTrue
        $nativeMetadata = @(Get-WebRtcMsiMetadata -Path $env:NIC26_WEBRTC_TEST_MSI)
        $information = @()
        $proof = @(Get-WebRtcInstalledProof -Metadata $nativeMetadata[0] -InformationVariable information -InformationAction SilentlyContinue)
        $proof.Count | Should -Be 1
        ($proof[0] -is [bool]) | Should -BeTrue
        $information.Count | Should -Be 1
        $flags = ($information[0].MessageData -replace '^WebRTC installed proof: ', '') | ConvertFrom-Json
        $flags.Process64Bit | Should -Be ([Environment]::Is64BitProcess)
        ($flags.ProductCount -is [int]) | Should -BeTrue
    }
}

Describe 'Exact older-family replacement guards' {
    BeforeAll {
        $script:upgradeMetadata=[pscustomobject]@{ProductName='Remote Desktop WebRTC Redirector Service'; ProductVersion='2.0.0'; ServiceFileVersion=[version]'10.2.0.0' }
    }
    It 'requires one trusted machine product and both strictly older versions' -ForEach @(
        @{Change='none'; Expected=$true }
        @{Change='publisher'; Expected=$false }
        @{Change='family'; Expected=$false }
        @{Change='machine'; Expected=$false }
        @{Change='name'; Expected=$false }
        @{Change='productVersion'; Expected=$false }
        @{Change='binaryVersion'; Expected=$false }
        @{Change='service'; Expected=$false }
        @{Change='multiple'; Expected=$false }
        @{Change='incomplete'; Expected=$false }
        @{Change='guid'; Expected=$false }
    ) {
        $product=[pscustomobject]@{Code=([guid]::NewGuid().ToString('B')); Installed=$true; MachineAssigned=$true; RelatedFamily=$true; Name=$upgradeMetadata.ProductName; Publisher='Microsoft Corporation'; Version=[version]'1.0.0' }
        $state=[pscustomobject]@{Products=@($product); IncompleteProductCount=0; TrustedService=$true; BinaryVersion=[version]'10.1.0.0' }
        switch ($Change) {
            publisher { $product.Publisher='Other' }
            family { $product.RelatedFamily=$false }
            machine { $product.MachineAssigned=$false }
            name { $product.Name='Other' }
            productVersion { $product.Version=[version]'2.0.0' }
            binaryVersion { $state.BinaryVersion=[version]'10.2.0.0' }
            service { $state.TrustedService=$false }
            multiple { $state.Products=@($product, $product) }
            incomplete { $state.IncompleteProductCount=1 }
            guid { $product.Code='invalid' }
        }
        Test-WebRtcOlderReplacement $upgradeMetadata $state | Should -Be $Expected
    }
}

Describe 'Guarded replacement execution' {
    BeforeAll {
        $script:m=[pscustomobject]@{ProductName='Remote Desktop WebRTC Redirector Service'; ProductVersion='2.0.0'; ServiceFileVersion=[version]'10.2.0.0' }
        $script:p=[pscustomobject]@{Code=([guid]::NewGuid().ToString('B')); Installed=$true; MachineAssigned=$true; RelatedFamily=$true; Name=$m.ProductName; Publisher='Microsoft Corporation'; Version=[version]'1.0.0' }
        $script:s=[pscustomobject]@{Products=@($p); IncompleteProductCount=0; TrustedService=$true; BinaryVersion=[version]'10.1.0.0' }
    }
    BeforeEach {
        Mock Get-WebRtcInstalledState { $s }
        $script:proofCall=0
        Mock Get-WebRtcInstalledProof { $script:proofCall++; $script:proofCall -gt 1 }
        Mock Test-WebRtcProductInstalled { $false }
        Mock Start-Process { [pscustomobject]@{ExitCode=0 } }
    }
    It 'removes only the proven product then installs and verifies fresh compatibility' {
        Install-WebRtcMsi -Path 'C:\Temp\example.msi' -Metadata $m
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq '/x' -and $ArgumentList[1] -eq $p.Code }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq '/i' }
        Should -Invoke Test-WebRtcProductInstalled -Times 1 -Exactly
        Should -Invoke Get-WebRtcInstalledProof -Times 2 -Exactly
    }
    It 'does not install while the removed product remains registered' {
        Mock Test-WebRtcProductInstalled { $true }
        { Install-WebRtcMsi -Path 'C:\Temp\example.msi' -Metadata $m } | Should -Throw '*remains installed*'
        Should -Invoke Start-Process -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq '/i' }
    }
    It 'rejects an unproven successful installation' {
        Mock Get-WebRtcInstalledProof { $false }
        { Install-WebRtcMsi -Path 'C:\Temp\example.msi' -Metadata $m } | Should -Throw '*without fresh compatible*'
    }
    It 'rejects replacement install 1638 even when old-product removal succeeded' {
        Mock Start-Process { if ($ArgumentList[0] -eq '/i') { [pscustomobject]@{ExitCode=1638 } }else { [pscustomobject]@{ExitCode=0 } } }
        { Install-WebRtcMsi -Path 'C:\Temp\example.msi' -Metadata $m } | Should -Throw '*replacement rejected*'
    }
}
