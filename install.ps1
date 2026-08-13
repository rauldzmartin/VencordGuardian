<#
.SYNOPSIS
  Installs or updates VencordGuardian.

.DESCRIPTION
  Downloads VencordGuardian.ps1 to %LOCALAPPDATA%\VencordGuardian and runs it.
  Safe to re-run: it always overwrites with the latest version and re-runs the repair.
#>
$ErrorActionPreference = 'Stop'

$url = 'https://raw.githubusercontent.com/rauldzmartin/VencordGuardian/main/VencordGuardian.ps1'
$destDir = Join-Path $env:LOCALAPPDATA 'VencordGuardian'
$dest = Join-Path $destDir 'VencordGuardian.ps1'

New-Item -ItemType Directory -Force -Path $destDir | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing

Write-Host "[vencord] Installed to $dest"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dest
