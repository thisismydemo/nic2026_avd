# Template tokens: {{arc_agent_uri}}, {{arc_agent_directory}} (both required; Packer only).
# Installs the Azure Connected Machine agent but never connects it: connection happens per VM after Entra join.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$agentUri = '{{arc_agent_uri}}'
$agentDirectory = '{{arc_agent_directory}}'
if (-not $agentUri -or $agentUri.Contains('{{') -or -not $agentDirectory -or $agentDirectory.Contains('{{')) {
    throw 'Arc agent URI and installer directory must be supplied.'
}

$installer = Join-Path $agentDirectory 'AzureConnectedMachineAgent.msi'
try {
    if (-not (Test-Path -LiteralPath $agentDirectory)) {
        $null = New-Item -Path $agentDirectory -ItemType Directory
    }

    Invoke-WebRequest -Uri $agentUri -OutFile $installer -UseBasicParsing
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$installer`"", '/qn', '/norestart') -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "Arc agent installer exited with code $($process.ExitCode)."
    }

    $agentExecutable = Join-Path $env:ProgramW6432 'AzureConnectedMachineAgent\azcmagent.exe'
    if (-not (Test-Path -LiteralPath $agentExecutable)) {
        throw 'Arc agent executable was not found after installation.'
    }

    Write-Output 'Arc agent installation completed without connecting'
}
finally {
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
}
