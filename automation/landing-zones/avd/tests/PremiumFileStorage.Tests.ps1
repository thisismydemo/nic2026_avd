#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
BeforeDiscovery {
    $script:HasAz = [bool](Get-Command az -ErrorAction SilentlyContinue)
}
Describe 'Compiled Premium FileStorage account and share tier separation' -Skip:(-not $HasAz) {
    BeforeAll {
        $source = Join-Path $PSScriptRoot '../bicep/modules/storage.bicep'
        $output = Join-Path $TestDrive 'storage.json'
        $diagnostics = & az bicep build --file $source --outfile $output 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($diagnostics -join "`n") }
        $script:Compiled = Get-Content $output -Raw | ConvertFrom-Json -AsHashtable
    }
    It 'uses the Premium SKU without sending the rejected Premium account access tier' {
        $parameters = $script:Compiled.resources.storageAccount.properties.parameters
        $parameters.kind.value | Should -Be 'FileStorage'
        $parameters.skuName.value | Should -Be 'Premium_LRS'
        if ($parameters.ContainsKey('accessTier')) {
            $parameters.accessTier.value | Should -Not -Be 'Premium' -Because 'Azure rejects this account property for FileStorage'
        }
    }
    It 'retains premium file-share tiers in the generated share loop' {
        $fileService = $script:Compiled.resources.storageAccount.properties.parameters.fileServices.value
        $shareCopy = @($fileService.copy | Where-Object name -EQ 'shares')
        $shareCopy.Count | Should -Be 1
        $shareCopy[0].input.accessTier | Should -Be 'Premium'
        $shareCopy[0].input.enabledProtocols | Should -Be 'SMB'
    }
    It 'preserves irreversible vault protection and cross-subscription restore settings' {
        $parameters = $script:Compiled.resources.recoveryVault.properties.parameters
        $parameters.softDeleteSettings.value.softDeleteState | Should -Be 'AlwaysON'
        $parameters.softDeleteSettings.value.enhancedSecurityState | Should -Be 'AlwaysON'
        $parameters.softDeleteSettings.value.softDeleteRetentionPeriodInDays | Should -Be "[parameters('backup_policy').soft_delete_retention_days]"
        $parameters.restoreSettings.value.crossSubscriptionRestoreSettings.crossSubscriptionRestoreState | Should -Be 'Enabled'
        $parameters.sourceScanConfiguration.value.state | Should -Be 'Disabled'
    }
}
