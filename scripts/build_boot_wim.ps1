#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Build a customized WinPE boot.wim for the unified_winpe_deploy.ps1 tool.

.DESCRIPTION
    Reproducible WinPE builder. Copies the ADK WinPE template, mounts boot.wim,
    adds the optional components and registry tweaks needed to apply Windows
    images that contain Windows Containers / Hyper-V layers, embeds the
    deployment script, and writes a startnet.cmd that auto-launches it.

    Must be run from the "Deployment and Imaging Tools Environment" shell (so
    copype and the ADK tools are on PATH), or with the ADK WinPE addon
    installed at the default location.

.PARAMETER WorkDir
    Working directory for copype output. Default: C:\WinPE_Build

.PARAMETER Architecture
    Target architecture: amd64 (default), x86, or arm64.

.PARAMETER DeployScript
    Path to unified_winpe_deploy.ps1. Default: sibling of this script's parent.

.PARAMETER AdkPath
    Override ADK install root. Default:
    C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit

.PARAMETER Clean
    Delete WorkDir before starting (fresh build).

.PARAMETER UsbDrive
    Drive letter of the already-partitioned WinPE FAT32 boot partition
    (e.g. 'P:'). If given, the built media is xcopied there at the end.
    Create the partition per docs/USB_SETUP.md Step 4 first.

.PARAMETER ReleaseUsbLetter
    After xcopy, run `mountvol <UsbDrive> /d` so the boot partition is no
    longer mounted in your working Windows session. Requires -UsbDrive.

.PARAMETER CctkSource
    Path to an extracted Dell Client Configuration Toolkit (CCTK) folder
    (the one containing cctk.exe). When given, the builder embeds CCTK
    into the boot.wim at X:\cctk\ and installs the HAPI driver into the
    offline image so CCTK can talk to the BIOS from WinPE. Per-machine
    configs live on the IMAGES data partition, not in boot.wim - see
    docs/CCTK.md for the selection precedence.

.EXAMPLE
    # Build only, leave output in C:\WinPE_Build\media for later xcopy
    .\build_boot_wim.ps1

.EXAMPLE
    # Build and copy to pre-partitioned USB boot partition P:, then release P:
    .\build_boot_wim.ps1 -UsbDrive P: -ReleaseUsbLetter -Clean

