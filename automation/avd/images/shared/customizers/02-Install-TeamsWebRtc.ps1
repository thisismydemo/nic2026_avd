# Template tokens: {{install_teams_app}}, {{disable_teams_autoupdate}}.
# Teams media optimization: IsWVDEnvironment key, the Remote Desktop WebRTC Redirector Service, and (optionally) the new Teams app.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$installTeamsApp = '{{install_teams_app}}'
$disableTeamsAutoUpdate = '{{disable_teams_autoupdate}}'
$teamsKey = 'HKLM:\SOFTWARE\Microsoft\Teams'
$webrtcMsi = Join-Path $env:TEMP 'msrdcwebrtcsvc.msi'
$bootstrapper = Join-Path $env:TEMP 'teamsbootstrapper.exe'

if ($installTeamsApp -notin @('true', 'false') -or $disableTeamsAutoUpdate -notin @('true', 'false')) {
    throw 'Teams options must be true or false.'
}

try {
    # Never use -Force on an existing key: it would wipe the values it holds.
    if (-not (Test-Path -LiteralPath $teamsKey)) {
        $null = New-Item -Path $teamsKey
    }

    $null = New-ItemProperty -LiteralPath $teamsKey -Name IsWVDEnvironment -PropertyType DWord -Value 1 -Force
    if ($disableTeamsAutoUpdate -eq 'true') {
        $null = New-ItemProperty -LiteralPath $teamsKey -Name disableAutoUpdate -PropertyType DWord -Value 1 -Force
    }

    Invoke-WebRequest -Uri 'https://aka.ms/msrdcwebrtcsvc/msi' -OutFile $webrtcMsi -UseBasicParsing
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$webrtcMsi`"", '/quiet', '/norestart') -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "WebRTC installer exited with code $($process.ExitCode)."
    }

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
    Remove-Item -LiteralPath $webrtcMsi, $bootstrapper -Force -ErrorAction SilentlyContinue
}
