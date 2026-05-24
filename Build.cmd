@echo off
REM ============================================================================
REM  NvShaderCleaner — сборка .exe двойным кликом.
REM  Этот файл просто запускает Build-Exe.ps1 с ExecutionPolicy Bypass.
REM ============================================================================
setlocal
cd /d "%~dp0"

echo.
echo [Build.cmd] Запускаю сборку NvShaderCleaner.exe ...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Exe.ps1"
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo [Build.cmd] Готово. NvShaderCleaner.exe находится в этой же папке.
) else (
    echo [Build.cmd] Сборка завершилась с кодом %RC%.
)

echo.
pause
endlocal
exit /b %RC%
