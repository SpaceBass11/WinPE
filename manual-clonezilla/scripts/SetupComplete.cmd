@echo off
setlocal

set ROOT=C:\ProgramData\ManualClonezilla
set LOGDIR=%ROOT%\Logs
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

echo ==== SetupComplete started %date% %time% ====>> "%LOGDIR%\SetupComplete.log"

call :RunPS Apply-DellConfig.ps1
if errorlevel 1 goto :Fail

call :RunPS Enable-BitLocker.ps1
if errorlevel 1 goto :Fail

call :RunPS Finalize-Cleanup.ps1
if errorlevel 1 goto :Fail

echo SetupComplete succeeded>> "%LOGDIR%\SetupComplete.log"
exit /b 0

:RunPS
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\Scripts\%~1" >> "%LOGDIR%\SetupComplete.log" 2>&1
exit /b %errorlevel%

:Fail
echo SetupComplete failed with code %errorlevel%>> "%LOGDIR%\SetupComplete.log"
exit /b %errorlevel%
