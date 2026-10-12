#Requires -Version 7.0
<#
.SYNOPSIS
Publishes redirections.xml to the redirections folder of the Azure Files profile share and gives the users group
read access to it, through the Files REST API (no SMB session needed).
.DESCRIPTION
Companion of Set-FslogixShareRootAclRest.ps1 (the root grants the users group Modify on the root folder only, so the
redirections folder needs its own read entry). Steps: validate the XML (no UNC path, well-formed); create the
'redirections' directory if missing; upload redirections.xml when the content differs; set the folder's descriptor
(SYSTEM and admins Full control, users Read and execute, inherited by files) and read it back. A 15-minute share SAS
held in memory authorises the calls. Without -Execute it prints the plan.
.PARAMETER SubscriptionId
Subscription of the storage account.
.PARAMETER ResourceGroupName
Resource group of the storage account.
.PARAMETER StorageAccountName
FSLogix storage account.
.PARAMETER ShareName
Profile share.
.PARAMETER UsersGroupObjectId
Entra object ID of the FSLogix users group.
.PARAMETER AdminsGroupObjectId
Entra object ID of the FSLogix admins group.
.PARAMETER RedirectionsPath
Local redirections.xml (default: the solution's file).
.PARAMETER Execute
Apply.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$StorageAccountName,
    [Parameter(Mandatory)][string]$ShareName,
    [Parameter(Mandatory)][guid]$UsersGroupObjectId,
    [Parameter(Mandatory)][guid]$AdminsGroupObjectId,
    [string]$RedirectionsPath = (Join-Path $PSScriptRoot '..\redirections.xml'),
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -Name FslogixCommon)) { Import-Module (Join-Path $PSScriptRoot 'FslogixCommon.psm1') }

$content = Get-Content -LiteralPath $RedirectionsPath -Raw
[void][xml]$content
if ($content -match '\\\\') { throw 'redirections.xml must not contain a UNC path.' }
$usersSid = ConvertTo-EntraGroupSid -ObjectId $UsersGroupObjectId
$adminsSid = ConvertTo-EntraGroupSid -ObjectId $AdminsGroupObjectId
# 0x1200a9 = read and execute (FILE_GENERIC_READ | FILE_GENERIC_EXECUTE)
$desired = "O:BAG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;$adminsSid)(A;OICI;0x1200a9;;;$usersSid)"
$version = '2024-11-04'

if (-not $Execute) {
    [pscustomobject]@{ Share = $ShareName; Folder = 'redirections'; Descriptor = $desired; Status = 'Planned' }
    return
}

$null = Set-AzContext -SubscriptionId $SubscriptionId -Tenant (Get-AzContext).Tenant.Id -WhatIf:$false
$context = (Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName).Context
$base = "https://$StorageAccountName.file.core.windows.net/$ShareName/redirections"
$sas = (New-AzStorageShareSASToken -ShareName $ShareName -Permission rwdlc -ExpiryTime (Get-Date).AddMinutes(15) -Context $context).TrimStart('?')
try {
    if (-not (Get-AzStorageFile -ShareName $ShareName -Path 'redirections' -Context $context -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess("$ShareName/redirections", 'Create directory')) {
            $null = New-AzStorageDirectory -ShareName $ShareName -Path 'redirections' -Context $context
        }
    }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("redirections-{0}.xml" -f [guid]::NewGuid())
    try {
        $existing = Get-AzStorageFile -ShareName $ShareName -Path 'redirections/redirections.xml' -Context $context -ErrorAction SilentlyContinue
        $same = $false
        if ($existing) {
            $null = Get-AzStorageFileContent -ShareName $ShareName -Path 'redirections/redirections.xml' -Destination $temp -Context $context -Force
            $same = (Get-Content -LiteralPath $temp -Raw) -ceq $content
        }
        if (-not $same -and $PSCmdlet.ShouldProcess("$ShareName/redirections/redirections.xml", 'Upload')) {
            $null = Set-AzStorageFileContent -ShareName $ShareName -Source $RedirectionsPath -Path 'redirections/redirections.xml' -Context $context -Force
        }
    }
    finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }

    if ($PSCmdlet.ShouldProcess("$ShareName/redirections", 'Set folder permissions')) {
        $created = Invoke-WebRequest -Method Put -Uri "https://$StorageAccountName.file.core.windows.net/$ShareName`?restype=share&comp=filepermission&$sas" `
            -Headers @{ 'x-ms-version' = $version } -ContentType 'application/json' -Body (@{ permission = $desired; format = 'sddl' } | ConvertTo-Json)
        $key = $created.Headers['x-ms-file-permission-key'] | Select-Object -First 1
        $set = $null
        for ($attempt = 1; $null -eq $set; $attempt++) {
            try {
                $set = Invoke-WebRequest -Method Put -Uri "$base`?restype=directory&comp=properties&$sas" -Headers @{
                    'x-ms-version' = $version; 'x-ms-file-permission-key' = $key; 'x-ms-file-attributes' = 'preserve'
                    'x-ms-file-creation-time' = 'preserve'; 'x-ms-file-last-write-time' = 'preserve'
                }
            }
            catch { if ($attempt -ge 6) { throw }; Start-Sleep -Seconds (5 * $attempt) }
        }
        $applied = $set.Headers['x-ms-file-permission-key'] | Select-Object -First 1
        $read = (Invoke-RestMethod -Method Get -Uri "https://$StorageAccountName.file.core.windows.net/$ShareName`?restype=share&comp=filepermission&$sas" `
                -Headers @{ 'x-ms-version' = $version; 'x-ms-file-permission-key' = $applied; 'x-ms-file-permission-format' = 'sddl' }).permission -replace 'S:NO_ACCESS_CONTROL$', ''
        if ($read -ne $desired) { throw "Read-back of the redirections folder permissions differs ($read)." }
    }
    [pscustomobject]@{ Share = $ShareName; Folder = 'redirections'; File = 'redirections.xml'; Status = 'Published' }
}
finally { $sas = $null }
