<#
.SYNOPSIS
    NvShaderCleaner by melya - clean NVIDIA shader cache on Windows 10/11.

.DESCRIPTION
    Single-window WPF application that walks the user through a 3-step
    NVIDIA shader cache cleanup (set cache size = Disabled, reboot, clean
    folders, set cache size = Unlimited, reboot, done). The .exe is fully
    portable: it stores state.json / log.txt / tools / in
    %LOCALAPPDATA%\NvShaderCleaner, so the single .exe can be copied
    anywhere and just work.

    Threading model: everything runs on the STA/UI thread. Long operations
    use Update-UI (DispatcherFrame.PushFrame) to pump the message loop and
    keep the window responsive. User prompts use nested PushFrame loops.
    This avoids BackgroundWorker which is incompatible with ps2exe.
#>

[CmdletBinding()]
param(
    [switch]$Elevated
)

# ============================================================================
#                                CONSTANTS
# ============================================================================

$Script:AppName       = 'NvShaderCleaner'
$Script:AppAuthor     = 'melya'
$Script:AppVersion    = '1.2.0'

$Script:AppDataDir    = Join-Path $env:LOCALAPPDATA $Script:AppName
$Script:StateFile     = Join-Path $Script:AppDataDir 'state.json'
$Script:LogFile       = Join-Path $Script:AppDataDir 'log.txt'
$Script:ToolsDir      = Join-Path $Script:AppDataDir 'tools'
$Script:TaskName      = 'NvShaderCleaner_Resume'

$Script:NpiVersion    = '2.4.0.4'
$Script:NpiUrl        = "https://github.com/Orbmu2k/nvidiaProfileInspector/releases/download/$($Script:NpiVersion)/nvidiaProfileInspector.zip"
$Script:NpiExeName    = 'nvidiaProfileInspector.exe'

$Script:ShaderCacheSizeSettingId    = '11306135'
$Script:ShaderCacheSizeSettingName  = 'Shader disk cache maximum size'
$Script:ShaderCacheSize_Disabled    = '0'
$Script:ShaderCacheSize_Unlimited   = '4294967295'

# Nvidia-inspired green palette
$Script:Color_Bg          = '#0B0F0B'
$Script:Color_Surface     = '#121A12'
$Script:Color_SurfaceAlt  = '#172217'
$Script:Color_Border      = '#1F3A1F'
$Script:Color_NvGreen     = '#76B900'
$Script:Color_NvGreenSoft = '#9CDB2A'
$Script:Color_TextMain    = '#E6F2D8'
$Script:Color_TextDim     = '#9DBA7D'
$Script:Color_TextMuted   = '#6E8C5A'
$Script:Color_Warn        = '#F9E2AF'
$Script:Color_Error       = '#F38BA8'
$Script:Color_Ok          = '#A6E3A1'

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

# Shared UI state
$Script:UI     = $null
$Script:Prompt = @{ Frame = $null; Answer = $null }

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
    $ts   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Message"
    try { Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 } catch { }
    Add-UILog -Message $Message -Level $Level -Timestamp $ts
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
        [System.Windows.MessageBox]::Show(
            'Не удалось определить путь к .exe для повышения прав.',
            $Script:AppName, 'OK', 'Error') | Out-Null
        exit 1
    }
    try {
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList '-Elevated' | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show(
            "Запуск с правами администратора отменён: $($_.Exception.Message)",
            $Script:AppName, 'OK', 'Error') | Out-Null
        exit 1
    }
    exit 0
}

# ============================================================================
#                              STATE MACHINE
# ============================================================================

function New-DefaultState {
    return [pscustomobject]@{
        Step      = 'INIT'
        StartedAt = (Get-Date).ToString('o')
        NpiPath   = $null
        SteamPath = $null
    }
}

