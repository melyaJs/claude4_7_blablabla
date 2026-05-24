<#
.SYNOPSIS
    NvShaderCleaner — корректная очистка кэша шейдеров NVIDIA на Windows 10/11.

.DESCRIPTION
    Программа выполняет полный цикл очистки шейдер-кэша:
      1) Через NVIDIA Profile Inspector выставляет "Shader Cache Size" = Disabled
      2) Перезагружает ПК (авто, через 5 сек, с возможностью отмены)
      3) После перезагрузки автоматически продолжается (Task Scheduler):
         - Закрывает фоновые процессы NVIDIA (с подтверждением пользователя)
         - Удаляет %LOCALAPPDATA%\NVIDIA\DXCache и GLCache
         - Удаляет содержимое <Steam>\steamapps\shadercache\730
      4) Возвращает "Shader Cache Size" = Unlimited
      5) Перезагружает ПК ещё раз
      6) Выводит красивое окно с сообщением об успехе

    Состояние хранится в %LOCALAPPDATA%\NvShaderCleaner\state.json,
    лог пишется в %LOCALAPPDATA%\NvShaderCleaner\log.txt.

    Скрипт рассчитан на сборку в .exe через ps2exe (см. Build-Exe.ps1).
#>

[CmdletBinding()]
param(
    [switch]$Elevated
)

# ============================================================================
#                                КОНСТАНТЫ
# ============================================================================

$Script:AppName       = 'NvShaderCleaner'
$Script:AppDataDir    = Join-Path $env:LOCALAPPDATA $Script:AppName
$Script:StateFile     = Join-Path $Script:AppDataDir 'state.json'
$Script:LogFile       = Join-Path $Script:AppDataDir 'log.txt'
$Script:TaskName      = 'NvShaderCleaner_Resume'

# Стабильная версия NVIDIA Profile Inspector (релизы Orbmu2k/nvidiaProfileInspector)
$Script:NpiVersion    = '2.4.0.4'
$Script:NpiUrl        = "https://github.com/Orbmu2k/nvidiaProfileInspector/releases/download/$Script:NpiVersion/nvidiaProfileInspector.zip"
$Script:NpiExeName    = 'nvidiaProfileInspector.exe'

# Setting ID для "Shader Cache Size" в NVIDIA Profile Inspector
# Значения:
#   0x00000000 — Disabled
#   0xFFFFFFFF — Unlimited
$Script:ShaderCacheSettingId = '0x00E1C92E'
$Script:ShaderCache_Disabled  = '0x00000000'
$Script:ShaderCache_Unlimited = '0xFFFFFFFF'

# Шаги state machine
$Script:STEP_INIT             = 'INIT'
$Script:STEP_AFTER_REBOOT_1   = 'AFTER_REBOOT_1'
$Script:STEP_AFTER_REBOOT_2   = 'AFTER_REBOOT_2'
$Script:STEP_DONE             = 'DONE'

# Процессы NVIDIA, которые могут блокировать удаление DXCache/GLCache
# (по согласованию с пользователем — закрываем ВСЕ, включая Control Panel UI)
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
#                            ОБЩИЕ ВСПОМОГАТЕЛЬНЫЕ
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
    # Дублируем в консоль, если она есть (полезно при отладке)
    try { Write-Host $line } catch { }
}

