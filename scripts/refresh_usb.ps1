#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Refresh a WinPE USB stick with a new Windows ISO.

.DESCRIPTION
    Wrapper around prepare_wim.ps1 (and optionally build_boot_wim.ps1)
    for the recurring "Microsoft dropped new media, get it on my USB"
    workflow.

    Saves you from:
      - Typing out the OutputWim path (auto-derived from ISO filename)
      - Forgetting whether you also need to rebuild boot.wim
      - Hunting for the prepare_wim flags every time

    All actual work is delegated to the underlying scripts; this only
    glues them together with friendlier defaults.

    Run on the admin workstation. USB IMAGES partition should already
    be letter-assigned (default I:\). If -RebuildBootWim is requested,
    run from the ADK "Deployment and Imaging Tools Environment" (the
    script checks and warns if copype isn't on PATH).

.PARAMETER SourceIso
    Path to the Windows ISO. Required.

.PARAMETER OutputName
    Basename for the resulting WIM (no extension, no path). Defaults
    to the ISO filename minus its extension, e.g.
    'Win11_24H2_English_x64.iso' becomes 'Win11_24H2_English_x64.wim'.

.PARAMETER ImagesPath
    Directory where the resulting WIM is placed. Default: 'I:\images'.

.PARAMETER DriverPath
    Passthrough to prepare_wim.ps1 -DriverPath. Optional folder of
    .inf driver packages to pre-bake into the image.

.PARAMETER WhitelistFile
    Passthrough to prepare_wim.ps1 -WhitelistFile. Custom AppX
    whitelist text file (one DisplayName per line).

.PARAMETER DisableCopilot
    Passthrough to prepare_wim.ps1 -DisableCopilot.

.PARAMETER RebuildBootWim
    'Yes' to also rebuild WinPE boot.wim on the boot partition.
    'No' to skip. 'Ask' (default) prompts interactively. Most refreshes
    are image-only (you don't need to rebuild WinPE every time
    Microsoft drops new install media).

.PARAMETER BootUsbDrive
    Used only when -RebuildBootWim. Default: 'P:'.

.PARAMETER CctkSource
    Used only when -RebuildBootWim. Optional path to Dell CCTK to
    embed in boot.wim. See docs/CCTK.md.

.EXAMPLE
    # Simplest case: new ISO, refresh just the image
    .\scripts\refresh_usb.ps1 -SourceIso 'D:\iso\Win11_24H2.iso'

.EXAMPLE
    # Drivers + Copilot disabled
    .\scripts\refresh_usb.ps1 `
        -SourceIso 'D:\iso\Win11_24H2.iso' `
        -DriverPath 'C:\Drivers\Dell' `
        -DisableCopilot

.EXAMPLE
    # Refresh both the image AND WinPE boot.wim (run from ADK env)
    .\scripts\refresh_usb.ps1 `
        -SourceIso 'D:\iso\Win11_24H2.iso' `
        -RebuildBootWim Yes

.NOTES
    Lives alongside prepare_wim.ps1 and build_boot_wim.ps1 in scripts/.
    Adds no new behavior — just sequences and defaults.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceIso,

    [string]$OutputName,

    [string]$ImagesPath = 'I:\images',

    [string]$DriverPath,
    [string]$WhitelistFile,
    [switch]$DisableCopilot,

    [ValidateSet('Yes','No','Ask')]
    [string]$RebuildBootWim = 'Ask',

    [string]$BootUsbDrive = 'P:',
    [string]$CctkSource
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host "[refresh] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[  ok   ] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[ warn  ] $m" -ForegroundColor Yellow }

# Inputs
if (-not (Test-Path $SourceIso)) {
    throw "ISO not found: $SourceIso"
}
if (-not (Test-Path $ImagesPath)) {
    throw "ImagesPath not found: $ImagesPath (is the USB IMAGES partition mounted as $ImagesPath ?)"
}

# Derive output name from ISO if not given
if (-not $OutputName) {
    $OutputName = [System.IO.Path]::GetFileNameWithoutExtension($SourceIso)
    Write-Step "Output name derived from ISO: $OutputName"
}
$outputWim = Join-Path $ImagesPath "$OutputName.wim"
Write-Step "Output WIM: $outputWim"

if (Test-Path $outputWim) {
    Write-Warn "Output WIM already exists - prepare_wim.ps1 will overwrite."
}

# Resolve the boot-rebuild question early so the prompt isn't buried
# in the middle of a 20-minute prepare_wim run.
if ($RebuildBootWim -eq 'Ask') {
    $resp = Read-Host "Also rebuild WinPE boot.wim on $BootUsbDrive after the image is ready? (y/N)"
    $RebuildBootWim = if ($resp -match '^y') { 'Yes' } else { 'No' }
}

# Pre-flight the ADK env for the boot rebuild now, so we don't run
# prepare_wim for 20 minutes and then fail.
if ($RebuildBootWim -eq 'Yes') {
    if (-not (Get-Command copype -ErrorAction SilentlyContinue)) {
        throw "-RebuildBootWim requires the ADK 'Deployment and Imaging Tools Environment' (copype not on PATH). Open that as Admin and re-run, or pass -RebuildBootWim No."
    }
}

# Step 1: image prep
$prepArgs = @{
    SourceIso = $SourceIso
    OutputWim = $outputWim
}
if ($DriverPath)    { $prepArgs.DriverPath    = $DriverPath }
if ($WhitelistFile) { $prepArgs.WhitelistFile = $WhitelistFile }
if ($DisableCopilot){ $prepArgs.DisableCopilot = $true }

Write-Step "Invoking prepare_wim.ps1..."
$prepScript = Join-Path $PSScriptRoot 'prepare_wim.ps1'
& $prepScript @prepArgs
if ($LASTEXITCODE -ne 0) {
    throw "prepare_wim.ps1 failed (exit $LASTEXITCODE)"
}
Write-Ok "Image ready at $outputWim"

# Step 2 (optional): WinPE boot.wim rebuild
if ($RebuildBootWim -eq 'Yes') {
    Write-Step "Rebuilding WinPE boot.wim on $BootUsbDrive..."
    $buildArgs = @{
        Clean            = $true
        UsbDrive         = $BootUsbDrive
        ReleaseUsbLetter = $true
    }
    if ($CctkSource) { $buildArgs.CctkSource = $CctkSource }
    $buildScript = Join-Path $PSScriptRoot 'build_boot_wim.ps1'
    & $buildScript @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "build_boot_wim.ps1 failed (exit $LASTEXITCODE)"
    }
    Write-Ok "WinPE boot.wim refreshed on $BootUsbDrive"
}

# Summary so the operator sees the final state
Write-Host ""
Write-Ok "USB refresh complete."
$wims = Get-ChildItem $ImagesPath -Filter '*.wim' -ErrorAction SilentlyContinue
if ($wims) {
    Write-Host "Images now on $ImagesPath :"
    foreach ($w in ($wims | Sort-Object Name)) {
        $sizeGB = [math]::Round($w.Length / 1GB, 1)
        Write-Host ("  {0,-50} {1,6} GB" -f $w.Name, $sizeGB)
    }
}
