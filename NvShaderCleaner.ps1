<#
.SYNOPSIS
    NvShaderCleaner - clean NVIDIA shader cache on Windows 10/11.
#>

[CmdletBinding()]
param(
    [switch]$Elevated
)

# ============================================================================
#                                CONSTANTS
# ============================================================================

$Script:AppName       = 'NvShaderCleaner'
$Script:AppDataDir    = Join-Path $env:LOCALAPPDATA $Script:AppName
$Script:StateFile     = Join-Path $Script:AppDataDir 'state.json'
$Script:LogFile       = Join-Path $Script:AppDataDir 'log.txt'
$Script:TaskName      = 'NvShaderCleaner_Resume'

$Script:NpiVersion    = '2.4.0.4'
$Script:NpiUrl        = "https://github.com/Orbmu2k/nvidiaProfileInspector/releases/download/$($Script:NpiVersion)/nvidiaProfileInspector.zip"
$Script:NpiExeName    = 'nvidiaProfileInspector.exe'

# NVAPI Setting IDs (decimal) for .nip files
# PS_SHADERDISKCACHE_MAX_SIZE_ID = 0x00AC8497 = 11306135
# Values: 0 = Disabled, 4294967295 (0xFFFFFFFF) = Unlimited
$Script:ShaderCacheSizeSettingId    = '11306135'
$Script:ShaderCacheSizeSettingName  = 'Shader disk cache maximum size'
$Script:ShaderCacheSize_Disabled    = '0'
$Script:ShaderCacheSize_Unlimited   = '4294967295'

$Script:NvidiaProcessNames = @(
    'nvcontainer',
    'NVDisplay.Container',
    'NVIDIA Share',
    'NVIDIA Web Helper',
    'NvBackend',
    'NvTelemetryContainer',
    'nvsphelper64',
    'nvsphelper',
    'NVIDIA Overlay',
    'ShadowPlay',
    'nvcplui',
    'NvNodejsLauncher',
    'NVIDIA app',
    'NVIDIA GeForce Experience',
    'GfExperience',
    'NVIDIA Network Service',
    'nvxdsync',
    'nvxdbat'
)

# ============================================================================
#                               HELPERS
# ============================================================================

function Initialize-AppFolder {
    if (-not (Test-Path $Script:AppDataDir)) {
        New-Item -ItemType Directory -Path $Script:AppDataDir -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO','WARN','ERROR','OK')] [string] $Level = 'INFO'
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Message"
    try {
        Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8
    } catch { }
    try { Write-Host $line } catch { }
}

function Get-AppDir {
    try {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exePath -and ($exePath -notmatch 'powershell|pwsh|conhost')) {
            return Split-Path -Parent $exePath
        }
    } catch { }
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($MyInvocation.MyCommand.Path) { return Split-Path -Parent $MyInvocation.MyCommand.Path }
    return (Get-Location).Path
}

function Get-SelfExePath {
    try {
        $p = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($p) { return $p }
    } catch { }
    return $null
}