function Get-AppDir {
    # Каталог, где лежит запущенный .exe (или .ps1)
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
    # Перезапускает текущий .exe с правами администратора
    $exe = Get-SelfExePath
    if (-not $exe) {
        Show-ErrorBox 'Не удалось определить путь к собственному исполняемому файлу для повышения прав.'
        exit 1
    }
    try {
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList '-Elevated' | Out-Null
    } catch {
        Show-ErrorBox "Запуск с правами администратора отменён или не удался: $($_.Exception.Message)"
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
            Step      = $Script:STEP_INIT
            StartedAt = (Get-Date).ToString('o')
            NpiPath   = $null
            SteamPath = $null
        }
    }
    try {
        return Get-Content -Path $Script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log "Не удалось прочитать state.json, начинаю заново: $($_.Exception.Message)" 'WARN'
        return [pscustomobject]@{
            Step      = $Script:STEP_INIT
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
#                         WPF / WINFORMS UI (русский)
# ============================================================================

function Initialize-UI {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing | Out-Null
}

function Show-InfoBox {
    param([Parameter(Mandatory)][string]$Message, [string]$Title = 'NvShaderCleaner')
    Initialize-UI
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Information') | Out-Null
}

function Show-ErrorBox {
    param([Parameter(Mandatory)][string]$Message, [string]$Title = 'NvShaderCleaner — ошибка')
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
    <#
        Красивое модальное окно WPF: "Перезагрузка через N сек, [Отмена]".
        Возвращает $true — пользователь подтвердил/таймер истёк, перезагружать.
                  $false — пользователь нажал Отмена.
    #>
    param([int]$Seconds = 5, [string]$Reason = 'Для применения изменений требуется перезагрузка')
    Initialize-UI

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NvShaderCleaner — Перезагрузка"
        Height="220" Width="460"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        WindowStyle="None"
        Background="#1E1E2E"
        AllowsTransparency="True"
        Opacity="0.98">
    <Border BorderBrush="#76B900" BorderThickness="2" CornerRadius="8">
        <Grid Margin="20">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="Перезагрузка компьютера" FontSize="20" FontWeight="Bold" Foreground="#76B900" HorizontalAlignment="Center"/>
            <TextBlock Grid.Row="1" x:Name="ReasonText" Text="" FontSize="13" Foreground="#CDD6F4" TextWrapping="Wrap" HorizontalAlignment="Center" Margin="0,10,0,0"/>
            <TextBlock Grid.Row="2" x:Name="CountdownText" Text="" FontSize="32" FontWeight="Bold" Foreground="#F9E2AF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            <Button Grid.Row="3" x:Name="CancelBtn" Content="Отмена (перезагрузить позже вручную)" Height="34" Background="#45475A" Foreground="#CDD6F4" BorderBrush="#585B70" FontSize="12"/>
        </Grid>
    </Border>
</Window>
"@

    $reader  = New-Object System.Xml.XmlNodeReader $xaml
    $window  = [Windows.Markup.XamlReader]::Load($reader)
    $reason  = $window.FindName('ReasonText')
    $count   = $window.FindName('CountdownText')
    $btn     = $window.FindName('CancelBtn')
    $reason.Text = $Reason

    $script:_rebootCancelled = $false
    $script:_secondsLeft     = $Seconds
    $count.Text = "$Seconds сек."

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $timer.Add_Tick({
        $script:_secondsLeft--
        if ($script:_secondsLeft -le 0) {
            $timer.Stop()
            $window.Close()
        } else {
            $count.Text = "$script:_secondsLeft сек."
        }
    })

    $btn.Add_Click({
        $script:_rebootCancelled = $true
        $timer.Stop()
        $window.Close()
    })

    $timer.Start()
    $window.ShowDialog() | Out-Null
    return (-not $script:_rebootCancelled)
}

function Show-FinalSuccessWindow {
    <#
        Красивое финальное окно: "Кэш шейдеров успешно очищен".
    #>
    Initialize-UI

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NvShaderCleaner — Готово"
        Height="320" Width="520"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        WindowStyle="None"
        Background="#1E1E2E"
        AllowsTransparency="True"
        Opacity="0.98">
    <Border BorderBrush="#76B900" BorderThickness="2" CornerRadius="10">
        <Grid Margin="24">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" Text="✓" FontSize="64" FontWeight="Bold" Foreground="#A6E3A1" HorizontalAlignment="Center"/>

            <TextBlock Grid.Row="1" Text="Готово!" FontSize="26" FontWeight="Bold" Foreground="#A6E3A1" HorizontalAlignment="Center" Margin="0,4,0,0"/>

            <TextBlock Grid.Row="2" Text="Кэш шейдеров NVIDIA был успешно очищен."
                       FontSize="14" Foreground="#CDD6F4" HorizontalAlignment="Center" Margin="0,12,0,0" TextWrapping="Wrap" TextAlignment="Center"/>

            <TextBlock Grid.Row="3" x:Name="DetailsText"
                       FontSize="11" Foreground="#A6ADC8" HorizontalAlignment="Center"
                       Margin="0,16,0,0" TextWrapping="Wrap" TextAlignment="Center"/>

            <Button Grid.Row="4" x:Name="OkBtn" Content="Закрыть" Height="38" Width="160"
                    HorizontalAlignment="Center" Margin="0,16,0,0"
                    Background="#76B900" Foreground="White" BorderBrush="#76B900" FontSize="13" FontWeight="Bold"/>
        </Grid>
    </Border>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $details = $window.FindName('DetailsText')
    $okBtn   = $window.FindName('OkBtn')
    $details.Text = "Размер кэша шейдеров возвращён в значение «Без ограничений».`r`nПри следующем запуске игр шейдеры будут перекомпилированы заново."
    $okBtn.Add_Click({ $window.Close() })
    $window.ShowDialog() | Out-Null
}

# ============================================================================
#                        NVIDIA PROFILE INSPECTOR
# ============================================================================

function Get-NpiPath {
    $toolsDir = Join-Path (Get-AppDir) 'tools'
    return (Join-Path $toolsDir $Script:NpiExeName)
}

function Ensure-NpiInstalled {
    <#
        Проверяет наличие nvidiaProfileInspector.exe в .\tools\.
        Если нет — пытается скачать с GitHub. Если интернета нет —
        просит пользователя положить файл вручную и завершает работу.
    #>
    $toolsDir = Join-Path (Get-AppDir) 'tools'
    $npiExe   = Join-Path $toolsDir $Script:NpiExeName

    if (Test-Path $npiExe) {
        Write-Log "NVIDIA Profile Inspector уже установлен: $npiExe" 'INFO'
        return $npiExe
    }

    Write-Log "NVIDIA Profile Inspector не найден, пытаюсь скачать с GitHub..." 'INFO'

    if (-not (Test-Path $toolsDir)) {
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    }

    $zipPath = Join-Path $toolsDir 'nvidiaProfileInspector.zip'

    # Проверка интернета
    $hasInternet = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect('github.com', 443, $null, $null)
        $ok  = $iar.AsyncWaitHandle.WaitOne(3000, $false)
        if ($ok -and $tcp.Connected) { $hasInternet = $true }
        $tcp.Close()
    } catch { $hasInternet = $false }

    if (-not $hasInternet) {
        Show-ErrorBox @"
Не удалось подключиться к интернету для загрузки NVIDIA Profile Inspector.

Пожалуйста, скачайте архив вручную:
$($Script:NpiUrl)

или любую версию с https://github.com/Orbmu2k/nvidiaProfileInspector/releases

Распакуйте $($Script:NpiExeName) в папку:
$toolsDir

И запустите программу заново.
"@
        exit 1
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 -bor [Net.SecurityProtocolType]::Tls11
    } catch {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    }

    try {
        Write-Log "Скачиваю $($Script:NpiUrl) ..." 'INFO'
        Invoke-WebRequest -Uri $Script:NpiUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
    } catch {
        Show-ErrorBox @"
Не удалось скачать NVIDIA Profile Inspector с GitHub.
Ошибка: $($_.Exception.Message)

Скачайте архив вручную с
$($Script:NpiUrl)
и распакуйте $($Script:NpiExeName) в:
$toolsDir
"@
        exit 1
    }

    try {
        Expand-Archive -Path $zipPath -DestinationPath $toolsDir -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    } catch {
        Show-ErrorBox "Не удалось распаковать архив NVIDIA Profile Inspector: $($_.Exception.Message)"
        exit 1
    }

    if (-not (Test-Path $npiExe)) {
        # На случай, если внутри архива другой регистр / папка
        $found = Get-ChildItem -Path $toolsDir -Filter $Script:NpiExeName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            Move-Item -Path $found.FullName -Destination $npiExe -Force
        }
    }

    if (-not (Test-Path $npiExe)) {
        Show-ErrorBox "После распаковки не удалось найти $($Script:NpiExeName) в $toolsDir."
        exit 1
    }

    Write-Log "NVIDIA Profile Inspector установлен: $npiExe" 'OK'
    return $npiExe
}