function Get-State {
    if (-not (Test-Path $Script:StateFile)) { return New-DefaultState }
    try {
        return Get-Content -Path $Script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log "Cannot read state.json, starting over: $($_.Exception.Message)" 'WARN'
        return New-DefaultState
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
#                       UI ASSEMBLIES + MAIN WINDOW
# ============================================================================

function Initialize-UIAssemblies {
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
    Add-Type -AssemblyName WindowsBase -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
}

function New-Brush { param([string]$Hex) if (-not $Hex) { return $null }; [System.Windows.Media.BrushConverter]::new().ConvertFrom($Hex) }
function New-Thickness { param([double]$T=0,[double]$R=-1,[double]$B=0,[double]$L=0)
    if ($R -eq -1) { return [System.Windows.Thickness]::new($T) }
    return [System.Windows.Thickness]::new($L,$T,$R,$B)
}

function Build-MainWindow {
    $w = New-Object System.Windows.Window
    $w.Title = "$($Script:AppName) by $($Script:AppAuthor)"
    $w.Width = 700; $w.Height = 500
    $w.MinWidth = 700; $w.MinHeight = 500
    $w.WindowStartupLocation = 'CenterScreen'
    $w.ResizeMode = 'NoResize'
    $w.WindowStyle = 'None'
    $w.AllowsTransparency = $true
    $w.Background = New-Brush $Script:Color_Bg
    $w.ShowInTaskbar = $true
    $w.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI Variable Display, Segoe UI, Calibri'

    $outer = New-Object System.Windows.Controls.Border
    $outer.BorderBrush     = New-Brush $Script:Color_NvGreen
    $outer.BorderThickness = New-Thickness 2
    $outer.CornerRadius    = [System.Windows.CornerRadius]::new(10)
    $outer.Background      = New-Brush $Script:Color_Bg

    $root = New-Object System.Windows.Controls.Grid
    $root.Margin = New-Thickness -T 0
    foreach ($h in @('Auto','Auto','Auto','Auto','*','Auto','Auto')) {
        $rd = New-Object System.Windows.Controls.RowDefinition
        $rd.Height = $h
        $root.RowDefinitions.Add($rd) | Out-Null
    }

    # ---------- HEADER ----------
    $headerGrid = New-Object System.Windows.Controls.Grid
    $headerGrid.Margin = New-Thickness -T 18 -R 22 -B 4 -L 22
    $hc0 = New-Object System.Windows.Controls.ColumnDefinition; $hc0.Width = '*'
    $hc1 = New-Object System.Windows.Controls.ColumnDefinition; $hc1.Width = 'Auto'
    $headerGrid.ColumnDefinitions.Add($hc0) | Out-Null
    $headerGrid.ColumnDefinitions.Add($hc1) | Out-Null

    $titleStack = New-Object System.Windows.Controls.StackPanel
    $titleStack.Orientation = 'Vertical'

    $titleTb = New-Object System.Windows.Controls.TextBlock
    $titleTb.Text = $Script:AppName; $titleTb.FontSize = 26
    $titleTb.FontWeight = 'Bold'; $titleTb.Foreground = New-Brush $Script:Color_NvGreen
    $titleStack.Children.Add($titleTb) | Out-Null

    $subTb = New-Object System.Windows.Controls.TextBlock
    $subTb.Text = "NVIDIA shader cache cleaner  ·  by $($Script:AppAuthor)"
    $subTb.FontSize = 12; $subTb.Foreground = New-Brush $Script:Color_TextDim
    $subTb.Margin = New-Thickness -T 2 -R 0
    $titleStack.Children.Add($subTb) | Out-Null

    [System.Windows.Controls.Grid]::SetColumn($titleStack, 0)
    $headerGrid.Children.Add($titleStack) | Out-Null

    $winBtnStack = New-Object System.Windows.Controls.StackPanel
    $winBtnStack.Orientation = 'Horizontal'
    $winBtnStack.VerticalAlignment = 'Top'; $winBtnStack.HorizontalAlignment = 'Right'

    $minBtn = New-Object System.Windows.Controls.Button
    $minBtn.Content = [char]0x2014; $minBtn.Width = 34; $minBtn.Height = 28
    $minBtn.FontSize = 14
    $minBtn.Background = New-Brush $Script:Color_SurfaceAlt
    $minBtn.Foreground = New-Brush $Script:Color_TextDim
    $minBtn.BorderBrush = New-Brush $Script:Color_Border
    $minBtn.Cursor = 'Hand'; $minBtn.Margin = New-Thickness -T 0 -R 4 -B 0 -L 0
    $minBtn.Add_Click({ try { $Script:UI.Window.WindowState = 'Minimized' } catch { } })
    $winBtnStack.Children.Add($minBtn) | Out-Null

    $closeBtn = New-Object System.Windows.Controls.Button
    $closeBtn.Content = [char]0x2715; $closeBtn.Width = 34; $closeBtn.Height = 28
    $closeBtn.FontSize = 14
    $closeBtn.Background = New-Brush $Script:Color_SurfaceAlt
    $closeBtn.Foreground = New-Brush $Script:Color_TextDim
    $closeBtn.BorderBrush = New-Brush $Script:Color_Border
    $closeBtn.Cursor = 'Hand'
    $closeBtn.Add_Click({ try { $Script:UI.Window.Close() } catch { } })
    $winBtnStack.Children.Add($closeBtn) | Out-Null

    [System.Windows.Controls.Grid]::SetColumn($winBtnStack, 1)
    $headerGrid.Children.Add($winBtnStack) | Out-Null

    [System.Windows.Controls.Grid]::SetRow($headerGrid, 0)
    $root.Children.Add($headerGrid) | Out-Null

    # DragMove is registered in Main after $Script:UI is assigned,
    # because ps2exe may not capture local $w in event closures.

    # ---------- STEPS ROW ----------
    $stepsBorder = New-Object System.Windows.Controls.Border
    $stepsBorder.Margin = New-Thickness -T 8 -R 22 -B 6 -L 22
    $stepsBorder.Background = New-Brush $Script:Color_Surface
    $stepsBorder.BorderBrush = New-Brush $Script:Color_Border
    $stepsBorder.BorderThickness = New-Thickness 1
    $stepsBorder.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $stepsBorder.Padding = New-Thickness -T 10 -R 12 -B 10 -L 12

    $stepsGrid = New-Object System.Windows.Controls.Grid
    for ($i = 0; $i -lt 3; $i++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = '*'
        $stepsGrid.ColumnDefinitions.Add($cd) | Out-Null
    }

    $stepTitles = @(
        '1. Отключить Shader Cache',
        '2. Очистить папки кэша',
        '3. Вернуть Unlimited и завершить'
    )
    $stepTexts = @()
    for ($i = 0; $i -lt 3; $i++) {
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Vertical'
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $stepTitles[$i]; $tb.FontSize = 12
        $tb.FontWeight = 'SemiBold'; $tb.Foreground = New-Brush $Script:Color_TextDim
        $tb.TextWrapping = 'Wrap'
        $sp.Children.Add($tb) | Out-Null
        $sub = New-Object System.Windows.Controls.TextBlock
        $sub.Text = [char]0x23F3 + ' ожидание'; $sub.FontSize = 10
        $sub.Foreground = New-Brush $Script:Color_TextMuted
        $sub.Margin = New-Thickness -T 2 -R 0
        $sp.Children.Add($sub) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($sp, $i)
        $stepsGrid.Children.Add($sp) | Out-Null
        $stepTexts += ,@($tb, $sub)
    }
    $stepsBorder.Child = $stepsGrid
    [System.Windows.Controls.Grid]::SetRow($stepsBorder, 1)
    $root.Children.Add($stepsBorder) | Out-Null

    # ---------- PROGRESS BAR ----------
    $progressBorder = New-Object System.Windows.Controls.Border
    $progressBorder.Margin = New-Thickness -T 4 -R 22 -B 4 -L 22
    $progressBorder.Background = New-Brush $Script:Color_Surface
    $progressBorder.BorderBrush = New-Brush $Script:Color_Border
    $progressBorder.BorderThickness = New-Thickness 1
    $progressBorder.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $progressBorder.Height = 14

    $progressInner = New-Object System.Windows.Controls.Border
    $progressInner.HorizontalAlignment = 'Left'
    $progressInner.Background = New-Brush $Script:Color_NvGreen
    $progressInner.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $progressInner.Width = 0
    $progressBorder.Child = $progressInner

    [System.Windows.Controls.Grid]::SetRow($progressBorder, 2)
    $root.Children.Add($progressBorder) | Out-Null

    # ---------- STATUS LINE ----------
    $statusTb = New-Object System.Windows.Controls.TextBlock
    $statusTb.Text = 'Готов к запуску...'; $statusTb.FontSize = 12
    $statusTb.Foreground = New-Brush $Script:Color_TextMain
    $statusTb.Margin = New-Thickness -T 6 -R 22 -B 6 -L 22
    [System.Windows.Controls.Grid]::SetRow($statusTb, 3)
    $root.Children.Add($statusTb) | Out-Null

    # ---------- LOG VIEW ----------
    $logBorder = New-Object System.Windows.Controls.Border
    $logBorder.Margin = New-Thickness -T 0 -R 22 -B 6 -L 22
    $logBorder.Background = New-Brush $Script:Color_Surface
    $logBorder.BorderBrush = New-Brush $Script:Color_Border
    $logBorder.BorderThickness = New-Thickness 1
    $logBorder.CornerRadius = [System.Windows.CornerRadius]::new(8)

    $logScroll = New-Object System.Windows.Controls.ScrollViewer
    $logScroll.VerticalScrollBarVisibility = 'Auto'
    $logScroll.HorizontalScrollBarVisibility = 'Disabled'
    $logScroll.Padding = New-Thickness -T 8 -R 10 -B 8 -L 10

    $logPanel = New-Object System.Windows.Controls.StackPanel
    $logPanel.Orientation = 'Vertical'
    $logScroll.Content = $logPanel
    $logBorder.Child = $logScroll

    [System.Windows.Controls.Grid]::SetRow($logBorder, 4)
    $root.Children.Add($logBorder) | Out-Null

    # ---------- ACTION PANEL ----------
    $actionBorder = New-Object System.Windows.Controls.Border
    $actionBorder.Margin = New-Thickness -T 0 -R 22 -B 6 -L 22
    $actionBorder.Background = New-Brush $Script:Color_SurfaceAlt
    $actionBorder.BorderBrush = New-Brush $Script:Color_NvGreen
    $actionBorder.BorderThickness = New-Thickness 1
    $actionBorder.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $actionBorder.Padding = New-Thickness -T 10 -R 12 -B 10 -L 12
    $actionBorder.Visibility = 'Collapsed'

    $actionGrid = New-Object System.Windows.Controls.Grid
    $ac0 = New-Object System.Windows.Controls.ColumnDefinition; $ac0.Width = '*'
    $ac1 = New-Object System.Windows.Controls.ColumnDefinition; $ac1.Width = 'Auto'
    $actionGrid.ColumnDefinitions.Add($ac0) | Out-Null
    $actionGrid.ColumnDefinitions.Add($ac1) | Out-Null

    $actionText = New-Object System.Windows.Controls.TextBlock
    $actionText.FontSize = 12; $actionText.Foreground = New-Brush $Script:Color_TextMain
    $actionText.TextWrapping = 'Wrap'; $actionText.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($actionText, 0)
    $actionGrid.Children.Add($actionText) | Out-Null

    $btnStack = New-Object System.Windows.Controls.StackPanel
    $btnStack.Orientation = 'Horizontal'; $btnStack.VerticalAlignment = 'Center'
    $btnStack.Margin = New-Thickness -T 0 -R 0 -B 0 -L 12
    [System.Windows.Controls.Grid]::SetColumn($btnStack, 1)
    $actionGrid.Children.Add($btnStack) | Out-Null

    $yesBtn = New-Object System.Windows.Controls.Button
    $yesBtn.Content = 'Да'; $yesBtn.Width = 100; $yesBtn.Height = 32
    $yesBtn.FontSize = 12; $yesBtn.FontWeight = 'SemiBold'
    $yesBtn.Margin = New-Thickness -T 0 -R 6 -B 0 -L 0
    $yesBtn.Background = New-Brush $Script:Color_NvGreen
    $yesBtn.Foreground = [System.Windows.Media.Brushes]::White
    $yesBtn.BorderBrush = New-Brush $Script:Color_NvGreen; $yesBtn.Cursor = 'Hand'
    $btnStack.Children.Add($yesBtn) | Out-Null

    $noBtn = New-Object System.Windows.Controls.Button
    $noBtn.Content = 'Нет'; $noBtn.Width = 100; $noBtn.Height = 32
    $noBtn.FontSize = 12
    $noBtn.Background = New-Brush $Script:Color_SurfaceAlt
    $noBtn.Foreground = New-Brush $Script:Color_TextMain
    $noBtn.BorderBrush = New-Brush $Script:Color_Border; $noBtn.Cursor = 'Hand'
    $btnStack.Children.Add($noBtn) | Out-Null

    $actionBorder.Child = $actionGrid
    [System.Windows.Controls.Grid]::SetRow($actionBorder, 5)
    $root.Children.Add($actionBorder) | Out-Null

    # ---------- FOOTER ----------
    $footerTb = New-Object System.Windows.Controls.TextBlock
    $footerTb.Text = "v$($Script:AppVersion)  |  $([char]0x00A9) $((Get-Date).Year) $($Script:AppAuthor)  |  state: $($Script:AppDataDir)"
    $footerTb.FontSize = 10; $footerTb.Foreground = New-Brush $Script:Color_TextMuted
    $footerTb.Margin = New-Thickness -T 4 -R 22 -B 14 -L 22
    $footerTb.HorizontalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetRow($footerTb, 6)
    $root.Children.Add($footerTb) | Out-Null

    $outer.Child = $root
    $w.Content = $outer

    return [pscustomobject]@{
        Window        = $w
        StatusText    = $statusTb
        ProgressOuter = $progressBorder
        ProgressInner = $progressInner
        LogPanel      = $logPanel
        LogScroll     = $logScroll
        StepTexts     = $stepTexts
        ActionBorder  = $actionBorder
        ActionText    = $actionText
        BtnStack      = $btnStack
        YesBtn        = $yesBtn
        NoBtn         = $noBtn
    }
}

# ============================================================================
#                          UI UPDATE HELPERS
# ============================================================================

function Update-UI {
    <#
        Pump the WPF dispatcher so the window redraws and processes input.
        Call this between heavy operations to keep the UI responsive.
        IMPORTANT: BeginInvoke returns DispatcherOperation — must suppress
        with $null or it leaks into the caller's output stream and corrupts
        return values (e.g. Ensure-NpiInstalled returning an array instead
        of a string).
    #>
    try {
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $null = [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [System.Action]{ $frame.Continue = $false }
        )
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    } catch { }
}

function Add-UILog {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [string] $Level = 'INFO',
        [string] $Timestamp = $null
    )
    if (-not $Script:UI) { return }
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToString('HH:mm:ss') }
    else {
        try { $Timestamp = ([datetime]$Timestamp).ToString('HH:mm:ss') } catch {
            if ($Timestamp.Length -ge 19) { $Timestamp = $Timestamp.Substring(11,8) }
        }
    }

    $color = switch ($Level) {
        'OK'    { $Script:Color_Ok }
        'WARN'  { $Script:Color_Warn }
        'ERROR' { $Script:Color_Error }
        default { $Script:Color_TextMain }
    }
    $tag = switch ($Level) {
        'OK'    { '[OK]   ' }
        'WARN'  { '[WARN] ' }
        'ERROR' { '[ERR]  ' }
        default { '[INFO] ' }
    }

    try {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.FontFamily = New-Object System.Windows.Media.FontFamily 'Cascadia Mono, Consolas, Segoe UI Mono'
        $tb.FontSize = 11; $tb.TextWrapping = 'Wrap'
        $tb.Margin = New-Thickness -T 1 -R 0
        $tb.Foreground = New-Brush $color
        $tb.Text = "$Timestamp  $tag$Message"
        [void]$Script:UI.LogPanel.Children.Add($tb)
        $Script:UI.LogScroll.ScrollToEnd()
    } catch { }
}

