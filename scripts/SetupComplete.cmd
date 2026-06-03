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

call :RunPS Set-Level0ACL.ps1
if errorlevel 1 goto :Fail

REM Disable-RDP.ps1 TEMPORARILY LINED OUT by choice for now. The script itself
REM is reworked (registry fDenyTSConnections + NLA + service disable; firewall
REM changes removed). WARNING: while lined out, RDP stays ENABLED on deployed
REM machines (it was turned on for the Hyper-V enhanced-session build).
REM Re-enable by un-commenting the two lines below.
REM call :RunPS Disable-RDP.ps1
REM if errorlevel 1 goto :Fail

call :RunPS Harden-Administrator.ps1
if errorlevel 1 goto :Fail

REM Apply-StigHardening.ps1 TEMPORARILY LINED OUT -- not used for now. WARNING:
REM this removes Guest disable/rename, password+lockout policy, UAC hardening,
REM the logon banner, AND the assertion that only IT_Admin + the disabled
REM built-in admin are in local Administrators.
REM call :RunPS Apply-StigHardening.ps1
REM if errorlevel 1 goto :Fail

call :RunPS Enable-BitLocker.ps1
if errorlevel 1 goto :Fail

REM Best-effort app install: never aborts the chain (script exits 0).
call :RunPS Install-NotepadPP.ps1

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