function Test-Administrator {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevate {
    $exe = Get-SelfExePath
    if (-not $exe) {
        Show-ErrorBox 'Не удалось определить путь к .exe для повышения прав.'
        exit 1
    }
    try {
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList '-Elevated' | Out-Null
    } catch {
        Show-ErrorBox "Запуск с правами администратора отменён: $($_.Exception.Message)"
        exit 1
    }
    exit 0
}

# ============================================================================
#                              STATE MACHINE
# ============================================================================

function Get-State {
    if (-not (Test-Path $Script:StateFile)) {
        return [pscustomobject]@{
            Step      = 'INIT'
            StartedAt = (Get-Date).ToString('o')
            NpiPath   = $null
            SteamPath = $null
        }
    }
    try {
        return Get-Content -Path $Script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log "Cannot read state.json, starting over: $($_.Exception.Message)" 'WARN'
        return [pscustomobject]@{
            Step      = 'INIT'
            StartedAt = (Get-Date).ToString('o')
            NpiPath   = $null
            SteamPath = $null
        }
    }
}

function Save-State {
    param([Parameter(Mandatory)] $State)
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $Script:StateFile -Encoding UTF8
}

function Clear-State {
    if (Test-Path $Script:StateFile) {
        Remove-Item $Script:StateFile -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
#                         UI (WPF / MessageBox)
# ============================================================================

function Initialize-UI {
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
    Add-Type -AssemblyName WindowsBase -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
}

function Show-InfoBox {
    param([Parameter(Mandatory)][string]$Message, [string]$Title = 'NvShaderCleaner')
    Initialize-UI
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Information') | Out-Null
}

function Show-ErrorBox {
    param([Parameter(Mandatory)][string]$Message, [string]$Title = 'NvShaderCleaner')
    Initialize-UI
    Write-Log $Message 'ERROR'
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Error') | Out-Null
}

function Show-WarnBox {
    param([Parameter(Mandatory)][string]$Message, [string]$Title = 'NvShaderCleaner')
    Initialize-UI
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Warning') | Out-Null
}

function Show-YesNoBox {
    param([Parameter(Mandatory)][string]$Message, [string]$Title = 'NvShaderCleaner')
    Initialize-UI
    $res = [System.Windows.MessageBox]::Show($Message, $Title, 'YesNo', 'Question')
    return ($res -eq [System.Windows.MessageBoxResult]::Yes)
}

function Show-RebootCountdown {
    param([int]$Seconds = 5, [string]$Reason = '')
    Initialize-UI

    # Build WPF window entirely in code to avoid FindName issues in ps2exe
    $window = New-Object System.Windows.Window
    $window.Title = 'NvShaderCleaner'
    $window.Height = 220
    $window.Width = 460
    $window.WindowStartupLocation = 'CenterScreen'
    $window.ResizeMode = 'NoResize'
    $window.WindowStyle = 'None'
    $window.AllowsTransparency = $true
    $window.Opacity = 0.98
    $window.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#1E1E2E')

    $border = New-Object System.Windows.Controls.Border
    $border.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#76B900')
    $border.BorderThickness = [System.Windows.Thickness]::new(2)
    $border.CornerRadius = [System.Windows.CornerRadius]::new(8)

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = [System.Windows.Thickness]::new(20)
    $rd0 = New-Object System.Windows.Controls.RowDefinition; $rd0.Height = 'Auto'
    $rd1 = New-Object System.Windows.Controls.RowDefinition; $rd1.Height = 'Auto'
    $rd2 = New-Object System.Windows.Controls.RowDefinition; $rd2.Height = '*'
    $rd3 = New-Object System.Windows.Controls.RowDefinition; $rd3.Height = 'Auto'
    $grid.RowDefinitions.Add($rd0)
    $grid.RowDefinitions.Add($rd1)
    $grid.RowDefinitions.Add($rd2)
    $grid.RowDefinitions.Add($rd3)

    $titleTb = New-Object System.Windows.Controls.TextBlock
    $titleTb.Text = [char]::ConvertFromUtf32(0x26A0) + " Перезагрузка компьютера"
    $titleTb.FontSize = 20
    $titleTb.FontWeight = 'Bold'
    $titleTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#76B900')
    $titleTb.HorizontalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetRow($titleTb, 0)
    $grid.Children.Add($titleTb) | Out-Null

    $reasonTb = New-Object System.Windows.Controls.TextBlock
    $reasonTb.Text = $Reason
    $reasonTb.FontSize = 13
    $reasonTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#CDD6F4')
    $reasonTb.TextWrapping = 'Wrap'
    $reasonTb.HorizontalAlignment = 'Center'
    $reasonTb.Margin = [System.Windows.Thickness]::new(0,10,0,0)
    [System.Windows.Controls.Grid]::SetRow($reasonTb, 1)
    $grid.Children.Add($reasonTb) | Out-Null

    $countTb = New-Object System.Windows.Controls.TextBlock
    $countTb.Text = "$Seconds сек."
    $countTb.FontSize = 32
    $countTb.FontWeight = 'Bold'
    $countTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F9E2AF')
    $countTb.HorizontalAlignment = 'Center'
    $countTb.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetRow($countTb, 2)
    $grid.Children.Add($countTb) | Out-Null

    $cancelBtn = New-Object System.Windows.Controls.Button
    $cancelBtn.Content = 'Отмена (перезагрузить позже вручную)'
    $cancelBtn.Height = 34
    $cancelBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#45475A')
    $cancelBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#CDD6F4')
    $cancelBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#585B70')
    $cancelBtn.FontSize = 12
    [System.Windows.Controls.Grid]::SetRow($cancelBtn, 3)
    $grid.Children.Add($cancelBtn) | Out-Null

    $border.Child = $grid
    $window.Content = $border

    $script:_rebootCancelled = $false
    $script:_secondsLeft     = $Seconds

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $timer.Add_Tick({
        $script:_secondsLeft--
        if ($script:_secondsLeft -le 0) {
            $timer.Stop()
            $window.Close()
        } else {
            $countTb.Text = "$($script:_secondsLeft) сек."
        }
    })

    $cancelBtn.Add_Click({
        $script:_rebootCancelled = $true
        $timer.Stop()
        $window.Close()
    })

    $timer.Start()
    $window.ShowDialog() | Out-Null
    return (-not $script:_rebootCancelled)
}

function Show-FinalSuccessWindow {
    Initialize-UI

    $window = New-Object System.Windows.Window
    $window.Title = 'NvShaderCleaner'
    $window.Height = 320
    $window.Width = 520
    $window.WindowStartupLocation = 'CenterScreen'
    $window.ResizeMode = 'NoResize'
    $window.WindowStyle = 'None'
    $window.AllowsTransparency = $true
    $window.Opacity = 0.98
    $window.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#1E1E2E')

    $border = New-Object System.Windows.Controls.Border
    $border.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#76B900')
    $border.BorderThickness = [System.Windows.Thickness]::new(2)
    $border.CornerRadius = [System.Windows.CornerRadius]::new(10)

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = [System.Windows.Thickness]::new(24)
    for ($i = 0; $i -lt 5; $i++) {
        $rd = New-Object System.Windows.Controls.RowDefinition
        $rd.Height = if ($i -eq 3) { '*' } else { 'Auto' }
        $grid.RowDefinitions.Add($rd)
    }

    $checkTb = New-Object System.Windows.Controls.TextBlock
    $checkTb.Text = [char]::ConvertFromUtf32(0x2714)
    $checkTb.FontSize = 64
    $checkTb.FontWeight = 'Bold'
    $checkTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#A6E3A1')
    $checkTb.HorizontalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetRow($checkTb, 0)
    $grid.Children.Add($checkTb) | Out-Null

    $doneTb = New-Object System.Windows.Controls.TextBlock
    $doneTb.Text = 'Готово!'
    $doneTb.FontSize = 26
    $doneTb.FontWeight = 'Bold'
    $doneTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#A6E3A1')
    $doneTb.HorizontalAlignment = 'Center'
    $doneTb.Margin = [System.Windows.Thickness]::new(0,4,0,0)
    [System.Windows.Controls.Grid]::SetRow($doneTb, 1)
    $grid.Children.Add($doneTb) | Out-Null

    $msgTb = New-Object System.Windows.Controls.TextBlock
    $msgTb.Text = 'Кэш шейдеров NVIDIA был успешно очищен.'
    $msgTb.FontSize = 14
    $msgTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#CDD6F4')
    $msgTb.HorizontalAlignment = 'Center'
    $msgTb.Margin = [System.Windows.Thickness]::new(0,12,0,0)
    $msgTb.TextWrapping = 'Wrap'
    $msgTb.TextAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetRow($msgTb, 2)
    $grid.Children.Add($msgTb) | Out-Null

    $detailsTb = New-Object System.Windows.Controls.TextBlock
    $detailsTb.Text = "Размер кэша шейдеров возвращён в значение «Без ограничений».`r`nПри следующем запуске игр шейдеры будут перекомпилированы заново."
    $detailsTb.FontSize = 11
    $detailsTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#A6ADC8')
    $detailsTb.HorizontalAlignment = 'Center'
    $detailsTb.Margin = [System.Windows.Thickness]::new(0,16,0,0)
    $detailsTb.TextWrapping = 'Wrap'
    $detailsTb.TextAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetRow($detailsTb, 3)
    $grid.Children.Add($detailsTb) | Out-Null

    $okBtn = New-Object System.Windows.Controls.Button
    $okBtn.Content = 'Закрыть'
    $okBtn.Height = 38
    $okBtn.Width = 160
    $okBtn.HorizontalAlignment = 'Center'
    $okBtn.Margin = [System.Windows.Thickness]::new(0,16,0,0)
    $okBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#76B900')
    $okBtn.Foreground = [System.Windows.Media.Brushes]::White
    $okBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#76B900')
    $okBtn.FontSize = 13
    $okBtn.FontWeight = 'Bold'
    [System.Windows.Controls.Grid]::SetRow($okBtn, 4)
    $grid.Children.Add($okBtn) | Out-Null

    $okBtn.Add_Click({ $window.Close() })

    $border.Child = $grid
    $window.Content = $border
    $window.ShowDialog() | Out-Null
}

# ============================================================================
#                        NVIDIA PROFILE INSPECTOR
# ============================================================================

function Ensure-NpiInstalled {
    $toolsDir = Join-Path (Get-AppDir) 'tools'
    $npiExe   = Join-Path $toolsDir $Script:NpiExeName

    if (Test-Path $npiExe) {
        Write-Log "NVIDIA Profile Inspector found: $npiExe" 'INFO'
        return $npiExe
    }

    Write-Log "NVIDIA Profile Inspector not found, downloading..." 'INFO'

    if (-not (Test-Path $toolsDir)) {
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    }

    $zipPath = Join-Path $toolsDir 'nvidiaProfileInspector.zip'

    $hasInternet = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect('github.com', 443, $null, $null)
        $ok  = $iar.AsyncWaitHandle.WaitOne(3000, $false)
        if ($ok -and $tcp.Connected) { $hasInternet = $true }
        $tcp.Close()
    } catch { $hasInternet = $false }

    if (-not $hasInternet) {
        $msg = "Нет подключения к интернету.`r`n`r`n"
        $msg += "Скачайте вручную:`r`n$($Script:NpiUrl)`r`n`r`n"
        $msg += "или любую версию с https://github.com/Orbmu2k/nvidiaProfileInspector/releases`r`n`r`n"
        $msg += "Распакуйте $($Script:NpiExeName) в папку:`r`n$toolsDir`r`n`r`n"
        $msg += "И запустите программу заново."
        Show-ErrorBox $msg
        exit 1
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 -bor [Net.SecurityProtocolType]::Tls11
    } catch {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    }

    try {
        Write-Log "Downloading $($Script:NpiUrl) ..." 'INFO'
        Invoke-WebRequest -Uri $Script:NpiUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
    } catch {
        $msg = "Не удалось скачать NVIDIA Profile Inspector.`r`nОшибка: $($_.Exception.Message)`r`n`r`n"
        $msg += "Скачайте вручную с`r`n$($Script:NpiUrl)`r`n"
        $msg += "и распакуйте $($Script:NpiExeName) в:`r`n$toolsDir"
        Show-ErrorBox $msg
        exit 1
    }

    try {
        Expand-Archive -Path $zipPath -DestinationPath $toolsDir -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    } catch {
        Show-ErrorBox "Не удалось распаковать NVIDIA Profile Inspector: $($_.Exception.Message)"
        exit 1
    }

    if (-not (Test-Path $npiExe)) {
        $found = Get-ChildItem -Path $toolsDir -Filter $Script:NpiExeName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            Move-Item -Path $found.FullName -Destination $npiExe -Force
        }
    }

    if (-not (Test-Path $npiExe)) {
        Show-ErrorBox "После распаковки не найден $($Script:NpiExeName) в $toolsDir."
        exit 1
    }

    Write-Log "NVIDIA Profile Inspector installed: $npiExe" 'OK'
    return $npiExe
}

function New-NipFile {
    <#
        Creates a .nip profile file (UTF-16 XML) that NPI can import via -silentImport.
    #>
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string] $SettingId,
        [Parameter(Mandatory)] [string] $SettingName,
        [Parameter(Mandatory)] [string] $SettingValue
    )
    $xml = @"
