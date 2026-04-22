# Script Reference

Complete technical reference for `unified_winpe_deploy.ps1` and the
`scripts/build_boot_wim.ps1` boot media builder.

## Parameters

### -ImagePath [string]
Directory to search for `.wim`/`.esd` files. When provided, the script searches
only this directory (up to 2 levels deep) instead of scanning all drives.

```powershell
.\unified_winpe_deploy.ps1 -ImagePath "D:\images"
```

### -WimFile [string]
Direct path to a specific image file. Bypasses all discovery logic.
The file must exist and use a supported extension (`.wim` or `.esd`).

```powershell
.\unified_winpe_deploy.ps1 -WimFile "D:\images\Win11_Pro.wim"
```

### -TargetDisk [int]
Disk number to deploy to. Pre-selects the disk but still requires typed "ERASE"
confirmation unless combined with `-Force`. Use `diskpart` > `list disk` to find disk numbers.

```powershell
.\unified_winpe_deploy.ps1 -TargetDisk 0            # still asks for confirmation
.\unified_winpe_deploy.ps1 -TargetDisk 0 -Force      # skips confirmation (automation)
```

### -Force [switch]
Skips the "ERASE" confirmation when used with `-TargetDisk`. Without this flag,
`-TargetDisk` pre-selects the disk but still requires typed confirmation.
Also skips the `WIPE ALL` confirmation when `-WipeDisks` is set.

### -WipeDisks [string]
Comma-separated disk numbers to also wipe (clean-only, no repartitioning)
alongside the primary target. Validated against the
`^\s*\d+(\s*,\s*\d+)*\s*$` pattern in silent mode. Requires `-Force` for
unattended runs.

```powershell
.\unified_winpe_deploy.ps1 -TargetDisk 0 -WipeDisks "1,2" -Force
```

### -Silent [switch]
Unattended mode for automation. For deployment runs, it requires:
- `-WimFile` (to avoid interactive image selection)
- `-TargetDisk` (to avoid interactive disk selection)
- `-Force` (to avoid interactive final confirmation)

`-Silent` still does **not** bypass system-disk `DESTROY SYSTEM` confirmation, and it will fail fast when the selected image has multiple indexes (because unattended runs cannot answer the edition prompt).

### -ListOnly [switch]
Discovers and displays all available images non-interactively, then exits without deploying.

## Functions

### Core Functions

| Function | Purpose |
|----------|---------|
| `Write-Log` | Timestamped, color-coded console output |
| `Write-Banner` | Large section headers (80-char wide) |
| `Test-Administrator` | Checks if running as admin |
| `Show-MessageBox` | GUI dialog with console fallback |

### System Discovery

| Function | Purpose |
|----------|---------|
| `Initialize-SystemPaths` | Sets script directory, temp directory, diskpart script path, log file |
| `Find-ImageFiles` | Main image discovery orchestrator |
| `Search-DirectoryForImages` | Scans a directory for .wim/.esd files |
| `Show-ImageList` | Non-interactive image listing used by `-ListOnly` |
| `Show-ImageSelection` | Interactive TUI image picker |

### System Validation

| Function | Purpose |
|----------|---------|
| `Test-WinPEEnvironment` | Validates WinPE environment, blocks non-WinPE unless confirmed |
| `Test-SystemMemory` | Validates 8GB+ RAM with warning dialog |

### Disk Management

| Function | Purpose |
|----------|---------|
| `Get-SystemDisks` | Enumerates fixed (non-USB) disks via WMI, logs skipped USB drives |
| `Show-DiskMenu` | Color-coded disk selection display |
| `Select-TargetDisk` | Interactive disk picker with safety confirmations |
| `Select-AdditionalWipeDisks` | Optional menu for extra disks to clean (streamlined single `WIPE ALL` confirmation) |

### BIOS Configuration

| Function | Purpose |
|----------|---------|
| `Invoke-CctkConfig` | Pre-apply Dell CCTK BIOS config (service tag → model → default precedence). See [CCTK.md](CCTK.md) |

### Image Index Selection

| Function | Purpose |
|----------|---------|
| `Get-WimImageInfo` | Reads WIM indexes (editions) via DISM /Get-WimInfo |
| `Select-ImageIndex` | Interactive edition picker for multi-index WIMs |

### Image Deployment

| Function | Purpose |
|----------|---------|
| `New-DiskpartScript` | Generates GPT partition script, frees C:/S: drive letters |
| `Invoke-Diskpart` | Executes diskpart with generated script |
| `Apply-WindowsImage` | Runs DISM /apply-image |
| `Set-BootConfiguration` | Runs bcdboot.exe for UEFI |

### Main Orchestrator

| Function | Purpose |
|----------|---------|
| `Start-Deployment` | Orchestrates the full workflow end-to-end |

## Configuration

Located at the top of the script in `$Script:Config`:

```powershell
$Script:Config = @{
    MinimumMemoryGB    = 8          # Warn below this
    ScriptVersion      = '4.4.0'   # Display version
    DiskpartScriptName = 'deploy_diskpart.txt'
    SearchPaths        = @('images', 'wim', 'deploy', 'windows', 'os')
    ImageExtensions    = @('*.wim', '*.esd')
}
```

## Partition Layout Created

The diskpart script creates:

