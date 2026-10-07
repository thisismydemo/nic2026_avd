# Template tokens: {{shortpath_port}} (integer, 1024-65535).
# RDP Shortpath for managed networks: UDP listener port and the inbound firewall rule.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$port = 0
if (-not [int]::TryParse('{{shortpath_port}}', [ref]$port) -or $port -lt 1024 -or $port -gt 65535) {
    throw 'Shortpath port must be an integer from 1024 through 65535.'
}

$listener = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
$null = New-ItemProperty -LiteralPath $listener -Name fUseUdpPortRedirector -PropertyType DWord -Value 1 -Force
$null = New-ItemProperty -LiteralPath $listener -Name UdpPortNumber -PropertyType DWord -Value $port -Force

$ruleName = 'RemoteDesktop-UserMode-In-Shortpath-UDP'
if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
    $rule = @{
        DisplayName = 'Remote Desktop - Shortpath (UDP-In)'
        Action      = 'Allow'
        Description = 'Inbound rule for the Remote Desktop service to allow RDP Shortpath traffic.'
        Group       = '@FirewallAPI.dll,-28752'
        Name        = $ruleName
        PolicyStore = 'PersistentStore'
        Profile     = @('Domain', 'Private')
        Service     = 'TermService'
        Protocol    = 'UDP'
        LocalPort   = $port
        Program     = '%SystemRoot%\system32\svchost.exe'
        Enabled     = 'True'
    }
    $null = New-NetFirewallRule @rule
}

Write-Output 'Shortpath listener configuration completed'
