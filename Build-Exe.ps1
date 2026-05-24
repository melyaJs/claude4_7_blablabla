<#
.SYNOPSIS
    Сборка NvShaderCleaner.ps1 в NvShaderCleaner.exe через ps2exe.

.DESCRIPTION
    Запускать на Windows-машине в обычном PowerShell.
    Скрипт сам установит модуль ps2exe (из PowerShell Gallery) при необходимости,
    а затем соберёт .exe с манифестом requireAdministrator и (опционально) иконкой.

.NOTES
    Требования:
      • Windows
      • PowerShell 5.1+ (рекомендуется 7+)
      • Интернет для первой установки ps2exe
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

# Снимаем ограничение ExecutionPolicy только для текущего процесса, чтобы
# пользователю не нужно было выполнять Set-ExecutionPolicy отдельной командой.
try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
} catch { }

if (-not (Test-Path $Source)) {
    throw "Не найден исходник: $Source"
}

# 1. Установить ps2exe, если ещё не установлен
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host '[BUILD] Устанавливаю модуль ps2exe из PSGallery...' -ForegroundColor Cyan
    try {
        if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        }
        Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
    } catch {
        throw "Не удалось установить ps2exe: $($_.Exception.Message)"
    }
}

Import-Module ps2exe -Force

# 2. Сборка
$invokeArgs = @{
    InputFile      = $Source
    OutputFile     = $Output
    NoConsole      = $true
    RequireAdmin   = $true
    Title          = $Title
    Description    = $Description
    Company        = $Company
    Version        = $Version
    Product        = $Title
    Copyright      = "(c) $(Get-Date -Format yyyy) $Company"
}

if (Test-Path $IconFile) {
    $invokeArgs['IconFile'] = $IconFile
}

Write-Host "[BUILD] Сборка $Output ..." -ForegroundColor Cyan
Invoke-PS2EXE @invokeArgs

if (-not (Test-Path $Output)) {
    throw 'Сборка не удалась: выходной файл не создан.'
}

# 3. Опционально — встроить наш собственный манифест (если ps2exe не сделал
#    requireAdministrator достаточно жёстко). Используем mt.exe, если доступен.
if (Test-Path $Manifest) {
    $mt = Get-Command mt.exe -ErrorAction SilentlyContinue
    if ($mt) {
        Write-Host '[BUILD] Встраиваю manifest через mt.exe ...' -ForegroundColor Cyan
        & $mt.Source -nologo -manifest $Manifest "-outputresource:$Output;#1"
    } else {
        Write-Host '[BUILD] mt.exe не найден в PATH — пропускаю встраивание manifest. ' `
                   '(RequireAdmin от ps2exe уже включён, этого обычно достаточно.)' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host "[BUILD] Готово: $Output" -ForegroundColor Green
Write-Host ''
Write-Host 'Положите рядом папку tools\ (она создастся автоматически при первом запуске,' -ForegroundColor Gray
Write-Host 'либо вы можете заранее распаковать туда nvidiaProfileInspector.exe).' -ForegroundColor Gray