.EXAMPLE
    # Build with CCTK embedded (extracted from Dell installer to C:\cctk-src)
    .\build_boot_wim.ps1 -Clean -UsbDrive P: -ReleaseUsbLetter `
        -CctkSource C:\cctk-src
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\WinPE_Build',
    [ValidateSet('amd64','x86','arm64')]
    [string]$Architecture = 'amd64',
    [string]$DeployScript,
    [string]$AdkPath = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit',
    [switch]$Clean,
    [string]$UsbDrive,
    [switch]$ReleaseUsbLetter,
    [string]$CctkSource
)

$ErrorActionPreference = 'Stop'

# Components needed on top of the base boot.wim. Order matters - base cab
# first, language cab immediately after.
# The first six are standard PowerShell/DISM/WMI support (most builds need
# them regardless). The last three are what fixes the Windows Containers
# layer apply: StorageWMI + EnhancedStorage + FMAPI give DISM the storage
# surface area it needs, paired with the registry tweak below.
$Components = @(
    'WinPE-WMI'
    'WinPE-NetFx'
    'WinPE-Scripting'
    'WinPE-PowerShell'
    'WinPE-DismCmdlets'
    'WinPE-SecureStartup'
    'WinPE-StorageWMI'
    'WinPE-EnhancedStorage'
    'WinPE-FMAPI'
)

# Offline registry tweaks applied to the SYSTEM hive inside boot.wim.
# NtfsEnableDirCaseSensitivity = 1 is the fix for DISM "Incorrect function"
# on Windows Containers layer files at apply time - container layers set
# the CASE_SENSITIVE_DIR flag, which the live WinPE kernel will reject
# unless this key is set.
$RegTweaks = @(
    @{ Path = 'ControlSet001\Control\FileSystem'; Name = 'NtfsEnableDirCaseSensitivity'; Type = 'DWORD'; Value = 1 }
)

function Write-Step { param([string]$m) Write-Host "[build] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[ ok  ] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[warn ] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[ err ] $m" -ForegroundColor Red }

# Resolve deploy script path
if (-not $DeployScript) {
    $DeployScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'unified_winpe_deploy.ps1'
}
if (-not (Test-Path $DeployScript -PathType Leaf)) {
    throw "Deploy script not found: $DeployScript"
}
$DeployScript = (Resolve-Path $DeployScript).Path

# Resolve ADK paths
$winpeRoot = Join-Path $AdkPath "Windows Preinstallation Environment"
$copypeCmd = Join-Path $winpeRoot "copype.cmd"
$ocsDir    = Join-Path $winpeRoot "$Architecture\WinPE_OCs"

if (-not (Test-Path $copypeCmd)) {
    throw "copype.cmd not found at $copypeCmd - install the Windows ADK + WinPE add-on, or pass -AdkPath."
}
if (-not (Test-Path $ocsDir)) {
    throw "WinPE optional components not found at $ocsDir - install the WinPE add-on for ADK."
}

# Validate USB parameter combo
if ($ReleaseUsbLetter -and -not $UsbDrive) {
    throw "-ReleaseUsbLetter requires -UsbDrive"
}
if ($UsbDrive) {
    if ($UsbDrive -notmatch '^[A-Za-z]:$') {
        throw "-UsbDrive must be a drive letter like 'P:' (got '$UsbDrive')"
    }
    if (-not (Test-Path "$UsbDrive\")) {
        throw "USB drive $UsbDrive is not accessible - partition and assign the letter per docs/USB_SETUP.md Step 4 first."
    }
}

# CCTK source validation
$cctkExe = $null
$hapiInf = $null
if ($CctkSource) {
    if (-not (Test-Path $CctkSource -PathType Container)) {
        throw "-CctkSource must be an existing directory (got '$CctkSource')"
    }
    $CctkSource = (Resolve-Path $CctkSource).Path

    $cctkExe = Get-ChildItem -Path $CctkSource -Recurse -Filter 'cctk.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -match [regex]::Escape("\$Architecture\") -or $_.DirectoryName -notmatch '\\x86\\|\\x64\\|\\amd64\\|\\arm64\\' } |
        Select-Object -First 1
    if (-not $cctkExe) {
        $cctkExe = Get-ChildItem -Path $CctkSource -Recurse -Filter 'cctk.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $cctkExe) {
        throw "cctk.exe not found under $CctkSource - point -CctkSource at the extracted CCTK folder."
    }

    # HAPI driver inf (name varies: hapint64.inf, hapint64_DCH.inf, etc.)
    $hapiInf = Get-ChildItem -Path $CctkSource -Recurse -Include 'hapint*.inf','dcdbas*.inf' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $hapiInf) {
        Write-Warn "No HAPI driver inf found under $CctkSource - CCTK may fail in WinPE without it."
        Write-Warn "Look for HAPI\\hapint64.inf (or similar) in the CCTK distribution."
    }
}

# Fresh build if requested
if ($Clean -and (Test-Path $WorkDir)) {
    Write-Step "Removing existing workspace $WorkDir"
    # Ensure no stale mount before nuking the tree
    $staleMount = Join-Path $WorkDir 'mount'
    if (Test-Path $staleMount) {
        Write-Warn "Unmounting any stale image at $staleMount (discarding changes)"
        & dism.exe /Unmount-Image /MountDir:$staleMount /Discard 2>&1 | Out-Null
    }
    Remove-Item $WorkDir -Recurse -Force
}

# Step 1: copype to init workspace
Write-Step "Running copype to initialize $WorkDir ($Architecture)"
& cmd.exe /c "`"$copypeCmd`" $Architecture `"$WorkDir`""
if ($LASTEXITCODE -ne 0) { throw "copype failed with exit code $LASTEXITCODE" }

$bootWim  = Join-Path $WorkDir 'media\sources\boot.wim'
$mountDir = Join-Path $WorkDir 'mount'
$mediaDir = Join-Path $WorkDir 'media'