function Set-UIStatus {
    param([Parameter(Mandatory)][string]$Text)
    if (-not $Script:UI) { return }
    try { $Script:UI.StatusText.Text = $Text } catch { }
    Update-UI
}

function Set-UIProgress {
    param([Parameter(Mandatory)][double]$Percent)
    if (-not $Script:UI) { return }
    if ($Percent -lt 0)   { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    try {
        $total = $Script:UI.ProgressOuter.ActualWidth
        if ($total -lt 10) { $total = 654 }
        $Script:UI.ProgressInner.Width = [Math]::Max(0, $total * ($Percent / 100.0))
    } catch { }
    Update-UI
}

function Set-UIStep {
    param(
        [Parameter(Mandatory)][ValidateRange(0,2)][int]$Index,
        [Parameter(Mandatory)][ValidateSet('pending','active','done','error')] [string]$Status,
        [string]$Subtitle = $null
    )
    if (-not $Script:UI) { return }
    try {
        $title = $Script:UI.StepTexts[$Index][0]
        $sub   = $Script:UI.StepTexts[$Index][1]
        switch ($Status) {
            'pending' {
                $title.Foreground = New-Brush $Script:Color_TextDim
                if (-not $Subtitle) { $Subtitle = [char]0x23F3 + ' ожидание' }
                $sub.Foreground = New-Brush $Script:Color_TextMuted
            }
            'active' {
                $title.Foreground = New-Brush $Script:Color_NvGreen
                if (-not $Subtitle) { $Subtitle = [char]0x25B6 + ' выполняется...' }
                $sub.Foreground = New-Brush $Script:Color_NvGreenSoft
            }
            'done' {
                $title.Foreground = New-Brush $Script:Color_Ok
                if (-not $Subtitle) { $Subtitle = [char]0x2714 + ' готово' }
                $sub.Foreground = New-Brush $Script:Color_Ok
            }
            'error' {
                $title.Foreground = New-Brush $Script:Color_Error
                if (-not $Subtitle) { $Subtitle = [char]0x2716 + ' ошибка' }
                $sub.Foreground = New-Brush $Script:Color_Error
            }
        }
        $sub.Text = $Subtitle
    } catch { }
    Update-UI
}

function Wait-WithUI {
    param([int]$Milliseconds)
    $end = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    while ([DateTime]::UtcNow -lt $end) {
        Start-Sleep -Milliseconds 100
        Update-UI
    }
}

# ============================================================================
#                        USER PROMPTS (NESTED MESSAGE LOOP)
# ============================================================================

function Show-PromptInWindow {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [string] $YesText = 'Да',
        [string] $NoText  = 'Нет'
    )
    if (-not $Script:UI) { return $true }

    try {
        $Script:UI.ActionText.Text       = $Message
        $Script:UI.ActionText.Foreground = New-Brush $Script:Color_TextMain
        $Script:UI.YesBtn.Content        = $YesText
        $Script:UI.NoBtn.Content         = $NoText
        $Script:UI.YesBtn.Visibility     = 'Visible'
        $Script:UI.NoBtn.Visibility      = 'Visible'
        $Script:UI.ActionBorder.Visibility = 'Visible'
    } catch { return $true }

    $Script:Prompt.Answer = $null
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $Script:Prompt.Frame = $frame

    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $Script:Prompt.Frame = $null

    try { $Script:UI.ActionBorder.Visibility = 'Collapsed' } catch { }
    return $Script:Prompt.Answer
}

