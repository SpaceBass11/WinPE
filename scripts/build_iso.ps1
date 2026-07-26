#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Package WinPE + a prepared WIM into a single bootable ISO for end-user distribution.

.DESCRIPTION
    Combines an existing WinPE media tree (output of build_boot_wim.ps1) with a
    prepared Windows WIM (output of prepare_wim.ps1) into one self-contained,
    bootable ISO file. Users download the ISO, flash it to a USB with Rufus, and
    boot the target laptop — no IT knowledge required beyond that.

    The ISO is labeled "IMAGES" so the embedded startnet.cmd finds it
    automatically on boot. A deploy.args file is generated in the ISO root with
    paths expressed as {DRIVE}\... — startnet.cmd substitutes the real drive
    letter at boot time (see docs/DEPLOY_ARGS.md).

    Requires oscdimg.exe from the Windows ADK Deployment Tools.

.PARAMETER WimFile
    Path to the prepared Windows WIM or ESD to embed. Produced by prepare_wim.ps1.
    Must be a single-index WIM for silent deployment (the -Silent validation in
    unified_winpe_deploy.ps1 enforces this at runtime).

.PARAMETER OutputIso
    Full path for the output ISO file. Created or overwritten.

.PARAMETER MediaDir
    Path to the WinPE media directory built by build_boot_wim.ps1.
    Must contain sources\boot.wim, boot\etfsboot.com, and
    efi\microsoft\boot\efisys.bin. Default: C:\WinPE_Build\media

.PARAMETER UnattendFile
    Optional path to an unattend.xml answer file. When given, it is staged at
    configs\unattend.xml inside the ISO and referenced in the generated
    deploy.args so Windows Setup processes it on first boot.

.PARAMETER TargetDisk
    Disk number the deploy script will target on the end-user machine.
    Default 0 (first disk). Only used when -Interactive is not set.

.PARAMETER BitLockerPin
    If set, the generated deploy.args enables BitLocker with this PIN.
    PIN content is the admin's call - no placeholder or length policy
    is enforced here; the deploy script enforces only Windows' 6-20
    char window at runtime. Security note: the PIN is stored in
    plaintext in the ISO/on the USB - the USB is the trust boundary.
    Use a unique PIN per USB.

.PARAMETER DataDiskNumber
    Disk number of a secondary data drive to wipe and format as D:.
    Default -1 (disabled). Only used when -Interactive is not set.
    Requires -BitLockerPin to enable BitLocker on D: as well.

.PARAMETER WipeDisks
    Comma-separated disk numbers to clean alongside the primary target disk.
    Passed through to deploy.args. Example: "1,2". Only used when
    -Interactive is not set.

.PARAMETER Interactive
    When set, the generated deploy.args only pre-sets -ImagePath so the
    deploy script auto-discovers the WIM but still prompts the user for
    edition, target disk, and confirmations. Useful for lab/testing USBs
    where you want the TUI. When not set, a fully silent destructive
    deploy.args is generated and -ConfirmSilentDestructiveIso must be
    passed to acknowledge that.

.PARAMETER ConfirmSilentDestructiveIso
    Required acknowledgement when neither -Interactive is set. The
    silent deploy.args writes -TargetDisk N -Force -Silent, so anyone
    who boots the resulting ISO wipes whichever physical disk Windows
    enumerates as N on their hardware, with no operator confirmation.
    Pass this switch to confirm that is the intended outcome. Without
    it, the script throws before any file copy.

.PARAMETER AdkPath
    Override ADK install root. Default:
    C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit

.PARAMETER Architecture
    Architecture of the ADK tools to use for oscdimg path resolution.
    Default: amd64.

.PARAMETER VolumeLabel
    ISO volume label. Must match what startnet.cmd scans for ("IMAGES").
    Change only if you also rebuild boot.wim with a matching label.
    Default: IMAGES

.PARAMETER WorkDir
    Staging directory for ISO assembly. Created if missing.
    Default: C:\WinPE_ISOBuild

.PARAMETER Clean
    Delete WorkDir before starting for a guaranteed-fresh build.

