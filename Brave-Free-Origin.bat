@echo off
REM -----------------------------------------------------------------------
REM  Brave Free Origin - Windows launcher
REM  Double-click this file. It uses a one-shot ExecutionPolicy Bypass so
REM  users do NOT need to change the system PowerShell policy manually.
REM  The PowerShell script handles UAC elevation and opens the GUI.
REM -----------------------------------------------------------------------
setlocal
cd /d "%~dp0"
set "SCRIPT=%~dp0Brave-Free-Origin.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: Brave-Free-Origin.ps1 was not found next to this launcher.
    echo.
    echo Make sure you extracted the whole folder before running it.
    pause
    exit /b 1
)

echo Launching Brave Free Origin...
echo If Windows shows a UAC prompt, click Yes.
echo If SmartScreen appears, use More info ^> Run anyway only if you trust this local copy.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

if errorlevel 1 (
    echo.
    echo The launcher returned a non-zero exit code.
    echo Try right-clicking this BAT file and choosing Run as administrator.
    pause
)

endlocal