```
Disk (GPT)
├── EFI System Partition  (300 MB, FAT32, Letter: S:)
├── Microsoft Reserved    (16 MB, no format)
└── Primary               (remaining, NTFS, Letter: C:)
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Failure (any step) |

## Image Discovery Priority

1. `-WimFile` parameter (direct path, no scanning)
2. `-ImagePath` parameter (searches specified directory)
3. `$env:DEPLOY_IMAGE_DRIVE` (set by `startnet.cmd`)
4. Auto-discovery (scans all non-system drives)
   - Checks `images/`, `wim/`, `deploy/`, `windows/`, `os/` directories
   - Checks drive root (non-recursive)
   - Filters files > 100MB
   - Sorted by size descending

## Safety Chain

```
Admin check → WinPE detection (blocks non-WinPE unless "CONTINUE ANYWAY")
           → Image selection → Edition selection
           → Memory check → Disk selection
                              ├── System disk? → Type "DESTROY SYSTEM"
                              ├── -TargetDisk without -Force → Type "ERASE"
                              └── Final confirm → Type "ERASE"
           → Disk size validation
           → Diskpart (frees C:/S: first) → DISM (inline progress)
           → Post-deploy verification (C:\Windows, C:\Windows\System32)
           → Boot config → Success
```

## Log File

A timestamped log file is created in the temp directory:
`deploy_YYYYMMDD_HHMMSS.log`

All `Write-Log` messages are appended with `[timestamp] [level] message` format.

---

# build_boot_wim.ps1

Reproducible builder for a WinPE `boot.wim` that is compatible with this
deploy tool. Run from the ADK "Deployment and Imaging Tools Environment"
as Administrator.

## Parameters

### -WorkDir [string]
Working directory for `copype` output. Default: `C:\WinPE_Build`.

### -Architecture [amd64|x86|arm64]
Target architecture. Default: `amd64`.

### -DeployScript [string]
Path to `unified_winpe_deploy.ps1`. Default: sibling of the script's parent
directory (the repo root).

### -AdkPath [string]
ADK install root. Default:
`C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit`.

### -Clean [switch]
Delete `WorkDir` before starting. Also unmounts any stale image at
`WorkDir\mount` (discards changes) to clear prior failed runs.

### -UsbDrive [string]
Drive letter (e.g. `'P:'`) of the already-partitioned FAT32 boot partition
created per `docs/USB_SETUP.md` Step 4. The built media is xcopied there
after boot.wim is committed.

### -ReleaseUsbLetter [switch]
After copying to `-UsbDrive`, runs `mountvol <letter> /d` so the boot
partition is no longer mounted in your current Windows session. The USB
remains bootable — only the drive-letter assignment in the running OS is
removed. Requires `-UsbDrive`.

### -CctkSource [string]
Path to an extracted Dell Client Configuration Toolkit directory
(the one containing `cctk.exe`). When given, the builder:
- copies the CCTK tree to `X:\cctk\` inside `boot.wim`
- installs the HAPI driver (`hapint*.inf`) into the offline image via
  `dism /Add-Driver /ForceUnsigned`

The deploy script auto-detects `X:\cctk\cctk.exe` at runtime and
applies a config from `<IMAGES>\cctk\` (see [CCTK.md](CCTK.md) for
the selection precedence and config format). CCTK binaries are not
redistributable — supply your own.

## What It Adds

**Optional components** (ADK WinPE_OCs, base + en-us language pack):
`WinPE-WMI`, `WinPE-NetFx`, `WinPE-Scripting`, `WinPE-PowerShell`,
`WinPE-DismCmdlets`, `WinPE-SecureStartup`, `WinPE-StorageWMI`,
`WinPE-EnhancedStorage`, `WinPE-FMAPI`.

**Offline registry tweaks** (applied to `SYSTEM` hive inside `boot.wim`):
- `ControlSet001\Control\FileSystem\NtfsEnableDirCaseSensitivity = 1`
  — enables case-sensitive NTFS directory support in WinPE. Without this,
  DISM `/apply-image` fails at ~19% with "Incorrect function" on captured
  images that contain Windows Containers/Hyper-V layer files (the layers
  use `CASE_SENSITIVE_DIR`).

**Embedded deploy script:** `unified_winpe_deploy.ps1` is copied to
`X:\scripts\` inside the boot image.

**`startnet.cmd`:** Auto-launches the deploy script after `wpeinit` and
a short settle delay. Probes drive letters D:-Z: for a volume labeled
`IMAGES` and exports it as `%DEPLOY_IMAGE_DRIVE%` so the deploy script
skips a full scan.

## Safety Behavior

- Mount/customize/unmount is wrapped in `try/finally`; a mid-build failure
  discards the mount (`/Discard`) rather than committing a broken image.
- Registry hive is unloaded in a `finally` block after a forced GC so
  lingering handles don't prevent unload.
- Language pack misses are logged as warnings, not fatal.
- Package installs run against specific cab paths — no wildcards, so a
  missing cab is caught immediately.

## Examples

```powershell
# Build only - output at C:\WinPE_Build\media\ for later xcopy
.\scripts\build_boot_wim.ps1

# Clean rebuild, write to pre-partitioned USB boot partition, release P:
.\scripts\build_boot_wim.ps1 -Clean -UsbDrive P: -ReleaseUsbLetter

# Custom workdir and ADK path
.\scripts\build_boot_wim.ps1 -WorkDir D:\WinPE_Build -AdkPath 'E:\ADK'
```
