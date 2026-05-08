#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prepare a customized Windows install.wim for deployment.

.DESCRIPTION
    Companion to unified_winpe_deploy.ps1. Takes a stock Windows ISO,
    extracts install.wim, picks the requested edition, debloats provisioned
    AppX packages using a whitelist, optionally applies offline registry
    tweaks, and re-exports the result as a clean WIM ready to drop on the
    USB IMAGES partition.

    Whitelist-based debloat is intentional - blacklist approaches miss new
    bloat that Microsoft adds in each release. Edit -Whitelist (or pass
    -WhitelistFile) to suit your environment.

    All mounts wrap in try/finally and discard on mid-script failure rather
    than leaving an orphaned mount.

.PARAMETER SourceIso
    Path to the Windows installation ISO (the one with sources\install.wim).
    Required.

.PARAMETER OutputWim
    Where to write the customized WIM. Required.

.PARAMETER Edition
    Edition name as DISM reports it - e.g. 'Windows 11 Enterprise',
    'Windows 11 Pro'. Default: 'Windows 11 Enterprise'. Run
    `Get-WindowsImage -ImagePath <install.wim>` to see available names.

.PARAMETER WorkDir
    Temporary working directory for ISO mount, WIM mount, and scratch.
    Default: C:\WimPrep. Created if missing, NOT deleted afterwards
    (re-runnable, easier to debug failures).

.PARAMETER Whitelist
    Array of provisioned AppX package DisplayNames to KEEP. Anything not
    in this list gets removed. Default is a sane Microsoft set (Photos,
    Calculator, Notepad, Store, Terminal, Camera, security health, codecs).

.PARAMETER WhitelistFile
    Path to a text file with one DisplayName per line. Overrides -Whitelist.
    Lines starting with # are treated as comments. Useful for keeping the
    whitelist in source control separately from this script.

.PARAMETER DisableCopilot
    Apply the offline registry tweak to disable Windows Copilot via policy
    (`HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot\TurnOffWindowsCopilot=1`).

.PARAMETER NoCleanup
    Skip dismount-discard on the cleanup paths. Mainly for debugging stuck
    mounts. Default off.

.EXAMPLE
    # Prep a Win11 Enterprise WIM with the default whitelist + Copilot off
    .\scripts\prepare_wim.ps1 `
        -SourceIso 'D:\iso\Win11_24H2_English_x64.iso' `
        -OutputWim 'E:\images\Win11_24h2_Enterprise_Custom.wim' `
        -DisableCopilot

.EXAMPLE
    # Prep with custom whitelist file
    .\scripts\prepare_wim.ps1 `
        -SourceIso 'D:\iso\Win11.iso' `
        -OutputWim 'E:\images\Win11_Custom.wim' `
        -WhitelistFile 'C:\configs\my_whitelist.txt'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SourceIso,
    [Parameter(Mandatory)] [string]$OutputWim,
    [string]$Edition = 'Windows 11 Enterprise',
    [string]$WorkDir = 'C:\WimPrep',
    [string[]]$Whitelist = @(
        # Codecs and image/video extensions (apps without these break on consumer hardware)
        'Microsoft.AV1VideoExtension'
        'Microsoft.AVCEncoderVideoExtension'
        'Microsoft.HEIFImageExtension'
        'Microsoft.HEVCVideoExtension'
        'Microsoft.MPEG2VideoExtension'
        'Microsoft.RawImageExtension'
        'Microsoft.VP9VideoExtensions'
        'Microsoft.WebMediaExtensions'
        'Microsoft.WebpImageExtension'
        # Core utilities most users actually use
        'Microsoft.DesktopAppInstaller'
        'Microsoft.GetHelp'
        'Microsoft.ScreenSketch'
        'Microsoft.SecHealthUI'
        'Microsoft.StorePurchaseApp'
        'Microsoft.Windows.Photos'
        'Microsoft.WindowsAlarms'
        'Microsoft.WindowsCalculator'
        'Microsoft.WindowsCamera'
        'Microsoft.WindowsNotepad'
        'Microsoft.WindowsSoundRecorder'
        'Microsoft.WindowsStore'
        'Microsoft.WindowsTerminal'
        'Microsoft.ApplicationCompatibilityEnhancements'
        'MicrosoftWindows.Client.WebExperience'
    ),
    [string]$WhitelistFile,
    [switch]$DisableCopilot,
    [switch]$NoCleanup
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host "[prep] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[ ok ] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[warn] $m" -ForegroundColor Yellow }