function Show-RebootCountdownInWindow {
    param(
        [int]$Seconds = 5,
        [string]$Reason = ''
    )
    if (-not $Script:UI) { return $true }

    $script:_secondsLeft = $Seconds
    $script:_rebootReason = $Reason
    $Script:Prompt.Answer = $null

    try {
        $Script:UI.ActionText.Foreground   = New-Brush $Script:Color_Warn
        $Script:UI.ActionText.Text         = "$([char]0x26A0)  $Reason`n$([char]0x23F3) Перезагрузка через $Seconds сек..."
        $Script:UI.YesBtn.Content          = 'Перезагрузить'
        $Script:UI.NoBtn.Content           = 'Отмена'
        $Script:UI.YesBtn.Visibility       = 'Visible'
        $Script:UI.NoBtn.Visibility        = 'Visible'
        $Script:UI.ActionBorder.Visibility = 'Visible'
    } catch { return $true }

    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $Script:Prompt.Frame = $frame

    $Script:_rebootTimer = New-Object System.Windows.Threading.DispatcherTimer
    $Script:_rebootTimer.Interval = [TimeSpan]::FromSeconds(1)
    $Script:_rebootTimer.Add_Tick({
        try {
            $script:_secondsLeft--
            if ($script:_secondsLeft -le 0) {
                $Script:_rebootTimer.Stop()
                if ($Script:Prompt.Frame) {
                    $Script:Prompt.Answer = $true
                    $Script:Prompt.Frame.Continue = $false
                }
            } else {
                $Script:UI.ActionText.Text = "$([char]0x26A0)  $($script:_rebootReason)`n$([char]0x23F3) Перезагрузка через $($script:_secondsLeft) сек..."
            }
        } catch { }
    })
    $Script:_rebootTimer.Start()

    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $Script:Prompt.Frame = $null

    try { $Script:_rebootTimer.Stop() } catch { }
    try { $Script:UI.ActionBorder.Visibility = 'Collapsed' } catch { }
    return $Script:Prompt.Answer
}

