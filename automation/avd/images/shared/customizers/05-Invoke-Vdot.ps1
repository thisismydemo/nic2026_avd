# Template tokens: {{vdot_archive_uri}}, {{vdot_archive_sha256}} (both required when enabled; an empty uri skips VDOT).
# Virtual Desktop Optimization Tool: a pinned, checksummed archive only.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$archiveUri = '{{vdot_archive_uri}}'
$expectedHash = '{{vdot_archive_sha256}}'
if (-not $archiveUri -or $archiveUri.Contains('{{')) {
    Write-Output 'VDOT skipped'
    exit 0
}

if ($expectedHash -notmatch '^[a-fA-F0-9]{64}$') {
    throw 'VDOT archive SHA-256 must contain 64 hexadecimal characters.'
}

$archive = Join-Path $env:TEMP 'vdot.zip'
$extractDirectory = Join-Path $env:TEMP ([guid]::NewGuid().ToString())

try {
    Invoke-WebRequest -Uri $archiveUri -OutFile $archive -UseBasicParsing
    $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ($actualHash -ine $expectedHash) {
        throw 'VDOT archive SHA-256 mismatch.'
    }

    Expand-Archive -LiteralPath $archive -DestinationPath $extractDirectory
    $tool = Get-ChildItem -LiteralPath $extractDirectory -Filter 'Windows_VDOT.ps1' -Recurse -File |
        Select-Object -First 1
    if (-not $tool) {
        throw 'Windows_VDOT.ps1 was not found in the archive.'
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool.FullName -Optimizations All -AcceptEULA
    if ($LASTEXITCODE -ne 0) {
        throw "VDOT exited with code $LASTEXITCODE."
    }

    Write-Output 'VDOT optimization completed'
}
finally {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