<?xml version="1.0" encoding="utf-16"?>
<ArrayOfProfile xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <Profile>
    <ProfileName>Base Profile</ProfileName>
    <Executeables />
    <Settings>
      <ProfileSetting>
        <SettingNameInfo>$SettingName</SettingNameInfo>
        <SettingID>$SettingId</SettingID>
        <SettingValue>$SettingValue</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
    </Settings>
  </Profile>
</ArrayOfProfile>
"@
    # .nip files must be UTF-16 (Unicode) for NPI to parse them
    $xml | Set-Content -Path $FilePath -Encoding Unicode -Force
    Write-Log "Created .nip file: $FilePath (value=$SettingValue)" 'INFO'
}

function Set-ShaderCacheSize {
    param(
        [Parameter(Mandatory)] [ValidateSet('Disabled','Unlimited')] [string] $Mode,
        [Parameter(Mandatory)] [string] $NpiPath
    )
    $value = if ($Mode -eq 'Disabled') { $Script:ShaderCacheSize_Disabled } else { $Script:ShaderCacheSize_Unlimited }
    Write-Log "Setting Shader Cache Size = $Mode (value=$value) via NPI -silentImport" 'INFO'

    $nipFile = Join-Path $Script:AppDataDir "shader_cache_$($Mode.ToLower()).nip"

    try {
        New-NipFile -FilePath $nipFile `
                    -SettingId $Script:ShaderCacheSizeSettingId `
                    -SettingName $Script:ShaderCacheSizeSettingName `
                    -SettingValue $value

        $proc = Start-Process -FilePath $NpiPath `
            -ArgumentList "`"$nipFile`"", '-silentImport' `
            -PassThru -WindowStyle Hidden -ErrorAction Stop

        $exited = $proc.WaitForExit(60000)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            throw "nvidiaProfileInspector не завершился за 60 секунд (завис)."
        }

        Write-Log "Shader Cache Size = $Mode applied successfully." 'OK'
    } catch {
        $msg = "Не удалось изменить «Размер кэша шейдеров» через NVIDIA Profile Inspector.`r`n`r`n"
        $msg += "Ошибка: $($_.Exception.Message)`r`n`r`n"
        $msg += "Проверьте, что NPI присутствует в:`r`n$NpiPath`r`n"
        $msg += "и что установлены актуальные драйверы NVIDIA."
        Show-ErrorBox $msg
        throw
    } finally {
        Remove-Item $nipFile -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
#                          NVIDIA PROCESSES
# ============================================================================

function Get-RunningNvidiaProcesses {
    $list = @()
    foreach ($name in $Script:NvidiaProcessNames) {
        $p = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($p) { $list += $p }
    }
    $extra = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match '^(?i)(nv|nvidia)' -and ($list.Id -notcontains $_.Id)
    }
    if ($extra) { $list += $extra }
    return $list
}

