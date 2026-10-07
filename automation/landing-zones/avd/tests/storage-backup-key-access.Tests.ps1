#Requires -Version 7.0
# Pester 5 - Azure Files backup needs 'Allow storage account key access' on the source account (Learn: support matrix for Azure Files backup),
# so the FSLogix account's shared-key setting must follow enable_backup in both tracks and in the validator.
BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
Describe 'FSLogix storage account key access follows enable_backup' {
    It 'Bicep: allowSharedKeyAccess is enable_backup, not a literal' {
        $b = Get-Content (Join-Path $script:root 'bicep\modules\storage.bicep') -Raw
        $b | Should -Match 'allowSharedKeyAccess: enable_backup'
        $b | Should -Not -Match 'allowSharedKeyAccess: (true|false)'
    }
    It 'Terraform: shared_access_key_enabled is var.enable_backup' {
        (Get-Content (Join-Path $script:root 'terraform\main.tf') -Raw) | Should -Match 'shared_access_key_enabled\s+= var\.enable_backup'
    }
    It 'the validator asserts the same pairing' {
        $s = Get-Content (Join-Path $script:root 'scripts\Test-AvdLandingZone.ps1') -Raw
        $s | Should -Match 'expectKey = \[bool\]\$inputs\.enable_backup'
        $s | Should -Not -Match "AllowSharedKeyAccess -eq \`$false\) 'shared key access is not disabled'"
    }
    It 'the account stays Kerberos-only with no default share permission' {
        $b = Get-Content (Join-Path $script:root 'bicep\modules\storage.bicep') -Raw
        $b | Should -Match "authenticationMethods: 'Kerberos'"
        $b | Should -Match "defaultSharePermission: 'None'"
    }
}

Describe 'AVD alert rules can see silent hosts and use real event levels (review R-38)' {
    BeforeAll {
        $script:mon = Get-Content (Join-Path $script:root 'bicep\modules\monitoring.bicep') -Raw
        $script:tfm = Get-Content (Join-Path $script:root 'terraform\main.tf') -Raw
    }
    It 'the host-unavailable rule looks back an hour and flags a host whose last row is old' {
        $script:mon | Should -Match 'ago\(1h\) \| summarize arg_max\(TimeGenerated, \*\) by SessionHostName \| where Status != "Available" or TimeGenerated < ago\(10m\)'
        $script:tfm | Should -Match 'ago\(1h\) \| summarize arg_max\(TimeGenerated, \*\) by SessionHostName'
        $script:mon | Should -Match "windowSize: 'PT1H'"
        $script:tfm | Should -Match 'window\s+= "PT1H"'
    }
    It 'the FSLogix rule uses the Error level of both channels, not hard-coded event ids' {
        $script:mon | Should -Not -Match 'EventID in \(26, 27\)'
        $script:tfm | Should -Not -Match 'EventID in \(26, 27\)'
        $script:mon | Should -Match 'EventLevelName == "Error"'
    }
    It 'every rule gets its own window in both tracks' {
        $script:mon | Should -Match 'windowSize: alert\.windowSize'
        $script:tfm | Should -Match 'window_duration\s+= each\.value\.window'
    }
}
