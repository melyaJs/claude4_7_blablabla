@echo off
REM ============================================================================
REM  NvShaderCleaner - build .exe with a double-click.
REM  Runs Build-Exe.ps1 with ExecutionPolicy Bypass and UTF-8 codepage.
REM ============================================================================
setlocal
cd /d "%~dp0"
chcp 65001 >nul 2>&1

echo.
echo [Build.cmd] Building NvShaderCleaner.exe ...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Exe.ps1"
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo [Build.cmd] Done. NvShaderCleaner.exe is in this folder.
) else (
    echo [Build.cmd] Build finished with exit code %RC%.
)

echo.
pause
endlocal
exit /b %RC%
