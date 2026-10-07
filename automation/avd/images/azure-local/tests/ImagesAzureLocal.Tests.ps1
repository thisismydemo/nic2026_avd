#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stubs mirror the real cmdlet signatures.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:importScript = Join-Path $script:root 'scripts/Import-AzureLocalImage.ps1'
    $script:parameters = @{
        AvdSubscriptionId     = 'avd-sub'
        AzlSubscriptionId     = 'azl-sub'
        GalleryImageVersionId = 'gallery-version-id'
        ImageName             = 'img-lab'
        CustomLocationId      = 'custom-location-id'
        ImageResourceGroup    = 'image-rg'
        Location              = 'test-region'
        TempDiskResourceGroup = 'disk-rg'
        TempDiskName          = 'import-disk'
    }

    # Real Az cmdlets are mocked when installed (Mock follows their signatures); otherwise stubs with the same parameters.
    if (-not (Get-Command Set-AzContext -ErrorAction SilentlyContinue)) { function Set-AzContext { param([string]$SubscriptionId) } }
    if (-not (Get-Command Get-AzDisk -ErrorAction SilentlyContinue)) { function Get-AzDisk { param([string]$ResourceGroupName, [string]$DiskName) } }
    if (-not (Get-Command New-AzDiskConfig -ErrorAction SilentlyContinue)) {
        function New-AzDiskConfig { param([string]$Location, [string]$CreateOption, $GalleryImageReference, [string]$SkuName, [string]$OsType, [string]$HyperVGeneration, [int]$DiskSizeGB) }
    }
    if (-not (Get-Command New-AzDisk -ErrorAction SilentlyContinue)) {
        function New-AzDisk { [CmdletBinding(SupportsShouldProcess)] param([string]$ResourceGroupName, [string]$DiskName, $Disk) }
    }
    if (-not (Get-Command Grant-AzDiskAccess -ErrorAction SilentlyContinue)) {
        function Grant-AzDiskAccess { [CmdletBinding(SupportsShouldProcess)] param([string]$ResourceGroupName, [string]$DiskName, [string]$Access, [int]$DurationInSecond) }
    }
    if (-not (Get-Command Revoke-AzDiskAccess -ErrorAction SilentlyContinue)) {
        function Revoke-AzDiskAccess { [CmdletBinding(SupportsShouldProcess)] param([string]$ResourceGroupName, [string]$DiskName) }
    }
    if (-not (Get-Command Remove-AzDisk -ErrorAction SilentlyContinue)) {
        function Remove-AzDisk { [CmdletBinding(SupportsShouldProcess)] param([string]$ResourceGroupName, [string]$DiskName, [switch]$Force) }
    }
    if (-not (Get-Command Invoke-AzCli -ErrorAction SilentlyContinue)) {
        function Invoke-AzCli { param([string[]]$Arguments) }
    }
}

AfterAll {
    Remove-Variable -Name ImageEvents, ImageShowCount, ImageCreateFails, ImageAlreadyExists -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Azure Local image solution' {
    It 'declares the manifest contract' {
        $manifest = Get-Content (Join-Path $script:root 'solution.yml') -Raw
        foreach ($key in @('name: avd-images-azure-local', 'scope: avd', 'depends_on:', 'gallery_image_version_id',
                'custom_location_id', 'storage_path_id', 'temp_disk_resource_group', 'sas_duration_seconds',
                'azl_image_id', 'secrets: []', 'destroy: supported', 'disk_import:')) {
            $manifest | Should -Match ([regex]::Escape($key))
        }
    }

    Context 'script behaviour' {
        BeforeEach {
            $global:ImageEvents = [System.Collections.Generic.List[string]]::new()
            $global:ImageShowCount = 0
            $global:ImageCreateFails = $false
            $global:ImageAlreadyExists = $false

            Mock Set-AzContext { $global:ImageEvents.Add('context') }
            Mock Get-AzDisk { $global:ImageEvents.Add('diskcheck'); return $null }
            Mock New-AzDiskConfig { $global:ImageEvents.Add('config'); return @{ Location = $Location } }
            Mock New-AzDisk { $global:ImageEvents.Add('disk') }
            Mock Grant-AzDiskAccess {
                $global:ImageEvents.Add('grant')
                return [pscustomobject]@{ AccessSAS = 'https://example.invalid/sas?sig=FAKESECRET' }
            }
            Mock Revoke-AzDiskAccess { $global:ImageEvents.Add('revoke') }
            Mock Remove-AzDisk { $global:ImageEvents.Add('remove') }
            Mock Invoke-AzCli {
                if ($Arguments[2] -eq 'show') {
                    $global:ImageShowCount++
                    $global:ImageEvents.Add('show')
                    if ($global:ImageAlreadyExists -or $global:ImageShowCount -gt 1) {
                        return @{ ExitCode = 0; StdOut = 'image-resource-id'; StdErr = '' }
                    }
                    return @{ ExitCode = 3; StdOut = ''; StdErr = '' }
                }
                $global:ImageEvents.Add('create')
                if ($global:ImageCreateFails) {
                    return @{ ExitCode = 1; StdOut = ''; StdErr = 'https://example.invalid/sas?sig=FAKESECRET' }
                }
                return @{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
        }

        It 'rejects the invalid name <_> before any call' -ForEach @('windows-11', 'IMG-x', 'img-Windows') {
            { & $script:importScript @script:parameters -ImageName $_ -Execute } | Should -Throw
            $global:ImageEvents.Count | Should -Be 0
        }

        It 'plans without contacting Azure or the CLI' {
            $plan = @(& $script:importScript @script:parameters)
            $plan[0] | Should -Match '^Plan:'
            $global:ImageEvents.Count | Should -Be 0
        }

        It 'imports, cleans up and returns the resource ID in order' {
            $result = & $script:importScript @script:parameters -Execute
            $result | Should -Be 'image-resource-id'
            ($global:ImageEvents -join ',') | Should -Be 'show,context,diskcheck,config,disk,grant,create,revoke,remove,show'
        }

        It 'never exposes the SAS, even when the CLI fails, and still cleans up' {
            $global:ImageCreateFails = $true
            $everything = & {
                try { & $script:importScript @script:parameters -Execute -InformationAction Continue -Verbose *>&1 }
                catch { $_ }
            } | Out-String
            $everything | Should -Not -Match 'FAKESECRET'
            ($global:ImageEvents -join ',') | Should -Be 'show,context,diskcheck,config,disk,grant,create,revoke,remove'
        }

        It 'refuses an existing image without creating a disk' {
            $global:ImageAlreadyExists = $true
            { & $script:importScript @script:parameters -Execute } | Should -Throw '*already exists*'
            ($global:ImageEvents -join ',') | Should -Be 'show'
        }

        It 'refuses a temporary disk name that is already in use and creates nothing' {
            Mock Get-AzDisk { $global:ImageEvents.Add('diskcheck'); return [pscustomobject]@{ Name = 'import-disk' } }
            { & $script:importScript @script:parameters -Execute } | Should -Throw '*already in use*'
            ($global:ImageEvents -join ',') | Should -Be 'show,context,diskcheck'
            Should -Invoke Remove-AzDisk -Times 0 -Exactly
        }

        It 'passes the storage path only when given' {
            & $script:importScript @script:parameters -Execute -StoragePathId 'storage-path-id' | Out-Null
            Should -Invoke Invoke-AzCli -Times 1 -Exactly -ParameterFilter { $Arguments -contains '--storage-path-id' -and $Arguments -contains 'storage-path-id' }
        }
    }
}
