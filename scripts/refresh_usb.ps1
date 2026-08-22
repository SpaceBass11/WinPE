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
    Path to the Windows ISO. Use this OR -SourceWim, not both.

.PARAMETER SourceWim
    Path to an already-captured `.wim` (or `.esd`) file. Use this when
    your starting point is a captured reference image rather than a
    stock Windows ISO. Passthrough to `prepare_wim.ps1 -SourceWim`.

.PARAMETER Index
    Numeric image-index to pick from the source. Passthrough to
    `prepare_wim.ps1 -Index`. Useful for captured WIMs that don't use
    standard edition names. Overrides -Edition.

.PARAMETER Edition
    Edition name (as DISM reports it) to pick from the source.
    Passthrough to `prepare_wim.ps1 -Edition`. Default in the underlying
    script is 'Windows 11 Enterprise'.

.PARAMETER OutputName
    Basename for the resulting WIM. Must be a bare filename: no path
    separators, no invalid Windows filename characters, and no trailing
    `.wim`/`.esd` (the extension is appended). Dotted version tokens
    like `Win11.24H2` are fine. Defaults to the source filename minus
    its extension, e.g. `Win11_24H2_English_x64.iso` becomes
    `Win11_24H2_English_x64.wim`.

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

.PARAMETER DisableExtraBloat
    Passthrough to prepare_wim.ps1 -DisableExtraBloat. Superset of
    -DisableCopilot; applies the broader fleet-friendly debloat
    policies.

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