.EXAMPLE
    # Minimal: WinPE media + WIM -> single silent ISO (disk 0, no BitLocker).
    # -ConfirmSilentDestructiveIso is required to acknowledge that the
    # resulting ISO wipes disk 0 with no operator prompt.
    .\scripts\build_iso.ps1 `
        -WimFile 'I:\images\Win11_Pro_Custom.wim' `
        -OutputIso 'D:\release\Win11_Deploy.iso' `
        -ConfirmSilentDestructiveIso

.EXAMPLE
    # With unattend (account creation, OOBE skip) and BitLocker
    .\scripts\build_iso.ps1 `
        -WimFile    'I:\images\Win11_Pro_Custom.wim' `
        -OutputIso  'D:\release\Win11_Deploy.iso' `
        -UnattendFile 'I:\configs\unattend.xml' `
        -BitLockerPin 'Acme2025#7' `
        -ConfirmSilentDestructiveIso

.EXAMPLE
    # Interactive ISO: TUI prompts the operator, WIM pre-located for them.
    # No -ConfirmSilentDestructiveIso needed - the operator sees prompts.
    .\scripts\build_iso.ps1 `
        -WimFile   'I:\images\Win11_Pro_Custom.wim' `
        -OutputIso 'D:\release\Win11_Deploy_Interactive.iso' `
        -Interactive

.EXAMPLE
    # Non-default WinPE media dir and ADK path
    .\scripts\build_iso.ps1 `
        -WimFile   'I:\images\Win11_Pro_Custom.wim' `
        -OutputIso 'D:\release\Win11_Deploy.iso' `
        -MediaDir  'E:\MyWinPEBuild\media' `
        -AdkPath   'D:\ADK' `
        -ConfirmSilentDestructiveIso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$WimFile,
    [Parameter(Mandatory)] [string]$OutputIso,
    [string]$MediaDir = 'C:\WinPE_Build\media',
    [string]$UnattendFile,
    [int]$TargetDisk = 0,
    [string]$BitLockerPin,
    [int]$DataDiskNumber = -1,
    [string]$WipeDisks,
    [switch]$Interactive,
    [switch]$ConfirmSilentDestructiveIso,
    [string]$AdkPath = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit',
    [ValidateSet('amd64','x86','arm64')]
    [string]$Architecture = 'amd64',
    [string]$VolumeLabel = 'IMAGES',
    [string]$WorkDir = 'C:\WinPE_ISOBuild',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host "[iso] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[ ok] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[wrn] $m" -ForegroundColor Yellow }

# --- Destructive-intent gate ---
# Without -Interactive, the generated deploy.args contains -Force -Silent
# and a fixed -TargetDisk. The resulting ISO wipes whichever physical
# disk Windows enumerates as $TargetDisk on the end-user's hardware,
# with NO operator confirmation. Require explicit acknowledgement so a
# non-IT user flashing the ISO can't trigger this by accident, and so
# nobody runs the builder with default flags and gets a silent wiper.
if (-not $Interactive -and -not $ConfirmSilentDestructiveIso) {
    throw @"
build_iso.ps1 would generate a fully silent disk-wiping ISO:
  -TargetDisk $TargetDisk -Force -Silent
Anyone who boots the resulting ISO wipes whichever physical disk
Windows enumerates as $TargetDisk on their hardware, with NO operator
confirmation. To proceed, re-run with one of:
  -Interactive                         (TUI prompts on deploy)
  -ConfirmSilentDestructiveIso         (silent + destructive, intended)
"@
}

# --- Input validation ---

if (-not (Test-Path $WimFile -PathType Leaf)) {
    throw "WimFile not found: $WimFile"
}
if ([IO.Path]::GetExtension($WimFile) -notin '.wim','.esd') {
    throw "WimFile must have a .wim or .esd extension (got: $WimFile)"
}
$WimFile = (Resolve-Path $WimFile).Path

