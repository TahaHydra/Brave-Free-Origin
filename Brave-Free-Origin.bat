@echo off
REM -----------------------------------------------------------------------
REM  Brave Free Origin - Windows launcher (portable ZIP)
REM
REM  Double-click this file. It starts the PowerShell app with an execution
REM  policy bypass that lasts for this one process only, so your system
REM  PowerShell policy is never changed. The app itself asks Windows for
REM  administrator permission (the UAC prompt).
REM
REM  Exit codes coming back from the app:
REM    0  ok (also returned right after it re-launches itself elevated)
REM    1  the app could not start (it shows a message and writes a log)
REM    2  administrator permission was declined
REM -----------------------------------------------------------------------
setlocal
cd /d "%~dp0"
set "SCRIPT=%~dp0Brave-Free-Origin.ps1"

if not exist "%SCRIPT%" (
    echo Brave-Free-Origin.ps1 was not found next to this launcher.
    echo.
    echo Extract the whole ZIP first, then run this file from the extracted folder.
    echo.
    pause
    exit /b 1
)

echo Starting Brave Free Origin...
echo Windows will ask for administrator permission. Choose Yes.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RC=%errorlevel%"

if "%RC%"=="0" goto :done

echo.
if "%RC%"=="2" (
    echo Administrator permission was not granted, so nothing was changed.
    echo Run this file again and choose Yes on the Windows prompt.
) else (
    echo Brave Free Origin could not start ^(exit code %RC%^).
    echo Details were saved in: %LOCALAPPDATA%\Brave-Free-Origin\logs
    echo If PowerShell says scripts are blocked by your organization, ask your administrator.
)
echo.
pause

:done
endlocal & exit /b %RC%