function Set-ShaderCacheSize {
    param(
        [Parameter(Mandatory)] [ValidateSet('Disabled','Unlimited')] [string] $Mode,
        [Parameter(Mandatory)] [string] $NpiPath
    )
    $value = if ($Mode -eq 'Disabled') { $Script:ShaderCache_Disabled } else { $Script:ShaderCache_Unlimited }
    Write-Log "Применяю Shader Cache Size = $Mode ($value) через $NpiPath" 'INFO'

    try {
        $proc = Start-Process -FilePath $NpiPath `
            -ArgumentList @('-setProfileSetting', '"Base Profile"', $Script:ShaderCacheSettingId, $value) `
            -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop
        if ($proc.ExitCode -ne 0) {
            throw "nvidiaProfileInspector вернул код $($proc.ExitCode)"
        }
        Write-Log "Shader Cache Size = $Mode применён успешно." 'OK'
    } catch {
        Show-ErrorBox @"
Не удалось изменить параметр «Размер кэша шейдеров» через NVIDIA Profile Inspector.

Ошибка: $($_.Exception.Message)

Проверьте, что NVIDIA Profile Inspector присутствует в:
$NpiPath
и что у вас установлены актуальные драйверы NVIDIA.
"@
        throw
    }
}

# ============================================================================
#                          ПРОЦЕССЫ NVIDIA
# ============================================================================

