@echo off
setlocal enabledelayedexpansion
:: ============================================================================
:: Smart Launcher for WinPE Image Deployment Tool
:: Discovers PowerShell, the deployment script, and image drives automatically.
:: Edit DEPLOY_LABEL below to match your USB data partition volume label.
:: ============================================================================

set DEPLOY_LABEL=DEPLOY_IMAGES
set PS_EXE=
set DEPLOY_SCRIPT=
set DEPLOY_IMAGE_DRIVE=
set DEPLOY_LAUNCHER_DIR=%~dp0

:: Initialize WinPE networking and hardware
wpeinit

:: Allow drives to settle after wpeinit
timeout /t 3 /nobreak >nul

echo.
echo ================================================================
echo   WinPE Image Deployment - Smart Launcher
echo ================================================================
echo.

:: ── Step 1: Discover PowerShell ──────────────────────────────────────────────
echo [Step 1/4] Discovering PowerShell...

:: Prefer pwsh.exe (PowerShell 7+) if available on any drive
for %%d in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%d:\Program Files\PowerShell\7\pwsh.exe" (
        set "PS_EXE=%%d:\Program Files\PowerShell\7\pwsh.exe"
        goto :ps_found
    )
)

:: Fall back to Windows PowerShell on system path
where powershell.exe >nul 2>&1
if %ERRORLEVEL% equ 0 (
    set "PS_EXE=powershell.exe"
    goto :ps_found
)

:: Search all drives for powershell.exe
for %%d in (X W V U T S R Q P O N M L K J I H G F E D C B A) do (
    if exist "%%d:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" (
        set "PS_EXE=%%d:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        goto :ps_found
    )
)

echo   [FAIL] PowerShell not found on any drive
echo   Ensure WinPE-PowerShell package is included in the WinPE image.
pause
exit /b 1

:ps_found
echo   [OK] %PS_EXE%

:: ── Step 2: Discover Deployment Script ───────────────────────────────────────
echo [Step 2/4] Discovering deployment script...

:: Check same directory as this launcher
if exist "%~dp0unified_winpe_deploy.ps1" (
    set "DEPLOY_SCRIPT=%~dp0unified_winpe_deploy.ps1"
    goto :script_found
)

:: Check scripts/ subdirectory
if exist "%~dp0scripts\unified_winpe_deploy.ps1" (
    set "DEPLOY_SCRIPT=%~dp0scripts\unified_winpe_deploy.ps1"
    goto :script_found
)

:: Scan all drives
for %%d in (X W V U T S R Q P O N M L K J I H G F E D C B A) do (
    if exist "%%d:\unified_winpe_deploy.ps1" (
        set "DEPLOY_SCRIPT=%%d:\unified_winpe_deploy.ps1"
        goto :script_found
    )
    if exist "%%d:\scripts\unified_winpe_deploy.ps1" (
        set "DEPLOY_SCRIPT=%%d:\scripts\unified_winpe_deploy.ps1"
        goto :script_found
    )
    if exist "%%d:\Windows\System32\unified_winpe_deploy.ps1" (
        set "DEPLOY_SCRIPT=%%d:\Windows\System32\unified_winpe_deploy.ps1"
        goto :script_found
    )
)

echo   [FAIL] unified_winpe_deploy.ps1 not found
echo   Place the script alongside this launcher or in a scripts\ subdirectory.
pause
exit /b 1

:script_found
echo   [OK] %DEPLOY_SCRIPT%

:: ── Step 3: Discover Image Drive ─────────────────────────────────────────────
echo [Step 3/4] Discovering image drive...

:: Skip if already set by parent script
if defined DEPLOY_IMAGE_DRIVE (
    echo   [OK] %DEPLOY_IMAGE_DRIVE% (pre-set)
    goto :step4
)

:: Search by volume label
for %%d in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    vol %%d: 2>nul | find /i "%DEPLOY_LABEL%" >nul 2>&1
    if !ERRORLEVEL! equ 0 (
        set "DEPLOY_IMAGE_DRIVE=%%d:"
        echo   [OK] %%d: (label: %DEPLOY_LABEL%)
        goto :step4
    )
)

:: Fall back: scan for images/ directory containing .wim files
for %%d in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%d:\images\*.wim" (
        set "DEPLOY_IMAGE_DRIVE=%%d:"
        echo   [OK] %%d: (found .wim files in images\)
        goto :step4
    )
    if exist "%%d:\images\*.esd" (
        set "DEPLOY_IMAGE_DRIVE=%%d:"
        echo   [OK] %%d: (found .esd files in images\)
        goto :step4
    )
)

echo   [SKIP] No image drive found (script will auto-discover)

:: ── Step 4: Launch ───────────────────────────────────────────────────────────
:step4
echo [Step 4/4] Launching deployment script...
echo.

:: Build launch arguments
set "LAUNCH_ARGS=-ExecutionPolicy Bypass -NoProfile -File "%DEPLOY_SCRIPT%""

:: If we found an image drive with an images directory, pass it as -ImagePath
if defined DEPLOY_IMAGE_DRIVE (
    if exist "%DEPLOY_IMAGE_DRIVE%\images" (
        set "LAUNCH_ARGS=%LAUNCH_ARGS% -ImagePath "%DEPLOY_IMAGE_DRIVE%\images""
    )
)

echo Starting: %PS_EXE% %LAUNCH_ARGS%
echo.

"%PS_EXE%" %LAUNCH_ARGS%

:: If the script exits, pause so the user can see any errors
if %ERRORLEVEL% neq 0 (
    echo.
    echo Deployment script exited with error code %ERRORLEVEL%
    pause
)