function Stop-NvidiaProcessesWithConsent {
    $procs = Get-RunningNvidiaProcesses
    if (-not $procs -or $procs.Count -eq 0) {
        Write-Log "No running NVIDIA processes found." 'INFO'
        return $true
    }

    $uniqueNames = ($procs | Select-Object -ExpandProperty ProcessName -Unique)
    $namesList = ""
    foreach ($n in $uniqueNames) { $namesList += "`r`n  - $n" }

    $msg = "Обнаружены запущенные процессы NVIDIA:$namesList`r`n`r`n"
    $msg += "Для продолжения очистки их необходимо закрыть.`r`nЗакрыть эти процессы сейчас?"

    if (-not (Show-YesNoBox -Message $msg -Title 'NvShaderCleaner')) {
        Write-Log "User refused to close NVIDIA processes." 'WARN'
        return $false
    }

    foreach ($p in $procs) {
        try {
            Write-Log "Stopping $($p.ProcessName) (PID $($p.Id))..." 'INFO'
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
        } catch {
            Write-Log "Failed to stop $($p.ProcessName): $($_.Exception.Message)" 'WARN'
        }
    }
    Start-Sleep -Seconds 2
    return $true
}

# ============================================================================
#                       CACHE FOLDER DELETION
# ============================================================================

