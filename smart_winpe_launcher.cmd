@echo off
setlocal enabledelayedexpansion
title SAMS Image Deployment Tool - Auto Discovery
color 0B

:: ====================================================================
::                    AUTO-DISCOVERY LAUNCHER
:: ====================================================================

echo.
echo ====================================================================
echo                    SAMS IMAGE DEPLOYMENT TOOL
echo                         Auto-Discovery Mode
echo ====================================================================
echo.

:: Get script directory (where this batch file is located)
set "SCRIPT_DIR=%~dp0"
set "BASE_DIR=%SCRIPT_DIR:~0,-1%"

echo Launcher location: %BASE_DIR%
echo.

:: ====================================================================
::                    DISCOVER POWERSHELL
:: ====================================================================

echo [1/4] Discovering PowerShell...

:: Search order for PowerShell
set "PWSH_FOUND="
set "PWSH_VERSION="

:: 1. Check for PowerShell 7+ in common WinPE locations
for %%d in (X Y Z A B C D E F G H I J K L M N O P Q R S T U V W) do (
    if exist "%%d:\programs\powershell*\pwsh.exe" (
        for /d %%p in ("%%d:\programs\powershell*") do (
            if exist "%%p\pwsh.exe" (
                set "PWSH_FOUND=%%p\pwsh.exe"
                set "PWSH_VERSION=%%~nxp"
                goto :pwsh_found
            )
        )
    )
)

:: 2. Check relative to launcher
if exist "%BASE_DIR%\tools\powershell\pwsh.exe" (
    set "PWSH_FOUND=%BASE_DIR%\tools\powershell\pwsh.exe"
    set "PWSH_VERSION=Local"
    goto :pwsh_found
)

:: 3. Check Windows PowerShell as fallback
where powershell.exe >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    set "PWSH_FOUND=powershell.exe"
    set "PWSH_VERSION=Windows PowerShell (Fallback)"
    goto :pwsh_found
)

:: PowerShell not found
color 4F
echo    ERROR: No PowerShell found!
echo    Searched locations:
echo    - Drive:\programs\powershell*\pwsh.exe
echo    - %BASE_DIR%\tools\powershell\pwsh.exe
echo    - System PATH for powershell.exe
echo.
goto :error_exit

:pwsh_found
echo    Found: %PWSH_VERSION%
echo    Path:  !PWSH_FOUND!
echo.

:: ====================================================================
::                    DISCOVER DEPLOYMENT SCRIPT
:: ====================================================================

echo [2/4] Discovering deployment script...

set "DEPLOY_SCRIPT="

:: Search order for deployment script
:: 1. Same directory as launcher
if exist "%BASE_DIR%\Apply_Sams_Image.ps1" (
    set "DEPLOY_SCRIPT=%BASE_DIR%\Apply_Sams_Image.ps1"
    goto :script_found
)

:: 2. Scripts subdirectory
if exist "%BASE_DIR%\scripts\Apply_Sams_Image.ps1" (
    set "DEPLOY_SCRIPT=%BASE_DIR%\scripts\Apply_Sams_Image.ps1"
    goto :script_found
)

:: 3. Search drives for scripts directory
for %%d in (X Y Z A B C D E F G H I J K L M N O P Q R S T U V W) do (
    if exist "%%d:\scripts\Apply_Sams_Image\Apply_Sams_Image.ps1" (
        set "DEPLOY_SCRIPT=%%d:\scripts\Apply_Sams_Image\Apply_Sams_Image.ps1"
        goto :script_found
    )
)

:: Script not found
color 4F
echo    ERROR: Deployment script not found!
echo    Searched locations:
echo    - %BASE_DIR%\Apply_Sams_Image.ps1
echo    - %BASE_DIR%\scripts\Apply_Sams_Image.ps1
echo    - Drive:\scripts\Apply_Sams_Image\Apply_Sams_Image.ps1
echo.
goto :error_exit

:script_found
echo    Found: !DEPLOY_SCRIPT!
echo.

:: ====================================================================
::                    DISCOVER IMAGE LOCATION
:: ====================================================================

echo [3/4] Discovering image location...

set "IMAGE_DRIVE="

:: Look for SAMS_IMAGES drive label
for %%d in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    vol %%d: 2>nul | find "SAMS_IMAGES" >nul
    if !ERRORLEVEL! EQU 0 (
        if exist "%%d:\images\SAMS*.wim" (
            set "IMAGE_DRIVE=%%d:"
            goto :images_found
        )
    )
)

:: Fallback: search for images directory with SAMS WIM files
for %%d in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%d:\images\SAMS*.wim" (
        set "IMAGE_DRIVE=%%d:"
        goto :images_found
    )
)

echo    WARNING: No images found, but deployment script will search at runtime
echo    This is normal if images are on a different drive or network location
echo.
goto :launch_script

:images_found
echo    Found images on: !IMAGE_DRIVE!
for %%f in ("!IMAGE_DRIVE!\images\SAMS*.wim") do (
    echo    - %%~nxf
)
echo.

:: ====================================================================
::                    LAUNCH DEPLOYMENT SCRIPT
:: ====================================================================

:launch_script
echo [4/4] Launching deployment script...
echo.
echo ====================================================================
echo                    STARTING DEPLOYMENT PROCESS
echo ====================================================================
echo.

:: Set environment variables for the PowerShell script to use
set "SAMS_LAUNCHER_DIR=%BASE_DIR%"
if defined IMAGE_DRIVE set "SAMS_IMAGE_DRIVE=%IMAGE_DRIVE%"

:: Launch with appropriate parameters
"!PWSH_FOUND!" -ExecutionPolicy Bypass -NoProfile -File "!DEPLOY_SCRIPT!"

:: Handle completion
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo ====================================================================
if %EXIT_CODE% EQU 0 (
    color 2F
    echo                    DEPLOYMENT COMPLETED SUCCESSFULLY
) else (
    color 4F
    echo                    DEPLOYMENT COMPLETED WITH ISSUES
    echo                           Exit Code: %EXIT_CODE%
)
echo ====================================================================
echo.
echo Press any key to close...
pause >nul
exit /b %EXIT_CODE%

:error_exit
echo Press any key to exit...
pause >nul
exit /b 1