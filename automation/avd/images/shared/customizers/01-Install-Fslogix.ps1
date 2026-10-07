# Template tokens: none.
# Installs the current FSLogix release (Learn: aka.ms/fslogix_download; /install /quiet /norestart). No share path is configured here.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$downloadUri = 'https://aka.ms/fslogix_download'
$archive = Join-Path $env:TEMP 'fslogix_download.zip'
$extractDirectory = Join-Path $env:TEMP ([guid]::NewGuid().ToString())

try {
    Invoke-WebRequest -Uri $downloadUri -OutFile $archive -UseBasicParsing
    Expand-Archive -LiteralPath $archive -DestinationPath $extractDirectory
    $installer = Join-Path $extractDirectory 'x64\Release\FSLogixAppsSetup.exe'
    if (-not (Test-Path -LiteralPath $installer)) {
        throw 'FSLogix installer was not found in the archive.'
    }

    $process = Start-Process -FilePath $installer -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "FSLogix installer exited with code $($process.ExitCode)."
    }

    Write-Output 'FSLogix installation completed'
}
finally {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