function Remove-NvidiaCacheFolders {
    $base    = Join-Path $env:LOCALAPPDATA 'NVIDIA'
    $targets = @('DXCache', 'GLCache')
    $removed = @()
    $errors  = @()

    if (-not (Test-Path $base)) {
        Write-Log "Folder $base not found, nothing to delete." 'INFO'
        return @{ Removed = $removed; Errors = $errors }
    }

    foreach ($name in $targets) {
        $path = Join-Path $base $name
        if (-not (Test-Path $path)) {
            Write-Log "Folder $path does not exist, skipping." 'INFO'
            continue
        }
        try {
            Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            Write-Log "Deleted $path" 'OK'
            $removed += $path
        } catch {
            Write-Log "Error deleting $path : $($_.Exception.Message)" 'ERROR'
            $errors += "$path : $($_.Exception.Message)"
        }
    }
    return @{ Removed = $removed; Errors = $errors }
}

function Find-SteamPath {
    $candidates = @(
        @{ Path='HKCU:\Software\Valve\Steam';                   Name='SteamPath'   },
        @{ Path='HKLM:\SOFTWARE\WOW6432Node\Valve\Steam';       Name='InstallPath' },
        @{ Path='HKLM:\SOFTWARE\Valve\Steam';                   Name='InstallPath' }
    )
    foreach ($c in $candidates) {
        try {
            $v = (Get-ItemProperty -Path $c.Path -Name $c.Name -ErrorAction Stop).$($c.Name)
            if ($v -and (Test-Path $v)) { return ($v -replace '/', '\') }
        } catch { }
    }
    return $null
}

function Get-AllSteamLibraries {
    $main = Find-SteamPath
    if (-not $main) { return @() }

    $libs = @($main)
    $vdf  = Join-Path $main 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        $content = Get-Content -Path $vdf -Raw -ErrorAction SilentlyContinue
        if ($content) {
            $regexMatches = [regex]::Matches($content, '"path"\s*"([^"]+)"')
            foreach ($m in $regexMatches) {
                $p = $m.Groups[1].Value -replace '\\\\', '\'
                if ($p -and (Test-Path $p) -and ($libs -notcontains $p)) { $libs += $p }
            }
        }
    }
    return $libs
}

function Remove-SteamShaderCache730 {
    $libs = Get-AllSteamLibraries
    $cleared = @()
    $missing = @()
    $errors  = @()

    if (-not $libs -or $libs.Count -eq 0) {
        Write-Log "Steam not found in registry." 'WARN'
        return @{ Cleared = $cleared; Missing = $missing; Errors = $errors; SteamFound = $false }
    }

    foreach ($lib in $libs) {
        $path = Join-Path $lib 'steamapps\shadercache\730'
        if (-not (Test-Path $path)) {
            Write-Log "Path $path does not exist, skipping." 'INFO'
            $missing += $path
            continue
        }
        try {
            Get-ChildItem -Path $path -Force -ErrorAction Stop | ForEach-Object {
                Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction Stop
            }
            Write-Log "Cleared $path" 'OK'
            $cleared += $path
        } catch {
            Write-Log "Error clearing $path : $($_.Exception.Message)" 'ERROR'
            $errors += "$path : $($_.Exception.Message)"
        }
    }

    return @{ Cleared = $cleared; Missing = $missing; Errors = $errors; SteamFound = $true }
}

# ============================================================================
#                         TASK SCHEDULER (RESUME)
# ============================================================================

function Register-ResumeTask {
    $exe = Get-SelfExePath
    if (-not $exe) {
        Show-ErrorBox 'Не удалось определить путь к .exe для создания задачи.'
        throw 'self exe not found'
    }

    Unregister-ResumeTask

    $user = "$env:USERDOMAIN\$env:USERNAME"
    Write-Log "Registering scheduled task '$($Script:TaskName)' for $user -> $exe" 'INFO'

    $action    = New-ScheduledTaskAction -Execute $exe -Argument '-Elevated'
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = 'PT1M'
    $principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Register-ScheduledTask -TaskName $Script:TaskName `
                           -Action $action `
                           -Trigger $trigger `
                           -Principal $principal `
                           -Settings $settings `
                           -Force | Out-Null
}

function Unregister-ResumeTask {
    try {
        $t = Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
        if ($t) {
            Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Log "Scheduled task '$($Script:TaskName)' removed." 'INFO'
        }
    } catch {
        Write-Log "Failed to remove task '$($Script:TaskName)': $($_.Exception.Message)" 'WARN'
    }
}

# ============================================================================
#                              REBOOT
# ============================================================================

function Invoke-RebootOrAbort {
    param([string]$Reason = 'Для применения изменений требуется перезагрузка.')

    $doReboot = Show-RebootCountdown -Seconds 5 -Reason $Reason
    if ($doReboot) {
        Write-Log "Initiating reboot (shutdown /r /t 5)." 'INFO'
        & shutdown.exe /r /t 5 /c "NvShaderCleaner: reboot to apply shader cache settings."
    } else {
        Write-Log "User cancelled automatic reboot." 'WARN'
        Show-InfoBox "Автоматическая перезагрузка отменена.`r`n`r`nПерезагрузите компьютер вручную.`r`nПрограмма автоматически продолжит работу после следующего входа в систему." 'NvShaderCleaner'
    }
    exit 0
}

# ============================================================================
#                                STEPS
# ============================================================================

function Invoke-Step-Init {
    Write-Log '=== STEP 1: setting Shader Cache Size = Disabled ===' 'INFO'

    $npi = Ensure-NpiInstalled
    try {
        Set-ShaderCacheSize -Mode Disabled -NpiPath $npi
    } catch {
        exit 1
    }

    try {
        Register-ResumeTask
    } catch {
        Show-ErrorBox "Не удалось зарегистрировать задачу возобновления: $($_.Exception.Message)"
        exit 1
    }

    $state = Get-State
    $state.Step    = 'AFTER_REBOOT_1'
    $state.NpiPath = $npi
    Save-State $state

    Invoke-RebootOrAbort -Reason 'Кэш шейдеров отключён. Компьютер перезагрузится, после входа очистка продолжится автоматически.'
}

function Invoke-Step-AfterReboot1 {
    Write-Log '=== STEP 2: cleaning shader cache folders ===' 'INFO'

    if (-not (Stop-NvidiaProcessesWithConsent)) {
        $msg = "Очистка не может быть продолжена, пока запущены процессы NVIDIA.`r`n`r`n"
        $msg += "Закройте их вручную через Диспетчер задач и запустите программу заново."
        Show-WarnBox $msg 'NvShaderCleaner'
        exit 0
    }

    $nvResult    = Remove-NvidiaCacheFolders
    $steamResult = Remove-SteamShaderCache730

    $npi = (Get-State).NpiPath
    if (-not $npi -or -not (Test-Path $npi)) {
        $npi = Ensure-NpiInstalled
    }
    try {
        Set-ShaderCacheSize -Mode Unlimited -NpiPath $npi
    } catch {
        exit 1
    }

    $warnings = @()
    if (-not $steamResult.SteamFound) {
        $warnings += 'Steam не обнаружен - папка shadercache\730 пропущена.'
    } elseif ($steamResult.Cleared.Count -eq 0 -and $steamResult.Missing.Count -gt 0) {
        $warnings += "Папка shadercache\730 не найдена ни в одной библиотеке Steam - пропущена."
    }
    if ($nvResult.Errors.Count -gt 0) {
        $warnings += "Ошибки при удалении папок NVIDIA:`r`n  " + ($nvResult.Errors -join "`r`n  ")
    }
    if ($steamResult.Errors.Count -gt 0) {
        $warnings += "Ошибки при очистке Steam:`r`n  " + ($steamResult.Errors -join "`r`n  ")
    }
    if ($warnings.Count -gt 0) {
        Show-WarnBox (($warnings -join "`r`n`r`n")) 'NvShaderCleaner'
    }

    $state = Get-State
    $state.Step = 'AFTER_REBOOT_2'
    Save-State $state

    try {
        Register-ResumeTask
    } catch {
        Show-ErrorBox "Не удалось зарегистрировать задачу финального запуска: $($_.Exception.Message)"
        exit 1
    }

    Invoke-RebootOrAbort -Reason 'Очистка завершена. Компьютер перезагрузится ещё раз, после чего будет показано итоговое окно.'
}

function Invoke-Step-AfterReboot2 {
    Write-Log '=== STEP 3: final window ===' 'INFO'

    Unregister-ResumeTask

    Show-FinalSuccessWindow

    Clear-State
    Write-Log '=== Done. State cleared. ===' 'OK'
}

# ============================================================================
#                                MAIN
# ============================================================================

function Main {
    Initialize-AppFolder

    Write-Log '----- NvShaderCleaner started -----' 'INFO'

    if (-not (Test-Administrator)) {
        Write-Log 'Not admin, requesting UAC...' 'INFO'
        Invoke-SelfElevate
        return
    }

    $state = Get-State
    Write-Log "Current step: $($state.Step)" 'INFO'

    try {
        switch ($state.Step) {
            'INIT'           { Invoke-Step-Init }
            'AFTER_REBOOT_1' { Invoke-Step-AfterReboot1 }
            'AFTER_REBOOT_2' { Invoke-Step-AfterReboot2 }
            'DONE'           { Clear-State; Invoke-Step-Init }
            default          { Clear-State; Invoke-Step-Init }
        }
    } catch {
        $msg = "Непредвиденная ошибка на шаге $($state.Step):`r`n`r`n$($_.Exception.Message)`r`n`r`nПодробности в логе:`r`n$($Script:LogFile)"
        Show-ErrorBox $msg
        Write-Log "FATAL: $($_.Exception.Message)`r`n$($_.ScriptStackTrace)" 'ERROR'
        exit 1
    }
}

Main
