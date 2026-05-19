@echo off
setlocal

:: Check for administrator privileges
net session >nul 2>&1
if %errorLevel% == 0 goto :run

:: Not elevated -- re-launch this batch file with UAC elevation
echo Requesting administrator privileges...
powershell.exe -NoProfile -Command ^
    "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c \"%~f0\"' -Verb RunAs -Wait"
exit /b

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-MDT.ps1"