function Get-RunningNvidiaProcesses {
    $list = @()
    foreach ($name in $Script:NvidiaProcessNames) {
        $p = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($p) { $list += $p }
    }
    # Дополнительно — что-нибудь с "nvidia" в имени, чтобы не пропустить новые компоненты
    $extra = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match '^(?i)(nv|nvidia)' -and ($list.Id -notcontains $_.Id)
    }
    if ($extra) { $list += $extra }
    return $list
}

function Stop-NvidiaProcessesWithConsent {
    <#
        Если есть запущенные процессы NVIDIA — спрашивает у пользователя
        подтверждение и закрывает их. Возвращает $true, если всё ок (или
        процессов не было), $false — если пользователь отказался.
    #>
    $procs = Get-RunningNvidiaProcesses
    if (-not $procs -or $procs.Count -eq 0) {
        Write-Log "Запущенных процессов NVIDIA не обнаружено." 'INFO'
        return $true
    }

    $names = ($procs | Select-Object -ExpandProperty ProcessName -Unique) -join "`r`n  • "
    $msg = @"
Обнаружены запущенные процессы NVIDIA, которые могут помешать удалению кэша:

  • $names

Чтобы продолжить очистку, их необходимо закрыть.
Закрыть эти процессы сейчас?
"@
    if (-not (Show-YesNoBox -Message $msg -Title 'Закрыть процессы NVIDIA?')) {
        Write-Log "Пользователь отказался закрывать процессы NVIDIA." 'WARN'
        return $false
    }

    foreach ($p in $procs) {
        try {
            Write-Log "Завершаю процесс $($p.ProcessName) (PID $($p.Id))..." 'INFO'
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
        } catch {
            Write-Log "Не удалось завершить $($p.ProcessName): $($_.Exception.Message)" 'WARN'
        }
    }
    Start-Sleep -Seconds 2
    return $true
}

# ============================================================================
#                       УДАЛЕНИЕ ПАПОК КЭША
# ============================================================================

function Remove-NvidiaCacheFolders {
    $base    = Join-Path $env:LOCALAPPDATA 'NVIDIA'
    $targets = @('DXCache', 'GLCache')
    $removed = @()
    $errors  = @()

    if (-not (Test-Path $base)) {
        Write-Log "Папка $base не найдена — нечего удалять." 'INFO'
        return @{ Removed = $removed; Errors = $errors }
    }

    foreach ($name in $targets) {
        $path = Join-Path $base $name
        if (-not (Test-Path $path)) {
            Write-Log "Папка $path отсутствует — пропускаю." 'INFO'
            continue
        }
        try {
            Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            Write-Log "Удалена $path" 'OK'
            $removed += $path
        } catch {
            Write-Log "Ошибка при удалении $path : $($_.Exception.Message)" 'ERROR'
            $errors += "$path : $($_.Exception.Message)"
        }
    }
    return @{ Removed = $removed; Errors = $errors }
}

