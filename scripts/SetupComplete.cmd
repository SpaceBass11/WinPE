@echo off
setlocal

set ROOT=C:\ProgramData\ManualClonezilla
set LOGDIR=%ROOT%\Logs
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

echo ==== SetupComplete started %date% %time% ====>> "%LOGDIR%\SetupComplete.log"

call :RunPS Apply-DellConfig.ps1
if errorlevel 1 goto :Fail

call :RunPS Scrub-AuditArtifacts.ps1
if errorlevel 1 goto :Fail

call :RunPS New-LocalAccounts.ps1
if errorlevel 1 goto :Fail

REM Pre-create Level 1's profile (Win32 CreateProfile) and seed the Docker
REM data disk into it. Non-fatal (script always exits 0) so a missing or
REM failed Docker payload cannot abort the security chain.
call :RunPS Stage-DockerData.ps1

call :RunPS Set-Level0ACL.ps1
if errorlevel 1 goto :Fail

REM RDP-off, the STIG baseline, and the Notepad++ install are baked into the
REM gold PRE-SYSPREP (see Apply-GoldHardening.ps1) -- they are SID-independent
REM image state that survives generalize, so they are NOT re-run here.

call :RunPS Harden-Administrator.ps1
if errorlevel 1 goto :Fail

REM Post-sysprep safety gate: only IT_Admin + the disabled built-in admin may
REM be local Administrators. Hard-fail (needs the post-generalize accounts).
call :RunPS Assert-AdminGroup.ps1
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