function Show-FinalSuccessInWindow {
    if (-not $Script:UI) { return }

    try {
        $Script:UI.ActionText.Foreground   = New-Brush $Script:Color_Ok
        $Script:UI.ActionText.Text         =
            "$([char]0x2714)  Готово! Кэш шейдеров NVIDIA успешно очищен.`n" +
            "Размер кэша возвращён в значение «Без ограничений».`n" +
            "При следующем запуске игр шейдеры будут перекомпилированы."
        $Script:UI.YesBtn.Content          = 'Закрыть'
        $Script:UI.YesBtn.Visibility       = 'Visible'
        $Script:UI.NoBtn.Visibility        = 'Collapsed'
        $Script:UI.ActionBorder.Visibility = 'Visible'
    } catch { return }

    $Script:Prompt.Answer = $null
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $Script:Prompt.Frame = $frame
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $Script:Prompt.Frame = $null
}

function Show-FatalInWindow {
    param([Parameter(Mandatory)][string]$Message)
    if (-not $Script:UI) { return }

    try {
        $Script:UI.ActionText.Foreground   = New-Brush $Script:Color_Error
        $Script:UI.ActionText.Text         = "$([char]0x2716)  $Message`nПодробности в логе: $($Script:LogFile)"
        $Script:UI.YesBtn.Content          = 'Закрыть'
        $Script:UI.YesBtn.Visibility       = 'Visible'
        $Script:UI.NoBtn.Visibility        = 'Collapsed'
        $Script:UI.ActionBorder.Visibility = 'Visible'
    } catch { return }

    $Script:Prompt.Answer = $null
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $Script:Prompt.Frame = $frame
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $Script:Prompt.Frame = $null
}