# Validate inputs
if (-not (Test-Path $SourceIso -PathType Leaf)) {
    throw "SourceIso not found: $SourceIso"
}
$SourceIso = (Resolve-Path $SourceIso).Path

$outputDir = Split-Path -Parent $OutputWim
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Load whitelist from file if given
if ($WhitelistFile) {
    if (-not (Test-Path $WhitelistFile -PathType Leaf)) {
        throw "WhitelistFile not found: $WhitelistFile"
    }
    $Whitelist = Get-Content $WhitelistFile |
        Where-Object { $_ -and $_ -notmatch '^\s*#' } |
        ForEach-Object { $_.Trim() }
    Write-Step "Loaded $($Whitelist.Count) whitelist entries from $WhitelistFile"
}

# Working paths
$mountDir   = Join-Path $WorkDir 'wimmount'
$scratchDir = Join-Path $WorkDir 'scratch'
$baseWim    = Join-Path $WorkDir 'install_base.wim'
foreach ($d in @($WorkDir, $mountDir, $scratchDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# Step 1: mount ISO, extract install.wim, dismount ISO (try/finally)
Write-Step "Mounting ISO: $SourceIso"
$isoMounted = $false
try {
    $diskImage = Mount-DiskImage -ImagePath $SourceIso -PassThru
    $isoMounted = $true
    Start-Sleep -Seconds 2  # Give the volume time to surface
    $isoVolume = Get-DiskImage -ImagePath $SourceIso | Get-Volume
    if (-not $isoVolume.DriveLetter) {
        throw "ISO mounted but no drive letter assigned"
    }
    $isoDrive = "$($isoVolume.DriveLetter):"
    Write-Ok "ISO mounted at $isoDrive"

    $isoWim = Join-Path $isoDrive 'sources\install.wim'
    $isoEsd = Join-Path $isoDrive 'sources\install.esd'

    if (Test-Path $isoWim) {
        Copy-Item -Path $isoWim -Destination $baseWim -Force
        Write-Ok "Copied install.wim to $baseWim"
    } elseif (Test-Path $isoEsd) {
        # Some retail ISOs ship an ESD - export the requested edition out
        Write-Step "ISO has install.esd (not .wim) - converting via Export-WindowsImage"
        $esdImages = Get-WindowsImage -ImagePath $isoEsd
        $esdMatch = $esdImages | Where-Object { $_.ImageName -eq $Edition } | Select-Object -First 1
        if (-not $esdMatch) {
            $available = ($esdImages.ImageName -join ', ')
            throw "Edition '$Edition' not found in install.esd. Available: $available"
        }
        Export-WindowsImage -SourceImagePath $isoEsd -SourceIndex $esdMatch.ImageIndex `
            -DestinationImagePath $baseWim -DestinationName $Edition `
            -ScratchDirectory $scratchDir -CheckIntegrity | Out-Null
        Write-Ok "Exported $Edition from install.esd"
    } else {
        throw "Neither sources\install.wim nor install.esd found on ISO"
    }
} finally {
    if ($isoMounted) {
        try {
            Dismount-DiskImage -ImagePath $SourceIso | Out-Null
            Write-Ok "ISO dismounted"
        } catch {
            Write-Warn "ISO dismount failed (non-fatal): $($_.Exception.Message)"
        }
    }
}

# Step 2: identify the edition index in the base WIM
Write-Step "Inspecting $baseWim"
$baseImages = Get-WindowsImage -ImagePath $baseWim
$target = $baseImages | Where-Object { $_.ImageName -eq $Edition } | Select-Object -First 1
if (-not $target) {
    $available = ($baseImages.ImageName -join ', ')
    throw "Edition '$Edition' not found in $baseWim. Available: $available"
}
Write-Ok "Found '$Edition' at index $($target.ImageIndex)"

# Step 3: mount the WIM, debloat, optionally tweak registry, dismount /save (try/finally)
Write-Step "Mounting WIM index $($target.ImageIndex) at $mountDir"
$wimMounted = $false
$saveMount = $false  # only set true after successful customization
try {
    Mount-WindowsImage -ImagePath $baseWim -Index $target.ImageIndex -Path $mountDir | Out-Null
    $wimMounted = $true
    Write-Ok "WIM mounted"

    Write-Step "Debloating provisioned AppX packages"
    $packages = Get-AppxProvisionedPackage -Path $mountDir
    $kept = 0
    $removed = 0
    foreach ($pkg in $packages) {
        if ($Whitelist -contains $pkg.DisplayName) {
            $kept++
            continue
        }
        try {
            Remove-AppxProvisionedPackage -Path $mountDir -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
            $removed++
            Write-Host "  removed: $($pkg.DisplayName)" -ForegroundColor DarkGray
        } catch {
            # Fail loud - if a package can't be removed we want to know.
            # The deploy script's whole philosophy is "fail loud" and this script honors that.
            throw "Failed to remove $($pkg.DisplayName): $($_.Exception.Message)"
        }
    }
    Write-Ok "Debloat complete: $kept kept, $removed removed"

    if ($DisableCopilot) {
        Write-Step "Applying Copilot disable registry tweak"
        $softwareHive = Join-Path $mountDir 'Windows\System32\config\SOFTWARE'
        if (-not (Test-Path $softwareHive)) {
            throw "Offline SOFTWARE hive not found at $softwareHive"
        }
        $hiveKey = 'HKLM\WimPrepSoftware'
        & reg.exe load $hiveKey $softwareHive | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "reg load failed (exit $LASTEXITCODE)" }
        try {
            $copilotKey = "$hiveKey\Policies\Microsoft\Windows\WindowsCopilot"
            & reg.exe add $copilotKey /f | Out-Null
            & reg.exe add $copilotKey /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "reg add TurnOffWindowsCopilot failed (exit $LASTEXITCODE)" }
            Write-Ok "Copilot disabled via policy"
        } finally {
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            & reg.exe unload $hiveKey | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Warn "reg unload returned $LASTEXITCODE - may need a reboot" }
        }
    }

    $saveMount = $true
} finally {
    if ($wimMounted) {
        if ($saveMount) {
            Write-Step "Committing WIM (save + verify)"
            Dismount-WindowsImage -Path $mountDir -Save -CheckIntegrity | Out-Null
            Write-Ok "WIM committed"
        } elseif (-not $NoCleanup) {
            Write-Warn "Customization failed - discarding WIM mount"
            Dismount-WindowsImage -Path $mountDir -Discard | Out-Null
        }
    }
}

# Step 4: re-export with /Compress:max so the output is the cleanest version of just the customized index
Write-Step "Re-exporting customized WIM to $OutputWim (max compression)"
if (Test-Path $OutputWim) { Remove-Item $OutputWim -Force }
Export-WindowsImage -SourceImagePath $baseWim -SourceIndex $target.ImageIndex `
    -DestinationImagePath $OutputWim -DestinationName "$Edition (Custom)" `
    -ScratchDirectory $scratchDir -CheckIntegrity -CompressionType Max | Out-Null

$finalSizeGB = [Math]::Round((Get-Item $OutputWim).Length / 1GB, 2)
Write-Ok "Wrote $OutputWim ($finalSizeGB GB)"

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "  Input:  $SourceIso"
Write-Host "  Output: $OutputWim"
Write-Host ""
Write-Host "Next: copy the WIM to your USB IMAGES partition under \images\"
Write-Host "      then boot a target host with the WinPE USB to deploy."