if (-not (Test-Path $bootWim)) { throw "Expected boot.wim not found at $bootWim after copype" }
if (-not (Test-Path $mountDir)) { New-Item -ItemType Directory -Path $mountDir -Force | Out-Null }

# Step 2: mount, customize, unmount - wrapped in try/finally so a mid-run
# failure discards rather than commits a half-built image
Write-Step "Mounting boot.wim at $mountDir"
& dism.exe /Mount-Image /ImageFile:$bootWim /Index:1 /MountDir:$mountDir
if ($LASTEXITCODE -ne 0) { throw "DISM /Mount-Image failed (exit $LASTEXITCODE)" }

$committed = $false
try {
    # Step 3: add optional components
    Write-Step "Adding optional components ($($Components.Count) packages + language packs)"
    foreach ($comp in $Components) {
        $cab    = Join-Path $ocsDir "$comp.cab"
        $langCab = Join-Path $ocsDir "en-us\$comp`_en-us.cab"

        if (-not (Test-Path $cab)) {
            Write-Warn "Skipping $comp - cab not found at $cab"
            continue
        }
        & dism.exe /Image:$mountDir /Add-Package /PackagePath:$cab | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to add $comp (exit $LASTEXITCODE)" }

        if (Test-Path $langCab) {
            & dism.exe /Image:$mountDir /Add-Package /PackagePath:$langCab | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed to add $comp lang pack (exit $LASTEXITCODE)" }
        } else {
            Write-Warn "Language pack missing for $comp (not fatal)"
        }
        Write-Ok "Added $comp"
    }

    # Step 4: offline registry tweaks
    Write-Step "Applying offline registry tweaks"
    $offlineHive = Join-Path $mountDir 'Windows\System32\config\SYSTEM'
    if (-not (Test-Path $offlineHive)) { throw "Offline SYSTEM hive not found at $offlineHive" }

    & reg.exe load 'HKLM\WinPE_OFFLINE' $offlineHive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load failed (exit $LASTEXITCODE)" }

    try {
        foreach ($t in $RegTweaks) {
            $regPath = "HKLM\WinPE_OFFLINE\$($t.Path)"
            & reg.exe add $regPath /v $t.Name /t "REG_$($t.Type)" /d $t.Value /f | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "reg add failed for $($t.Name) (exit $LASTEXITCODE)" }
            Write-Ok "Set $regPath\$($t.Name) = $($t.Value)"
        }
    } finally {
        # Drop any lingering handles before unloading
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        & reg.exe unload 'HKLM\WinPE_OFFLINE' | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warn "reg unload returned exit $LASTEXITCODE - may need a reboot to fully release" }
    }

    # Step 5: embed the deploy script
    Write-Step "Embedding deploy script"
    $scriptsDir = Join-Path $mountDir 'scripts'
    New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
    Copy-Item -Path $DeployScript -Destination $scriptsDir -Force
    Write-Ok "Copied $(Split-Path -Leaf $DeployScript) to X:\scripts\"

    # Step 5b: embed CCTK (optional)
    if ($cctkExe) {
        Write-Step "Embedding CCTK (source: $CctkSource)"
        $cctkDest = Join-Path $mountDir 'cctk'
        New-Item -ItemType Directory -Path $cctkDest -Force | Out-Null
        # Copy the directory that contains cctk.exe (architecture-matched preferred)
        $cctkSrcDir = $cctkExe.DirectoryName
        Copy-Item -Path (Join-Path $cctkSrcDir '*') -Destination $cctkDest -Recurse -Force
        Write-Ok "Copied CCTK ($cctkSrcDir) to X:\cctk\"

        if ($hapiInf) {
            Write-Step "Installing HAPI driver into offline image ($($hapiInf.Name))"
            & dism.exe /Image:$mountDir /Add-Driver /Driver:$($hapiInf.FullName) /ForceUnsigned | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "HAPI driver install failed (exit $LASTEXITCODE) - required for CCTK to talk to BIOS in WinPE"
            }
            Write-Ok "HAPI driver installed"
        }
    }

    # Step 6: write startnet.cmd
    Write-Step "Writing startnet.cmd"
    $startnetPath = Join-Path $mountDir 'Windows\System32\startnet.cmd'
    # Keep this in sync with docs/USB_SETUP.md - it looks up the data
    # partition by volume label "IMAGES" and exposes it as DEPLOY_IMAGE_DRIVE
    # so the deploy script skips a full scan.
    $startnet = @'