function Find-SteamPath {
    <#
        Ищет путь к установке Steam через реестр.
        Возможные ключи:
          HKCU:\Software\Valve\Steam  -> SteamPath
          HKLM:\SOFTWARE\WOW6432Node\Valve\Steam -> InstallPath
          HKLM:\SOFTWARE\Valve\Steam -> InstallPath
    #>
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
    <#
        Возвращает все пути библиотек Steam: основная + дополнительные
        из libraryfolders.vdf.
    #>
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
    <#
        Удаляет содержимое <Library>\steamapps\shadercache\730 во всех
        обнаруженных библиотеках Steam. Возвращает hashtable с результатами.
    #>
    $libs = Get-AllSteamLibraries
    $cleared = @()
    $missing = @()
    $errors  = @()

    if (-not $libs -or $libs.Count -eq 0) {
        Write-Log "Steam не обнаружен в реестре." 'WARN'
        return @{ Cleared = $cleared; Missing = $missing; Errors = $errors; SteamFound = $false }
    }

    foreach ($lib in $libs) {
        $path = Join-Path $lib 'steamapps\shadercache\730'
        if (-not (Test-Path $path)) {
            Write-Log "Путь $path не существует — пропускаю." 'INFO'
            $missing += $path
            continue
        }
        try {
            Get-ChildItem -Path $path -Force -ErrorAction Stop | ForEach-Object {
                Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction Stop
            }
            Write-Log "Содержимое $path удалено." 'OK'
            $cleared += $path
        } catch {
            Write-Log "Ошибка при очистке $path : $($_.Exception.Message)" 'ERROR'
            $errors += "$path : $($_.Exception.Message)"
        }
    }

    return @{ Cleared = $cleared; Missing = $missing; Errors = $errors; SteamFound = $true }
}

# ============================================================================
#                         TASK SCHEDULER (RESUME)
# ============================================================================

function Register-ResumeTask {
    <#
        Создаёт одноразовую запланированную задачу AtLogon, которая через
        1 минуту после входа пользователя в систему запустит наш .exe снова
        с правами администратора. Задача удаляется самим скриптом в конце.
    #>
    $exe = Get-SelfExePath
    if (-not $exe) {
        Show-ErrorBox 'Не удалось определить путь к .exe для создания задачи возобновления.'
        throw 'self exe not found'
    }

    # Сначала удаляем, если уже существует
    Unregister-ResumeTask

    $user = "$env:USERDOMAIN\$env:USERNAME"
    Write-Log "Регистрирую запланированную задачу '$Script:TaskName' для пользователя $user → $exe" 'INFO'

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
            Write-Log "Запланированная задача '$Script:TaskName' удалена." 'INFO'
        }
    } catch {
        Write-Log "Не удалось удалить задачу '$Script:TaskName': $($_.Exception.Message)" 'WARN'
    }
}

# ============================================================================
#                              ПЕРЕЗАГРУЗКА
# ============================================================================

function Invoke-RebootOrAbort {
    <#
        Показывает окно обратного отсчёта, затем (если не отменено) выполняет
        shutdown /r /t 5. При отмене — выводит инструкцию и завершает работу,
        ожидая ручной перезагрузки (запланированная задача всё равно запустит
        скрипт после входа пользователя).
    #>
    param([string]$Reason = 'Для применения изменений требуется перезагрузка ПК.')

    $doReboot = Show-RebootCountdown -Seconds 5 -Reason $Reason
    if ($doReboot) {
        Write-Log "Запускаю перезагрузку (shutdown /r /t 5)." 'INFO'
        & shutdown.exe /r /t 5 /c "NvShaderCleaner: перезагрузка для применения настроек кэша шейдеров."
    } else {
        Write-Log "Пользователь отменил автоматическую перезагрузку." 'WARN'
        Show-InfoBox @"
Автоматическая перезагрузка отменена.

Пожалуйста, перезагрузите компьютер вручную, когда будете готовы.
Программа автоматически продолжит работу после следующего входа в систему.
"@ 'Перезагрузка отложена'
    }
    exit 0
}

# ============================================================================
#                                ШАГИ
# ============================================================================

function Invoke-Step-Init {
    Write-Log '=== ШАГ 1: настройка Shader Cache Size = Disabled ===' 'INFO'

    $npi = Ensure-NpiInstalled
    try {
        Set-ShaderCacheSize -Mode Disabled -NpiPath $npi
    } catch {
        # Ошибка уже показана. Не сохраняем состояние, чтобы при перезапуске начали заново.
        exit 1
    }

    # Создаём задачу на возобновление и сохраняем состояние
    try {
        Register-ResumeTask
    } catch {
        Show-ErrorBox "Не удалось зарегистрировать задачу возобновления после перезагрузки: $($_.Exception.Message)"
        exit 1
    }

    $state = Get-State
    $state.Step    = $Script:STEP_AFTER_REBOOT_1
    $state.NpiPath = $npi
    Save-State $state

    Invoke-RebootOrAbort -Reason 'Кэш шейдеров отключён. Сейчас компьютер перезагрузится, а после входа очистка продолжится автоматически.'
}

