<#
.SYNOPSIS
    Build NvShaderCleaner.ps1 into NvShaderCleaner.exe via ps2exe.

.DESCRIPTION
    Run on a Windows machine in PowerShell.
    Installs ps2exe from PowerShell Gallery if needed, then compiles the .exe
    with requireAdministrator manifest and an optional icon.

.NOTES
    Requirements: Windows, PowerShell 5.1+, Internet (once, to install ps2exe).
#>

[CmdletBinding()]
param(
    [string]$Source     = (Join-Path $PSScriptRoot 'NvShaderCleaner.ps1'),
    [string]$Output     = (Join-Path $PSScriptRoot 'NvShaderCleaner.exe'),
    [string]$Manifest   = (Join-Path $PSScriptRoot 'app.manifest'),
    [string]$IconFile   = (Join-Path $PSScriptRoot 'icon.ico'),
    [string]$Title      = 'NvShaderCleaner',
    [string]$Description= 'NVIDIA Shader Cache Cleaner',
    [string]$Company    = 'NvShaderCleaner',
    [string]$Version    = '1.0.0.0'
)

$ErrorActionPreference = 'Stop'

try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
} catch { }

if (-not (Test-Path $Source)) {
    throw "Source not found: $Source"
}

# 1. Install ps2exe if missing
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host '[BUILD] Installing ps2exe from PSGallery ...' -ForegroundColor Cyan
    try {
        if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        }
        Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
    } catch {
        throw "Failed to install ps2exe: $($_.Exception.Message)"
    }
}

Import-Module ps2exe -Force

# 2. Build
$invokeArgs = @{
    InputFile    = $Source
    OutputFile   = $Output
    NoConsole    = $true
    RequireAdmin = $true
    Title        = $Title
    Description  = $Description
    Company      = $Company
    Version      = $Version
    Product      = $Title
    Copyright    = "(c) $(Get-Date -Format yyyy) $Company"
}

if (Test-Path $IconFile) {
    $invokeArgs['IconFile'] = $IconFile
}

Write-Host "[BUILD] Building $Output ..." -ForegroundColor Cyan
Invoke-PS2EXE @invokeArgs

if (-not (Test-Path $Output)) {
    throw 'Build failed: output file was not created.'
}

# 3. Optionally embed our own manifest via mt.exe (if available)
if (Test-Path $Manifest) {
    $mt = Get-Command mt.exe -ErrorAction SilentlyContinue
    if ($mt) {
        Write-Host '[BUILD] Embedding manifest via mt.exe ...' -ForegroundColor Cyan
        & $mt.Source -nologo -manifest $Manifest "-outputresource:$Output;#1"
    } else {
        Write-Host '[BUILD] mt.exe not found, skipping manifest embed (ps2exe RequireAdmin is sufficient).' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host "[BUILD] Done: $Output" -ForegroundColor Green
Write-Host ''
Write-Host 'The tools\ folder will be created automatically on first run' -ForegroundColor Gray
Write-Host '(or you can unpack nvidiaProfileInspector.exe there in advance).' -ForegroundColor Gray