@echo off
wpeinit
setlocal enabledelayedexpansion
ping -n 4 127.0.0.1 >nul
set DEPLOY_IMAGE_DRIVE=
for %%d in (D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    vol %%d: 2>nul | find /i "IMAGES" >nul 2>&1
    if !ERRORLEVEL! equ 0 (
        set "DEPLOY_IMAGE_DRIVE=%%d:"
        goto :found
    )
)
echo No drive with label "IMAGES" found - script will scan all drives.
goto :launch
:found
echo Found image drive: %DEPLOY_IMAGE_DRIVE%
:launch
:: Optional per-USB args file. One line of PowerShell parameters; lets
:: operators retarget a USB without rebuilding boot.wim. See docs/DEPLOY_ARGS.md.
set "DEPLOYARGS="
if defined DEPLOY_IMAGE_DRIVE (
    if exist "%DEPLOY_IMAGE_DRIVE%\deploy.args" (
        set /p DEPLOYARGS=<"%DEPLOY_IMAGE_DRIVE%\deploy.args"
        echo Loaded deploy args from %DEPLOY_IMAGE_DRIVE%\deploy.args
        echo   Parameters loaded. Secrets, if present, are not displayed.
    )
)
:: Replace {DRIVE} placeholder with the actual image-drive letter.
:: build_iso.ps1 uses this so deploy.args paths work regardless of
:: which drive letter WinPE assigns the USB.
if defined DEPLOY_IMAGE_DRIVE (
    if defined DEPLOYARGS (
        set "DEPLOYARGS=!DEPLOYARGS:{DRIVE}=%DEPLOY_IMAGE_DRIVE%!"
    )
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\scripts\unified_winpe_deploy.ps1 !DEPLOYARGS!
'@
    Set-Content -Path $startnetPath -Value $startnet -Encoding ASCII -Force
    Write-Ok "Wrote startnet.cmd"

    # Step 7: commit
    Write-Step "Unmounting with /commit (this rewrites the WIM - can take a few minutes)"
    & dism.exe /Unmount-Image /MountDir:$mountDir /Commit
    if ($LASTEXITCODE -ne 0) { throw "DISM /Unmount-Image /Commit failed (exit $LASTEXITCODE)" }
    $committed = $true
    Write-Ok "boot.wim committed"
} finally {
    if (-not $committed) {
        Write-Err "Build failed - discarding mount"
        & dism.exe /Unmount-Image /MountDir:$mountDir /Discard 2>&1 | Out-Null
    }
}

# Step 8: optionally copy to USB
if ($UsbDrive) {
    Write-Step "Copying WinPE media to $UsbDrive"
    & xcopy.exe /s /e /y "$mediaDir\*.*" "$UsbDrive\"
    if ($LASTEXITCODE -ne 0) { throw "xcopy to $UsbDrive failed (exit $LASTEXITCODE)" }
    Write-Ok "Media copied to $UsbDrive"

    if ($ReleaseUsbLetter) {
        Write-Step "Releasing drive letter $UsbDrive"
        & mountvol.exe $UsbDrive /d
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "mountvol /d returned $LASTEXITCODE - remove the letter manually if needed"
        } else {
            Write-Ok "$UsbDrive released - WinPE boot partition is no longer visible in Explorer"
        }
    }
}

Write-Host ""
Write-Host "Build complete." -ForegroundColor Green
Write-Host "  boot.wim: $bootWim"
Write-Host "  media:    $mediaDir"
if (-not $UsbDrive) {
    Write-Host ""
    Write-Host "To write to a pre-partitioned USB boot partition (see docs/USB_SETUP.md Step 4):"
    Write-Host "  xcopy /s /e /y `"$mediaDir\*.*`" P:\"
    Write-Host "  mountvol P: /d   (optional - hides the boot partition from Explorer)"
}
