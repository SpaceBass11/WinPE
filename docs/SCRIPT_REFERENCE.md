# Script Reference

Complete technical reference for `unified_winpe_deploy.ps1`,
`scripts/build_boot_wim.ps1`, and `scripts/prepare_wim.ps1`.

> **Drive-letter conventions used in examples:**
> - `I:\` — IMAGES partition as seen from the admin workstation (matches
>   the `assign letter=I` in [USB_SETUP.md](USB_SETUP.md) Step 3).
> - `D:\` — IMAGES partition as seen from WinPE at runtime (WinPE itself
>   is on `X:`, the FAT32 boot partition gets the lowest free letter, and
>   the NTFS data partition typically lands on `D:`).
> - `P:\` — FAT32 WinPE boot partition on the admin workstation.

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
Skips the typed `ERASE` / `WIPE ALL` confirmations when combined with
`-TargetDisk` / `-WipeDisks` respectively. Without this flag, those flags
pre-select but still require typed confirmation. **Never bypasses
`DESTROY SYSTEM`** — the system-disk gate always requires the typed string.

### -WipeDisks [string]
Comma-separated disk numbers to also wipe (clean-only, no repartitioning)
alongside the primary target. Validated against the
`^\s*\d+(\s*,\s*\d+)*\s*$` pattern in silent mode. Requires `-Force` for
unattended runs.

```powershell
.\unified_winpe_deploy.ps1 -TargetDisk 0 -WipeDisks "1,2" -Force
```

### -MinImageSizeMB [int]
Minimum file size (in MB) for a `.wim`/`.esd` file to be considered during
auto-discovery. Default: `100`. Files smaller than this are skipped to
avoid picking up boot artifacts that share the extension. Lower it if
you're using small lab images.

```powershell
.\unified_winpe_deploy.ps1 -MinImageSizeMB 25
```

### -Silent [switch]
Unattended mode for automation. For deployment runs, it requires:
- `-WimFile` (to avoid interactive image selection)
- `-TargetDisk` (to avoid interactive disk selection)
- `-Force` (to avoid interactive final confirmation)

`-Silent` still does **not** bypass system-disk `DESTROY SYSTEM` confirmation, and it will fail fast when the selected image has multiple indexes (because unattended runs cannot answer the edition prompt).

### -UnattendFile [string]
Path to an `unattend.xml` answer file. After the Windows image is applied and
`C:\Windows\System32` verification passes, the file is copied to
`C:\Windows\Panther\unattend.xml` — one of the canonical locations Windows
Setup searches on first boot. Use this for:

- **OOBE skip** (`SkipMachineOOBE`, `SkipUserOOBE`)
- **Computer name** (`ComputerName` in the `specialize` pass)
- **Domain join** (`JoinDomain`, `MachineObjectOU`, domain credentials in `specialize`)
- **Autologon** (`AutoLogon` in `oobeSystem`)

The file is validated (must exist) before any destructive disk work begins —
the deploy aborts early if the path is wrong.

```powershell
.\unified_winpe_deploy.ps1 -WimFile "D:\images\Win11.wim" `
    -UnattendFile "D:\configs\unattend.xml"
```

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
    ScriptVersion      = '4.6.0'   # Display version
    DiskpartScriptName = 'deploy_diskpart.txt'
    SearchPaths        = @('images', 'wim', 'deploy', 'windows', 'os')
    ImageExtensions    = @('*.wim', '*.esd')
    CctkPath           = 'X:\cctk\cctk.exe'   # In-image CCTK location (set by builder)
    CctkConfigDir      = 'cctk'               # Subdirectory on IMAGES drive for configs
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
           → -UnattendFile validation (fail fast if path doesn't exist)
           → Image selection → Edition selection
           → Memory check
           → CCTK pre-apply (if X:\cctk\cctk.exe present and config matched)
                              └── Non-zero exit → abort deploy
           → Disk selection
                              ├── System disk? → Type "DESTROY SYSTEM"
                              ├── -TargetDisk without -Force → Type "ERASE"
                              └── Final confirm → Type "ERASE"
           → Additional-wipe prompt (optional)
                              └── Selected disks → single "WIPE ALL" confirmation
           → Disk size validation
           → Diskpart (frees C:/S: first; clean-only preamble for extras)
           → DISM (inline progress)
           → Post-deploy verification (C:\Windows, C:\Windows\System32)
           → Unattend staging (if -UnattendFile: copy to C:\Windows\Panther\unattend.xml)
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
created per `docs/USB_SETUP.md` Step 3. The built media is xcopied there
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

---

# prepare_wim.ps1

Companion to `unified_winpe_deploy.ps1`. Takes a stock Windows ISO,
extracts `install.wim`, picks the requested edition, debloats provisioned
AppX packages with a whitelist, optionally applies offline registry
tweaks, and re-exports a clean WIM for deployment. Run on an
admin Windows workstation (not in WinPE).

## Parameters

### -SourceIso [string] (Required if -SourceWim not given)
Path to the Windows installation ISO (must contain
`sources\install.wim` or `sources\install.esd`). Use this **or**
`-SourceWim`, not both.

### -SourceWim [string] (Required if -SourceIso not given)
Path to an already-captured `.wim`/`.esd` file (e.g. one produced by
`Dism /Capture-Image` on a reference machine). Use this **or**
`-SourceIso`, not both. The source is copied to a working location
before modification — the original file is never touched in place.

### -OutputWim [string] (Required)
Where to write the customized WIM. Parent directory is created if missing.

### -Edition [string]
Edition name as DISM reports it. Default: `'Windows 11 Enterprise'`.
Run `Get-WindowsImage -ImagePath <install.wim>` to list available names.
Ignored if `-Index` is given.

### -Index [int]
Numeric image index to pick from the source. Overrides `-Edition`.
Useful for captured WIMs that don't use the standard edition names, or
when you want to be explicit. If neither `-Edition` nor `-Index` is
given and the source is a captured WIM, defaults to index 1.

### -WorkDir [string]
Temporary working directory for ISO mount, WIM mount, and DISM scratch.
Default: `C:\WimPrep`. Created if missing, NOT auto-deleted (re-runnable,
easier to debug).

### -Whitelist [string[]]
Array of provisioned AppX package `DisplayName`s to keep. Anything not
in this list is removed. Default is a sane Microsoft set (Photos,
Calculator, Notepad, Store, Terminal, Camera, Defender UI, codecs).

### -WhitelistFile [string]
Path to a text file with one DisplayName per line. Lines starting with
`#` are comments. Overrides `-Whitelist` if both are given. Useful for
keeping the whitelist under version control separately.

### -DriverPath [string]
Path to a folder containing driver packages (`.inf` files). Searched
recursively. Drivers are injected into the offline image via
`Add-WindowsDriver -Recurse -ForceUnsigned` while the WIM is mounted,
after debloat and before save/re-export.

Use this to pre-bake chipset, NVMe, NIC, or vendor-specific drivers so
deployed machines have them out-of-box without a post-deploy injection step.

Suggested folder layout:
```
C:\Drivers\Dell_OptiPlex7090\
  chipset\   ← Intel chipset .inf files
  nvme\      ← vendor NVMe .inf files
  nic\       ← NIC .inf files
```

The script validates that the path exists and contains at least one `.inf`
before mounting — fails fast so you don't waste 10 minutes on a mount/unmount
cycle for a bad path.

### -DisableCopilot [switch]
Apply the offline registry tweak that disables Windows Copilot via
policy (`HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot\TurnOffWindowsCopilot=1`).
Single key, narrow scope. Use `-DisableExtraBloat` instead for the
broader set.

### -DisableExtraBloat [switch]
Superset of `-DisableCopilot`. Applies all of the above plus seven
additional HKLM policy tweaks via the same offline-hive mechanism:

| Tweak | Key |
|---|---|
| Disable Recall (24H2+) | `Policies\Microsoft\Windows\WindowsAI\DisableAIDataAnalysis = 1` |
| Disable Widgets / News & Interests | `Policies\Microsoft\Dsh\AllowNewsAndInterests = 0` |
| Disable Bing in Start search | `Policies\Microsoft\Windows\Windows Search\DisableWebSearch = 1` and `ConnectedSearchUseWeb = 0` |
| Disable telemetry | `Policies\Microsoft\Windows\DataCollection\AllowTelemetry = 0` (Enterprise floors at 0; Pro/Home cap at 1 regardless) |
| Disable consumer feature auto-installs | `Policies\Microsoft\Windows\CloudContent\DisableWindowsConsumerFeatures = 1` |
| Hide Edge first-run experience | `Policies\Microsoft\Edge\HideFirstRunExperience = 1` |
| Disable Teams Consumer Chat auto-install | `Microsoft\Windows\CurrentVersion\Communications\ConfigureChatAutoInstall = 0` |

Also stages `scripts/first-login.ps1` into the image at
`C:\Windows\Setup\Scripts\first-login.ps1` so that an `unattend.xml`
`FirstLogonCommands` entry can call it at first sign-in to apply
per-user (HKCU) tweaks (file extensions on, suggested apps off,
classic right-click menu, OneDrive uninstall, etc). See
[`configs/unattend.example.xml`](../configs/unattend.example.xml) for
the template.

### -NoCleanup [switch]
Skip the dismount-discard cleanup paths. Mainly for debugging stuck
mounts. Off by default.

## Safety Behavior

- ISO mount, WIM mount, and registry hive load are each wrapped in
  `try/finally`. A mid-script failure discards the WIM mount (no
  half-debloated WIM committed) and unloads the offline hive.
- Whitelist approach intentionally fails forward when Microsoft adds new
  bloat — new packages stay until you explicitly whitelist them.
- `Remove-AppxProvisionedPackage` errors abort the run (no
  `-ErrorAction SilentlyContinue` swallowing). If a package can't be
  removed, you want to know.
- Final export uses `-CompressionType Max -CheckIntegrity` so the
  output is space-efficient and SHA1-hashed for later verification.

## Examples

```powershell
# Default whitelist + Copilot off
.\scripts\prepare_wim.ps1 `
    -SourceIso 'D:\iso\Win11_24H2_English_x64.iso' `
    -OutputWim 'I:\images\Win11_24h2_Enterprise_Custom.wim' `
    -DisableCopilot

# Custom whitelist file (one DisplayName per line, # for comments)
.\scripts\prepare_wim.ps1 `
    -SourceIso 'D:\iso\Win11.iso' `
    -OutputWim 'I:\images\Win11_Custom.wim' `
    -WhitelistFile 'C:\configs\my_whitelist.txt'

# Different edition (Pro instead of Enterprise)
.\scripts\prepare_wim.ps1 `
    -SourceIso 'D:\iso\Win11.iso' `
    -OutputWim 'I:\images\Win11_Pro_Custom.wim' `
    -Edition 'Windows 11 Pro'

# Pre-bake drivers + disable Copilot
.\scripts\prepare_wim.ps1 `
    -SourceIso 'D:\iso\Win11_24H2_English_x64.iso' `
    -OutputWim 'I:\images\Win11_Enterprise_Custom.wim' `
    -DriverPath 'C:\Drivers\Dell_OptiPlex7090' `
    -DisableCopilot
```

---

# refresh_usb.ps1

Thin wrapper for the recurring "Microsoft dropped new media, get it on
my USB" workflow. Sequences `prepare_wim.ps1` and (optionally)
`build_boot_wim.ps1`, with auto-derived output names and a prompt for
the boot-rebuild step that's easy to forget. Adds no behavior — just
defaults and ordering.

## Parameters

### -SourceIso [string] (Required)
Path to the Windows ISO.

### -OutputName [string]
Basename for the resulting WIM (no extension, no path). Defaults to
the ISO filename minus its extension.

### -ImagesPath [string]
Directory where the resulting WIM is placed. Default: `I:\images`.

### -DriverPath [string]
Passthrough to `prepare_wim.ps1 -DriverPath`. Optional folder of
`.inf` driver packages to pre-bake into the image.

### -WhitelistFile [string]
Passthrough to `prepare_wim.ps1 -WhitelistFile`. Custom AppX
whitelist text file.

### -DisableCopilot [switch]
Passthrough to `prepare_wim.ps1 -DisableCopilot`.

### -RebuildBootWim [Yes|No|Ask]
`Yes` to also rebuild WinPE boot.wim. `No` to skip. `Ask` (default)
prompts interactively. Most refreshes are image-only — you don't
need to rebuild WinPE every time Microsoft drops new install media.

### -BootUsbDrive [string]
Used only with `-RebuildBootWim Yes`. Default: `P:`.

### -CctkSource [string]
Used only with `-RebuildBootWim Yes`. Optional path to Dell CCTK to
embed in boot.wim. See [docs/CCTK.md](CCTK.md).

## Examples

```powershell
# Simplest case: new ISO, refresh just the image
.\scripts\refresh_usb.ps1 -SourceIso 'D:\iso\Win11_24H2.iso'

# Drivers + Copilot disabled
.\scripts\refresh_usb.ps1 `
    -SourceIso 'D:\iso\Win11_24H2.iso' `
    -DriverPath 'C:\Drivers\Dell' `
    -DisableCopilot

# Refresh both image and WinPE boot.wim (run from ADK env)
.\scripts\refresh_usb.ps1 `
    -SourceIso 'D:\iso\Win11_24H2.iso' `
    -RebuildBootWim Yes
```

## Pre-flight Checks

Fails early on:
- ISO path doesn't exist
- `ImagesPath` doesn't exist (USB not mounted as expected)
- `-RebuildBootWim Yes` but `copype` not on PATH (must run from ADK
  "Deployment and Imaging Tools Environment" as admin)

The pre-flight for `copype` runs before `prepare_wim.ps1` does, so
you don't sit through a 20-minute image prep only to discover the
boot rebuild can't proceed.

