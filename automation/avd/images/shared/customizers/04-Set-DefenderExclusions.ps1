# Template tokens: {{defender_paths}}, {{defender_processes}} (semicolon-separated; empty allowed).
# Adds local Defender exclusions only: unresolved placeholders and UNC paths are skipped so no share path enters an image.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$rawPaths = '{{defender_paths}}'
$rawProcesses = '{{defender_processes}}'
$preferences = Get-MpPreference

foreach ($entry in ($rawPaths -split ';')) {
    $candidate = $entry.Trim()
    if (-not $candidate -or $candidate.Contains('{{') -or $candidate.StartsWith('\\')) {
        continue
    }

    if ($candidate -notin @($preferences.ExclusionPath)) {
        Add-MpPreference -ExclusionPath $candidate
    }
}

foreach ($entry in ($rawProcesses -split ';')) {
    $candidate = $entry.Trim()
    if (-not $candidate -or $candidate.Contains('{{') -or $candidate.StartsWith('\\')) {
        continue
    }

    if ($candidate -notin @($preferences.ExclusionProcess)) {
        Add-MpPreference -ExclusionProcess $candidate
    }
}

Write-Output 'Defender exclusions configuration completed'