# ============================================================================
#                        NVIDIA PROFILE INSPECTOR
# ============================================================================

function Ensure-NpiInstalled {
    $npiExe = Join-Path $Script:ToolsDir $Script:NpiExeName

    if (Test-Path $npiExe) {
        Write-Log "NVIDIA Profile Inspector found: $npiExe" 'INFO'
        return $npiExe
    }

    Write-Log "NVIDIA Profile Inspector not found, downloading..." 'INFO'
    Set-UIStatus 'Загрузка nvidiaProfileInspector...'

    if (-not (Test-Path $Script:ToolsDir)) {
        New-Item -ItemType Directory -Path $Script:ToolsDir -Force | Out-Null
    }

    $zipPath = Join-Path $Script:ToolsDir 'nvidiaProfileInspector.zip'

    $hasInternet = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect('github.com', 443, $null, $null)
        $ok  = $iar.AsyncWaitHandle.WaitOne(3000, $false)
        if ($ok -and $tcp.Connected) { $hasInternet = $true }
        $tcp.Close()
    } catch { $hasInternet = $false }

    if (-not $hasInternet) {
        $msg = "Нет подключения к интернету. Скачайте $($Script:NpiUrl) вручную и распакуйте $($Script:NpiExeName) в $($Script:ToolsDir)."
        Write-Log $msg 'ERROR'
        throw $msg
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12 -bor `
            [Net.SecurityProtocolType]::Tls13 -bor `
            [Net.SecurityProtocolType]::Tls11
    } catch {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    }

    try {
        Write-Log "Downloading $($Script:NpiUrl) ..." 'INFO'
        Invoke-WebRequest -Uri $Script:NpiUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
    } catch {
        throw "Не удалось скачать NVIDIA Profile Inspector: $($_.Exception.Message)"
    }

    try {
        Expand-Archive -Path $zipPath -DestinationPath $Script:ToolsDir -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    } catch {
        throw "Не удалось распаковать NVIDIA Profile Inspector: $($_.Exception.Message)"
    }

    if (-not (Test-Path $npiExe)) {
        $found = Get-ChildItem -Path $Script:ToolsDir -Filter $Script:NpiExeName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { Move-Item -Path $found.FullName -Destination $npiExe -Force }
    }
    if (-not (Test-Path $npiExe)) {
        throw "После распаковки не найден $($Script:NpiExeName) в $($Script:ToolsDir)."
    }

    Write-Log "NVIDIA Profile Inspector installed: $npiExe" 'OK'
    return $npiExe
}