function Invoke-Step-AfterReboot1 {
    Write-Log '=== ШАГ 2: очистка папок кэша шейдеров ===' 'INFO'

    # Закрываем NVIDIA процессы (с подтверждением)
    if (-not (Stop-NvidiaProcessesWithConsent)) {
        Show-WarnBox @"
Очистка не может быть продолжена, пока запущены процессы NVIDIA.

Закройте их вручную через Диспетчер задач и запустите программу заново
(запланированная задача автоматически удалится при повторном запуске).
"@ 'Очистка прервана'
        # Оставляем state как есть — пользователь сможет вернуться
        exit 0
    }

    $nvResult    = Remove-NvidiaCacheFolders
    $steamResult = Remove-SteamShaderCache730

    # Восстанавливаем Shader Cache Size = Unlimited
    $npi = (Get-State).NpiPath
    if (-not $npi -or -not (Test-Path $npi)) {
        $npi = Ensure-NpiInstalled
    }
    try {
        Set-ShaderCacheSize -Mode Unlimited -NpiPath $npi
    } catch {
        exit 1
    }

    # Сводное уведомление, если были ошибки или Steam не найден
    $warnings = @()
    if (-not $steamResult.SteamFound) {
        $warnings += 'Steam не обнаружен в системе — папка shadercache\730 пропущена.'
    } elseif ($steamResult.Cleared.Count -eq 0 -and $steamResult.Missing.Count -gt 0) {
        $warnings += "Папка shadercache\730 не найдена ни в одной библиотеке Steam — пропущена.`r`nПроверены: $($steamResult.Missing -join '; ')"
    }
    if ($nvResult.Errors.Count -gt 0) {
        $warnings += "Ошибки при удалении папок NVIDIA:`r`n  " + ($nvResult.Errors -join "`r`n  ")
    }
    if ($steamResult.Errors.Count -gt 0) {
        $warnings += "Ошибки при очистке Steam:`r`n  " + ($steamResult.Errors -join "`r`n  ")
    }
    if ($warnings.Count -gt 0) {
        Show-WarnBox (($warnings -join "`r`n`r`n")) 'NvShaderCleaner — внимание'
    }

    # Готовимся ко второй перезагрузке
    $state = Get-State
    $state.Step = $Script:STEP_AFTER_REBOOT_2
    Save-State $state

    try {
        Register-ResumeTask
    } catch {
        Show-ErrorBox "Не удалось зарегистрировать задачу финального запуска: $($_.Exception.Message)"
        exit 1
    }

    Invoke-RebootOrAbort -Reason 'Очистка завершена. Перезагрузим компьютер ещё раз для применения настроек, после чего покажем итоговое окно.'
}

function Invoke-Step-AfterReboot2 {
    Write-Log '=== ШАГ 3: финальное окно ===' 'INFO'

    Unregister-ResumeTask

    Show-FinalSuccessWindow

    Clear-State
    Write-Log '=== Готово. State очищен. ===' 'OK'
}

# ============================================================================
#                                MAIN
# ============================================================================

function Main {
    # Каталог состояния создаём до всего остального
    Initialize-AppFolder

    Write-Log '----- NvShaderCleaner запущен -----' 'INFO'

    # Если не админ — повышаем права
    if (-not (Test-Administrator)) {
        Write-Log 'Прав администратора нет, запрашиваю UAC...' 'INFO'
        Invoke-SelfElevate
        return  # Invoke-SelfElevate сама делает exit
    }

    $state = Get-State
    Write-Log "Текущий шаг: $($state.Step)" 'INFO'

    try {
        switch ($state.Step) {
            'INIT'           { Invoke-Step-Init }
            'AFTER_REBOOT_1' { Invoke-Step-AfterReboot1 }
            'AFTER_REBOOT_2' { Invoke-Step-AfterReboot2 }
            'DONE'           { Clear-State; Invoke-Step-Init }
            default          { Clear-State; Invoke-Step-Init }
        }
    } catch {
        Show-ErrorBox "Произошла непредвиденная ошибка на шаге $($state.Step):`r`n`r`n$($_.Exception.Message)`r`n`r`nПодробности см. в логе:`r`n$Script:LogFile"
        Write-Log "FATAL: $($_.Exception.Message)`r`n$($_.ScriptStackTrace)" 'ERROR'
        exit 1
    }
}

Main
