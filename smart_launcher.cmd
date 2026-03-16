@echo off
setlocal enabledelayedexpansion
:: ============================================================================
:: WinPE Image Deployment Launcher
:: Finds the USB data partition by volume label and launches the deploy script.
:: Edit DEPLOY_LABEL below to match your USB data partition volume label.
:: ============================================================================

set DEPLOY_LABEL=IMAGES

wpeinit
timeout /t 3 /nobreak >nul

echo.
echo ================================================================
echo   WinPE Image Deployment - Launcher
echo ================================================================
echo.

:: Find the data partition by volume label
set DEPLOY_IMAGE_DRIVE=
for %%d in (D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    vol %%d: 2>nul | find /i "%DEPLOY_LABEL%" >nul 2>&1
    if !ERRORLEVEL! equ 0 (
        set "DEPLOY_IMAGE_DRIVE=%%d:"
        goto :found
    )
)

echo [WARN] No drive with label "%DEPLOY_LABEL%" found.
echo        The script will scan all drives for images.
goto :launch

:found
echo Found image drive: %DEPLOY_IMAGE_DRIVE% (label: %DEPLOY_LABEL%)

:launch
echo.

set "LAUNCH_ARGS=-ExecutionPolicy Bypass -NoProfile -File "%~dp0unified_winpe_deploy.ps1""
if defined DEPLOY_IMAGE_DRIVE (
    if exist "%DEPLOY_IMAGE_DRIVE%\images" (
        set "LAUNCH_ARGS=%LAUNCH_ARGS% -ImagePath "%DEPLOY_IMAGE_DRIVE%\images""
    )
)

powershell.exe %LAUNCH_ARGS%

if %ERRORLEVEL% neq 0 (
    echo.
    echo Deployment script exited with error code %ERRORLEVEL%
    pause
)