if (-not (Test-Path $MediaDir -PathType Container)) {
    throw "MediaDir not found: $MediaDir`nRun build_boot_wim.ps1 first (default output: C:\WinPE_Build\media)."
}
$bootWimPath  = Join-Path $MediaDir 'sources\boot.wim'
$etfsbootPath = Join-Path $MediaDir 'boot\etfsboot.com'
$efisysPath   = Join-Path $MediaDir 'efi\microsoft\boot\efisys.bin'
foreach ($f in $bootWimPath, $etfsbootPath, $efisysPath) {
    if (-not (Test-Path $f)) {
        throw "Expected WinPE file not found: $f`nVerify MediaDir ($MediaDir) is the output of build_boot_wim.ps1."
    }
}
$MediaDir = (Resolve-Path $MediaDir).Path

if ($UnattendFile) {
    if (-not (Test-Path $UnattendFile -PathType Leaf)) {
        throw "UnattendFile not found: $UnattendFile"
    }
    $UnattendFile = (Resolve-Path $UnattendFile).Path
}

if ($BitLockerPin) {
    # Fail fast on a PIN outside the Windows Enhanced-PIN 6-20 window.
    # Without this, a malformed PIN is baked into deploy.args on the
    # ISO, distributed, and only rejected by unified_winpe_deploy.ps1
    # at pre-flight on the target. The length is echoed but the PIN
    # itself is not, mirroring PR #236's redaction of the console echo.
    if ($BitLockerPin.Length -lt 6 -or $BitLockerPin.Length -gt 20) {
        throw "BitLockerPin must be 6-20 characters (Windows Enhanced PIN policy). Got: $($BitLockerPin.Length) character(s)."
    }
    if (-not $UnattendFile -and -not $Interactive) {
        Write-Warn "BitLocker PIN set but no UnattendFile given. First-boot will pause for manual setup steps."
    }
}

# Resolve output directory
$outputDir = Split-Path -Parent $OutputIso
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Find oscdimg.exe
$oscdimgPath = Join-Path $AdkPath "Deployment Tools\$Architecture\Oscdimg\oscdimg.exe"
if (-not (Test-Path $oscdimgPath)) {
    # Also try the flat Oscdimg dir (some ADK versions)
    $oscdimgPath = Join-Path $AdkPath "Deployment Tools\Oscdimg\oscdimg.exe"
}
if (-not (Test-Path $oscdimgPath)) {
    throw "oscdimg.exe not found at expected ADK path.`nInstall the Windows ADK Deployment Tools, or pass -AdkPath.`nSearched: $(Join-Path $AdkPath "Deployment Tools\$Architecture\Oscdimg\oscdimg.exe")"
}
Write-Ok "Found oscdimg at $oscdimgPath"

# --- Staging ---

if ($Clean -and (Test-Path $WorkDir)) {
    Write-Step "Removing existing staging dir $WorkDir"
    Remove-Item $WorkDir -Recurse -Force
}

$stagingDir = Join-Path $WorkDir 'staging'
if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

Write-Step "Copying WinPE media to staging"
# Robocopy gives us a clean recursive copy without needing xcopy flags
& robocopy.exe $MediaDir $stagingDir /e /nfl /ndl /njh /njs | Out-Null
# robocopy exits 1 for "files copied, no errors" — that is success
if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed copying WinPE media (exit $LASTEXITCODE)"
}
Write-Ok "WinPE media staged"

# Copy WIM to staging\images\
$imagesDir = Join-Path $stagingDir 'images'
New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
$wimBaseName = Split-Path -Leaf $WimFile
Write-Step "Copying WIM ($wimBaseName) to images\ (this may take a moment for large WIMs)"
Copy-Item -Path $WimFile -Destination (Join-Path $imagesDir $wimBaseName) -Force
$wimSizeGB = [math]::Round((Get-Item $WimFile).Length / 1GB, 1)
Write-Ok "WIM staged ($wimSizeGB GB)"

# Copy UnattendFile to staging\configs\
$unattendInIso = $null
if ($UnattendFile) {
    $configsDir = Join-Path $stagingDir 'configs'
    New-Item -ItemType Directory -Path $configsDir -Force | Out-Null
    $unattendBaseName = Split-Path -Leaf $UnattendFile
    Copy-Item -Path $UnattendFile -Destination (Join-Path $configsDir $unattendBaseName) -Force
    $unattendInIso = "{DRIVE}\configs\$unattendBaseName"
    Write-Ok "Unattend file staged (configs\$unattendBaseName)"
}