function New-NipFile {
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
    Set-UIStatus "Применение настройки Shader Cache = $Mode..."

    $nipFile = Join-Path $Script:AppDataDir "shader_cache_$($Mode.ToLower()).nip"
    try {
        New-NipFile -FilePath $nipFile `
                    -SettingId $Script:ShaderCacheSizeSettingId `
                    -SettingName $Script:ShaderCacheSizeSettingName `
                    -SettingValue $value

        $proc = Start-Process -FilePath $NpiPath `
            -ArgumentList "`"$nipFile`"", '-silentImport' `
            -PassThru -WindowStyle Hidden -ErrorAction Stop

        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while (-not $proc.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 200
            Update-UI
        }
        if (-not $proc.HasExited) {
            try { $proc.Kill() } catch { }
            throw 'nvidiaProfileInspector не завершился за 60 секунд (завис).'
        }
        Write-Log "Shader Cache Size = $Mode applied successfully." 'OK'
    } finally {
        Remove-Item $nipFile -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
#                          NVIDIA PROCESSES
# ============================================================================

function Get-RunningNvidiaProcesses {
    $selfPid = $PID
    $list = @()
    foreach ($name in $Script:NvidiaProcessNames) {
        $p = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($p) { $list += $p }
    }
    $extra = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match '^(?i)(nv|nvidia)' -and ($list.Id -notcontains $_.Id)
    }
    if ($extra) { $list += $extra }
    $list = @($list | Where-Object { $_.Id -ne $selfPid })
    return $list
}

function Stop-NvidiaProcessesWithConsent {
    $procs = Get-RunningNvidiaProcesses
    if (-not $procs -or $procs.Count -eq 0) {
        Write-Log 'No running NVIDIA processes found.' 'INFO'
        return $true
    }

    $uniqueNames = ($procs | Select-Object -ExpandProperty ProcessName -Unique)
    $namesList = ($uniqueNames -join ', ')
    $msg = "Обнаружены процессы NVIDIA: $namesList. Закрыть их сейчас?"

    if (-not (Show-PromptInWindow -Message $msg -YesText 'Закрыть процессы' -NoText 'Отмена')) {
        Write-Log 'User refused to close NVIDIA processes.' 'WARN'
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
    Wait-WithUI -Milliseconds 2000
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
        Update-UI
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
    $cleared = @(); $missing = @(); $errors = @()

    if (-not $libs -or $libs.Count -eq 0) {
        Write-Log 'Steam not found in registry.' 'WARN'
        return @{ Cleared = $cleared; Missing = $missing; Errors = $errors; SteamFound = $false }
    }

    foreach ($lib in $libs) {
        $path = Join-Path $lib 'steamapps\shadercache\730'
        if (-not (Test-Path $path)) {
            Write-Log "Path $path does not exist, skipping." 'INFO'
            $missing += $path; continue
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
        Update-UI
    }
    return @{ Cleared = $cleared; Missing = $missing; Errors = $errors; SteamFound = $true }
}

# ============================================================================
#                         TASK SCHEDULER (RESUME)
# ============================================================================

function Register-ResumeTask {
    $exe = Get-SelfExePath
    if (-not $exe) { throw 'Не удалось определить путь к .exe для создания задачи.' }

    Unregister-ResumeTask

    $user = "$env:USERDOMAIN\$env:USERNAME"
    Write-Log "Registering scheduled task '$($Script:TaskName)' for $user -> $exe" 'INFO'

    $action    = New-ScheduledTaskAction -Execute $exe -Argument '-Elevated'
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = 'PT30S'
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

    $doReboot = Show-RebootCountdownInWindow -Seconds 5 -Reason $Reason
    if ($doReboot) {
        Write-Log 'Initiating reboot (shutdown /r /t 5).' 'INFO'
        & shutdown.exe /r /t 5 /c "NvShaderCleaner: reboot to apply shader cache settings."
    } else {
        Write-Log 'User cancelled automatic reboot.' 'WARN'
        Set-UIStatus 'Автоматическая перезагрузка отменена - перезагрузите ПК вручную.'
        Wait-WithUI -Milliseconds 800
    }
    try { $Script:UI.Window.Close() } catch { }
}

# ============================================================================
#                                STEPS
# ============================================================================

function Invoke-Step-Init {
    Write-Log '=== STEP 1: setting Shader Cache Size = Disabled ===' 'INFO'
    Set-UIStep -Index 0 -Status active -Subtitle "$([char]0x25B6) отключаем кэш..."
    Set-UIStep -Index 1 -Status pending
    Set-UIStep -Index 2 -Status pending
    Set-UIProgress 5

    $npi = Ensure-NpiInstalled
    Set-UIProgress 25

    Set-UIStatus 'Отключение Shader Cache через NVIDIA Profile Inspector...'
    Set-ShaderCacheSize -Mode Disabled -NpiPath $npi
    Set-UIProgress 45

    Set-UIStatus 'Регистрируем автозапуск после перезагрузки...'
    Register-ResumeTask
    Set-UIProgress 55

    $state = Get-State
    $state.Step    = 'AFTER_REBOOT_1'
    $state.NpiPath = $npi
    Save-State $state

    Set-UIStep -Index 0 -Status done
    Set-UIProgress 60
    Invoke-RebootOrAbort -Reason 'Кэш шейдеров отключён. Нужна перезагрузка - очистка продолжится автоматически.'
}

function Invoke-Step-AfterReboot1 {
    Write-Log '=== STEP 2: cleaning shader cache folders ===' 'INFO'
    Set-UIStep -Index 0 -Status done
    Set-UIStep -Index 1 -Status active -Subtitle "$([char]0x25B6) останавливаем процессы NVIDIA..."
    Set-UIStep -Index 2 -Status pending
    Set-UIProgress 60

    if (-not (Stop-NvidiaProcessesWithConsent)) {
        Set-UIStep -Index 1 -Status error
        Show-FatalInWindow 'Очистка не может быть продолжена, пока запущены процессы NVIDIA. Закройте их вручную и запустите программу снова.'
        try { $Script:UI.Window.Close() } catch { }
        return
    }
    Set-UIProgress 70

    Set-UIStatus 'Удаление папок NVIDIA\DXCache и NVIDIA\GLCache...'
    $nvResult = Remove-NvidiaCacheFolders
    Set-UIProgress 78

    Set-UIStatus 'Очистка Steam shadercache\730 (CS2)...'
    $steamResult = Remove-SteamShaderCache730
    Set-UIProgress 85

    $npi = (Get-State).NpiPath
    if (-not $npi -or -not (Test-Path $npi)) { $npi = Ensure-NpiInstalled }

    Set-UIStatus 'Возвращаем Shader Cache в Unlimited...'
    Set-ShaderCacheSize -Mode Unlimited -NpiPath $npi
    Set-UIProgress 92

    foreach ($e in $nvResult.Errors)    { Write-Log "NVIDIA cache: $e" 'WARN' }
    foreach ($e in $steamResult.Errors) { Write-Log "Steam cache:  $e" 'WARN' }

    $state = Get-State
    $state.Step = 'AFTER_REBOOT_2'
    Save-State $state

    Register-ResumeTask

    Set-UIStep -Index 1 -Status done
    Set-UIProgress 95
    Invoke-RebootOrAbort -Reason 'Очистка завершена. Перезагрузка для финализации - после входа появится окно завершения.'
}

function Invoke-Step-AfterReboot2 {
    Write-Log '=== STEP 3: final window ===' 'INFO'
    Set-UIStep -Index 0 -Status done
    Set-UIStep -Index 1 -Status done
    Set-UIStep -Index 2 -Status active -Subtitle "$([char]0x25B6) финализация..."
    Set-UIProgress 97

    Unregister-ResumeTask
    Clear-State

    Set-UIStep -Index 2 -Status done
    Set-UIProgress 100
    Set-UIStatus 'Готово!'
    Write-Log '=== Done. State cleared. ===' 'OK'

    Show-FinalSuccessInWindow
    try { $Script:UI.Window.Close() } catch { }
}

# ============================================================================
#                                MAIN
# ============================================================================

function Main {
    Initialize-AppFolder
    Initialize-UIAssemblies

    Write-Log '----- NvShaderCleaner started -----' 'INFO'

    if (-not (Test-Administrator)) {
        Write-Log 'Not admin, requesting UAC...' 'INFO'
        Invoke-SelfElevate
        return
    }

    $Script:UI = Build-MainWindow

    # Enable window dragging from any non-control area.
    # Must be registered here (not in Build-MainWindow) because ps2exe
    # cannot capture local $w in event closures; $Script:UI is reliable.
    $Script:UI.Window.Add_MouseLeftButtonDown({
        try { $Script:UI.Window.DragMove() } catch { }
    })

    # Button handlers break out of nested PushFrame loops
    $Script:UI.YesBtn.Add_Click({
        try {
            $Script:Prompt.Answer = $true
            if ($Script:Prompt.Frame) { $Script:Prompt.Frame.Continue = $false }
        } catch { }
    })
    $Script:UI.NoBtn.Add_Click({
        try {
            $Script:Prompt.Answer = $false
            if ($Script:Prompt.Frame) { $Script:Prompt.Frame.Continue = $false }
        } catch { }
    })

    # After window renders, start workflow via a one-shot DispatcherTimer.
    # This defers execution so ShowDialog's message loop is running first.
    $Script:UI.Window.Add_ContentRendered({
        try {
            Set-UIStatus 'Инициализация...'
            $stateNow = Get-State
            switch ($stateNow.Step) {
                'INIT'           {
                    Set-UIStep -Index 0 -Status pending
                    Set-UIStep -Index 1 -Status pending
                    Set-UIStep -Index 2 -Status pending
                }
                'AFTER_REBOOT_1' {
                    Set-UIStep -Index 0 -Status done
                    Set-UIStep -Index 1 -Status pending
                    Set-UIStep -Index 2 -Status pending
                    Set-UIProgress 60
                }
                'AFTER_REBOOT_2' {
                    Set-UIStep -Index 0 -Status done
                    Set-UIStep -Index 1 -Status done
                    Set-UIStep -Index 2 -Status pending
                    Set-UIProgress 95
                }
            }
            Update-UI
        } catch { }

        $Script:_kickoff = New-Object System.Windows.Threading.DispatcherTimer
        $Script:_kickoff.Interval = [TimeSpan]::FromMilliseconds(200)
        $Script:_kickoff.Add_Tick({
            try { $Script:_kickoff.Stop() } catch { }
            try {
                $state = Get-State
                Write-Log "Current step: $($state.Step)" 'INFO'
                switch ($state.Step) {
                    'INIT'           { Invoke-Step-Init }
                    'AFTER_REBOOT_1' { Invoke-Step-AfterReboot1 }
                    'AFTER_REBOOT_2' { Invoke-Step-AfterReboot2 }
                    'DONE'           { Clear-State; Invoke-Step-Init }
                    default          { Clear-State; Invoke-Step-Init }
                }
            } catch {
                Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
                try { Write-Log "$($_.ScriptStackTrace)" 'ERROR' } catch { }
                Show-FatalInWindow "Непредвиденная ошибка: $($_.Exception.Message)"
                try { $Script:UI.Window.Close() } catch { }
            }
        })
        $Script:_kickoff.Start()
    })

    # If window is closed externally (X button), break any active prompt
    $Script:UI.Window.Add_Closed({
        try {
            $Script:Prompt.Answer = $false
            if ($Script:Prompt.Frame) { $Script:Prompt.Frame.Continue = $false }
        } catch { }
    })

    [void]$Script:UI.Window.ShowDialog()
}

Main