.EXAMPLE
    # Refresh from a captured reference WIM (instead of a stock ISO)
    .\scripts\refresh_usb.ps1 `
        -SourceWim 'C:\captures\golden-image.wim' `
        -Index 1 `
        -DisableExtraBloat

.NOTES
    Lives alongside prepare_wim.ps1 and build_boot_wim.ps1 in scripts/.
    Adds no new behavior — just sequences and defaults.
#>
[CmdletBinding(DefaultParameterSetName='FromIso')]
param(
    [Parameter(Mandatory, ParameterSetName='FromIso')]
    [string]$SourceIso,

    [Parameter(Mandatory, ParameterSetName='FromWim')]
    [string]$SourceWim,

    [int]$Index,
    [string]$Edition,

    [string]$OutputName,

    [string]$ImagesPath = 'I:\images',

    [string]$DriverPath,
    [string]$WhitelistFile,
    [switch]$DisableCopilot,
    [switch]$DisableExtraBloat,

    [ValidateSet('Yes','No','Ask')]
    [string]$RebuildBootWim = 'Ask',

    [string]$BootUsbDrive = 'P:',
    [string]$CctkSource
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host "[refresh] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[  ok   ] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[ warn  ] $m" -ForegroundColor Yellow }

# Resolve which source the operator gave us. Parameter sets guarantee
# exactly one of -SourceIso / -SourceWim is bound.
$fromIso    = $PSCmdlet.ParameterSetName -eq 'FromIso'
$sourcePath = if ($fromIso) { $SourceIso } else { $SourceWim }
$sourceKind = if ($fromIso) { 'ISO' } else { 'WIM' }

# Inputs. Match the -PathType Leaf / Container pattern used by the
# sibling scripts (prepare_wim.ps1, build_iso.ps1, build_boot_wim.ps1)
# so a swapped file/directory argument fails fast here with a clear
# message instead of producing a bogus derived OutputName and then
# bombing further down in prepare_wim.ps1 or Get-ChildItem.
if (-not (Test-Path $sourcePath -PathType Leaf)) {
    throw "$sourceKind not found (or is a directory, not a file): $sourcePath"
}
if (-not (Test-Path $ImagesPath -PathType Container)) {
    throw "ImagesPath not found (or is a file, not a directory): $ImagesPath (is the USB IMAGES partition mounted as $ImagesPath ?)"
}

# Derive output name from the source filename if not given
if (-not $OutputName) {
    $OutputName = [System.IO.Path]::GetFileNameWithoutExtension($sourcePath)
    Write-Step "Output name derived from $sourceKind`: $OutputName"
}
# Reject anything that isn't a bare filename basename. The doc calls this
# out ("no extension, no path"), but silent Join-Path concatenation lets
# 'foo/bar' land inside a nested subdir and lets 'name.wim' produce
# 'name.wim.wim'; both surface as "WIM not found on IMAGES partition" at
# deploy time. Catch it here where the operator can retype it.
if ($OutputName -match '[\\/:*?"<>|]') {
    throw "-OutputName must be a bare filename (no path, no invalid Windows filename characters). Got: '$OutputName'"
}
if ([IO.Path]::GetExtension($OutputName) -in '.wim', '.esd') {
    throw "-OutputName must not include the .wim/.esd extension (it is appended). Got: '$OutputName'"
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

# Pre-flight the ADK env and the boot-USB drive letter for the boot
# rebuild now, so we don't run prepare_wim for 20 minutes and then fail
# on something the operator could have fixed in one second. Format +
# accessibility checks mirror build_boot_wim.ps1's own validation of
# -UsbDrive so we surface the identical error message one stage earlier.
if ($RebuildBootWim -eq 'Yes') {
    if ($BootUsbDrive -notmatch '^[A-Za-z]:$') {
        throw "-BootUsbDrive must be a drive letter like 'P:' (got '$BootUsbDrive')"
    }
    if (-not (Test-Path "$BootUsbDrive\")) {
        throw "Boot USB drive $BootUsbDrive is not accessible - partition and assign the letter per docs/USB_SETUP.md Step 4 first."
    }
    if (-not (Get-Command copype -ErrorAction SilentlyContinue)) {
        throw "-RebuildBootWim requires the ADK 'Deployment and Imaging Tools Environment' (copype not on PATH). Open that as Admin and re-run, or pass -RebuildBootWim No."
    }
}

# Step 1: image prep
$prepArgs = @{
    OutputWim = $outputWim
}
if ($fromIso) { $prepArgs.SourceIso = $SourceIso } else { $prepArgs.SourceWim = $SourceWim }
if ($PSBoundParameters.ContainsKey('Index'))   { $prepArgs.Index   = $Index }
if ($PSBoundParameters.ContainsKey('Edition')) { $prepArgs.Edition = $Edition }
if ($DriverPath)        { $prepArgs.DriverPath        = $DriverPath }
if ($WhitelistFile)     { $prepArgs.WhitelistFile     = $WhitelistFile }
if ($DisableCopilot)    { $prepArgs.DisableCopilot    = $true }
if ($DisableExtraBloat) { $prepArgs.DisableExtraBloat = $true }

Write-Step "Invoking prepare_wim.ps1..."
$prepScript = Join-Path $PSScriptRoot 'prepare_wim.ps1'
# prepare_wim.ps1 signals failure by `throw` under $ErrorActionPreference=Stop,
# which propagates through `& $script` to our own EAP=Stop and terminates. Do
# NOT gate on $LASTEXITCODE here: prepare_wim runs native commands (reg.exe
# unload in particular) whose non-fatal warning paths can leak a non-zero
# $LASTEXITCODE into us after a successful prep, producing a false "failed".
& $prepScript @prepArgs
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
    # Same rationale as the prepare_wim call above: throw propagates;
    # checking $LASTEXITCODE would false-fail on benign native warnings
    # (reg unload, mountvol /d) that leak a non-zero code post-success.
    & $buildScript @buildArgs
    Write-Ok "WinPE boot.wim refreshed on $BootUsbDrive"
}

# Summary so the operator sees the final state.
# List both .wim and .esd files - the deploy script's Find-ImageFiles
# accepts both ($Script:Config.ImageExtensions), so an .esd dropped on the
# IMAGES partition manually (e.g. install.esd lifted from a Windows ISO)
# is just as deployable as a .wim. Showing only .wim here would mislead
# the operator about which images are actually available at boot time.
Write-Host ""
Write-Ok "USB refresh complete."
$images = Get-ChildItem $ImagesPath -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.wim', '.esd' }
if ($images) {
    Write-Host "Images now on $ImagesPath :"
    foreach ($img in ($images | Sort-Object Name)) {
        $sizeGB = [math]::Round($img.Length / 1GB, 1)
        Write-Host ("  {0,-50} {1,6} GB" -f $img.Name, $sizeGB)
    }
}