# --- Generate deploy.args ---

$deployArgsPath = Join-Path $stagingDir 'deploy.args'

if ($Interactive) {
    # Pre-locate the WIM dir so the TUI doesn't scan all drives,
    # but leave edition / disk / confirmations to the operator.
    $argsLine = "-ImagePath `"{DRIVE}\images`""
    Write-Step "Generating interactive deploy.args (TUI mode)"
} else {
    # Fully silent: boot -> deploy -> done, no prompts
    $argsLine = "-WimFile `"{DRIVE}\images\$wimBaseName`" -TargetDisk $TargetDisk -Force -Silent"

    if ($unattendInIso) {
        $argsLine += " -UnattendFile `"$unattendInIso`""
    }

    if ($WipeDisks) {
        # Validate format before embedding
        if ($WipeDisks -notmatch '^\s*\d+(\s*,\s*\d+)*\s*$') {
            throw "-WipeDisks must be comma-separated disk numbers (e.g. '1,2'). Got: '$WipeDisks'"
        }
        $argsLine += " -WipeDisks `"$WipeDisks`""
    }

    if ($DataDiskNumber -ge 0) {
        $argsLine += " -DataDiskNumber $DataDiskNumber"
    }

    if ($BitLockerPin) {
        $argsLine += " -EnableBitLocker -BitLockerPin `"$BitLockerPin`""
    }

    Write-Step "Generating silent deploy.args"
}

Set-Content -Path $deployArgsPath -Value $argsLine -Encoding ASCII -Force
Write-Ok "deploy.args written"
Write-Host "  $argsLine" -ForegroundColor DarkGray

# --- Run oscdimg ---

$etfsboot = Join-Path $stagingDir 'boot\etfsboot.com'
$efisys   = Join-Path $stagingDir 'efi\microsoft\boot\efisys.bin'

# -m    : ignore maximum image size (allows images > 650 MB)
# -o    : optimise storage (single-instance identical files)
# -u2   : produce UDF 2.01 file system
# -udfver102 : also include UDF 1.02 for older firmware
# -bootdata : BIOS boot sector + UEFI boot sector
# -l    : volume label (must match what startnet.cmd scans for)
$bootData = "2#p0,e,b`"$etfsboot`"#pEF,e,b`"$efisys`""
$oscdimgArgs = @(
    '-m', '-o', '-u2', '-udfver102',
    "-bootdata:$bootData",
    "-l$VolumeLabel",
    $stagingDir,
    $OutputIso
)

Write-Step "Running oscdimg to produce ISO"
Write-Host "  Output: $OutputIso" -ForegroundColor DarkGray
& $oscdimgPath @oscdimgArgs
if ($LASTEXITCODE -ne 0) {
    throw "oscdimg failed with exit code $LASTEXITCODE"
}

$isoSizeGB = [math]::Round((Get-Item $OutputIso).Length / 1GB, 2)
Write-Ok "ISO created ($isoSizeGB GB)"

# --- Summary ---

Write-Host ""
Write-Host "Build complete." -ForegroundColor Green
Write-Host "  ISO:   $OutputIso ($isoSizeGB GB)"
Write-Host "  WIM:   $wimBaseName ($wimSizeGB GB embedded)"
if ($Interactive) {
    Write-Host "  Mode:  Interactive TUI (operator selects edition and target disk)"
} else {
    Write-Host "  Mode:  Silent (boots and deploys automatically to disk $TargetDisk)"
}
if ($UnattendFile) { Write-Host "  Unattend: $UnattendFile" }
if ($BitLockerPin) { Write-Host "  BitLocker: enabled (PIN embedded in deploy.args on ISO)" }
Write-Host ""
Write-Host "End-user steps (see docs/END_USER_DEPLOY.md):" -ForegroundColor Yellow
Write-Host "  1. Send the user the ISO file."
Write-Host "  2. User flashes it to a USB (8 GB+) with Rufus."
Write-Host "  3. User boots the target laptop from USB."
if ($Interactive) {
    Write-Host "  4. User follows the on-screen TUI prompts."
} else {
    Write-Host "  4. Deployment runs automatically. Laptop reboots when done."
}
