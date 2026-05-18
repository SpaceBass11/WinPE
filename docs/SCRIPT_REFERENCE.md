# Script Reference

Parameter reference for all scripts in the MDT USB Payload Factory. For
architecture and design rationale see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## MDT Scripts (`scripts/mdt/`)

These run on the **admin workstation** to build the operator payload. Requires
MDT 8456 and ADK installed.

### Initialize-MDTDeploymentShare.ps1

One-time setup: creates the MDT deployment share, imports WIM(s), creates a
task sequence per OS (UEFI GPT layout), and writes zero-touch
`CustomSettings.ini` / `Bootstrap.ini`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-SharePath` | string | `C:\MDTDeploymentShare` | Local path for the deployment share |
| `-WimPaths` | string[] | `@()` | One or more `.wim`/`.esd` files to import; each becomes an OS + task sequence |
| `-OrgName` | string | `My Organization` | Organization name embedded in task sequences |
| `-TimeZone` | string | `Central Standard Time` | Windows time-zone name (`tzutil /l` to list valid names) |

```powershell
# Typical first-time setup
.\scripts\mdt\Initialize-MDTDeploymentShare.ps1 `
    -WimPaths 'C:\images\Win11_Pro_24H2.wim' `
    -OrgName  'Contoso IT'

# Multiple WIMs, different share path
.\scripts\mdt\Initialize-MDTDeploymentShare.ps1 `
    -SharePath 'D:\MDT' `
    -WimPaths 'C:\images\Win11_Pro.wim','C:\images\Win10_LTSC.wim' `
    -OrgName  'Contoso IT' `
    -TimeZone 'Eastern Standard Time'
```

---

### Import-WimImages.ps1

Add one or more WIMs to an existing deployment share. Optionally creates task
sequences and re-runs `Update-MDTDeploymentShare` to regenerate `LiteTouchPE_x64.wim`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-SharePath` | string | `C:\MDTDeploymentShare` | Local path to the existing deployment share |
| `-WimPaths` | string[] | `@()` | Explicit WIM/ESD file paths to import |
| `-WimFolder` | string | — | Folder to scan for `*.wim`/`*.esd`; ignored if `-WimPaths` is set |
| `-CreateTaskSequences` | bool | `$true` | Create a task sequence for each imported OS |
| `-OrgName` | string | `My Organization` | Organization name for task sequences |
| `-UpdateShare` | bool | `$true` | Re-run `Update-MDTDeploymentShare` after import to regenerate boot.wim |

```powershell
# Import a single new OS
.\scripts\mdt\Import-WimImages.ps1 -WimPaths 'C:\images\Win11_Ent_24H2.wim'

# Import all WIMs in a folder, skip task sequence creation
.\scripts\mdt\Import-WimImages.ps1 -WimFolder 'C:\images' -CreateTaskSequences:$false
```

---

### New-MDTMedia.ps1

Build the operator payload ISO (`LiteTouchMedia_x64.iso`). Run this every
time you want to publish an updated payload. The ISO is self-contained — no
network required when operators use it.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-SharePath` | string | `C:\MDTDeploymentShare` | Local path to the MDT deployment share |
| `-OutputPath` | string | `C:\MDTMedia` | Where to write media files and the final ISO |
| `-MediaName` | string | `MEDIA001` | MDT media object name; leave at default unless managing multiple media targets |
| `-SelectionProfile` | string | `Everything` | Content to include; create a named profile in MDT Workbench to limit ISO size (e.g. one OS only) |

```powershell
# Standard build — generates C:\MDTMedia\LiteTouchMedia_x64.iso
.\scripts\mdt\New-MDTMedia.ps1

# Custom output folder
.\scripts\mdt\New-MDTMedia.ps1 -OutputPath 'D:\Payloads\Win11_24H2'
```

---

## WinPE Tool Scripts (underlying layer)

These are used by the admin to build and maintain the WinPE USB tool. The MDT
layer replaces the manual USB workflow for most deployments; these remain
relevant for custom WinPE builds or direct-USB use.

> **Drive-letter conventions:**
> `I:\` — IMAGES partition on admin workstation; `P:\` — FAT32 WinPE boot
> partition on admin workstation; `D:\` — IMAGES partition as seen from WinPE
> at runtime.

---

### unified_winpe_deploy.ps1

WinPE deploy script — boots from USB, presents TUI menus, partitions the
target disk (GPT: EFI 300 MB + MSR 16 MB + NTFS), and applies the Windows
image via DISM. See [ARCHITECTURE.md](ARCHITECTURE.md) for the full flow.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ImagePath` | string | — | Directory to search for `.wim`/`.esd` (up to 2 levels deep); bypasses full drive scan |
| `-WimFile` | string | — | Direct path to a specific image file; bypasses all discovery |
| `-TargetDisk` | int | — | Pre-select disk number; still requires typed `ERASE` unless `-Force` is also set |
| `-Force` | switch | — | Skip `ERASE`/`WIPE ALL` typed confirmations; never bypasses `DESTROY SYSTEM` |
| `-WipeDisks` | string | — | Comma-separated disk numbers to wipe alongside the primary target (clean-only) |
| `-MinImageSizeMB` | int | `100` | Minimum file size to consider during auto-discovery |
| `-Silent` | switch | — | Unattended mode; requires `-WimFile`, `-TargetDisk`, `-Force` |
| `-UnattendFile` | string | — | Path to `unattend.xml`; copied to `C:\Windows\Panther\` after image apply |
| `-ListOnly` | switch | — | Discover and display available images, then exit without deploying |

---

### scripts/prepare_wim.ps1

Takes a stock Windows ISO or captured WIM, extracts the requested edition,
debloats provisioned AppX packages, optionally injects drivers and applies
offline registry tweaks, and re-exports a clean WIM for deployment. Run on an
admin Windows workstation.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-SourceIso` | string | — | Path to Windows ISO (mutually exclusive with `-SourceWim`) |
| `-SourceWim` | string | — | Path to a captured `.wim`/`.esd` (mutually exclusive with `-SourceIso`) |
| `-OutputWim` | string | **Required** | Output WIM path; parent directory created if missing |
| `-Edition` | string | `Windows 11 Enterprise` | Edition name as DISM reports it; ignored if `-Index` is given |
| `-Index` | int | — | Numeric image index; overrides `-Edition` |
| `-WorkDir` | string | `C:\WimPrep` | Temp directory for ISO/WIM mount and DISM scratch |
| `-Whitelist` | string[] | Microsoft default set | AppX `DisplayName`s to keep; everything else is removed |
| `-WhitelistFile` | string | — | Text file with one `DisplayName` per line (`#` = comment); overrides `-Whitelist` |
| `-DriverPath` | string | — | Folder of `.inf` driver packages to inject into the offline image (recursive) |
| `-DisableCopilot` | switch | — | Apply offline registry tweak disabling Windows Copilot via policy |
| `-DisableExtraBloat` | switch | — | Superset of `-DisableCopilot`; adds Recall, Widgets, Bing, telemetry, and other policy tweaks |
| `-NoCleanup` | switch | — | Skip dismount-discard cleanup (debugging use only) |

```powershell
# Default whitelist + Copilot off
.\scripts\prepare_wim.ps1 `
    -SourceIso 'D:\iso\Win11_24H2_English_x64.iso' `
    -OutputWim 'I:\images\Win11_24H2_Enterprise.wim' `
    -DisableCopilot

# Pre-bake drivers, full debloat
.\scripts\prepare_wim.ps1 `
    -SourceIso 'D:\iso\Win11_24H2_English_x64.iso' `
    -OutputWim 'I:\images\Win11_Enterprise.wim' `
    -DriverPath 'C:\Drivers\Dell_OptiPlex7090' `
    -DisableExtraBloat
```

---

### scripts/build_boot_wim.ps1

Reproducible builder for a WinPE `boot.wim` compatible with the deploy tool.
Run from the ADK "Deployment and Imaging Tools Environment" as Administrator.
Adds WinPE optional components, a registry tweak for NTFS case-sensitivity
(required for images containing Windows Containers/Hyper-V layer files), and
embeds `unified_winpe_deploy.ps1` with an auto-launch `startnet.cmd`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-WorkDir` | string | `C:\WinPE_Build` | Working directory for `copype` output |
| `-Architecture` | string | `amd64` | Target architecture: `amd64`, `x86`, or `arm64` |
| `-DeployScript` | string | repo root sibling | Path to `unified_winpe_deploy.ps1` |
| `-AdkPath` | string | `C:\Program Files (x86)\Windows Kits\10\...` | ADK install root |
| `-Clean` | switch | — | Delete `WorkDir` before starting; discards any stale mount |
| `-UsbDrive` | string | — | Drive letter (e.g. `P:`) of the FAT32 boot partition; built media is xcopied there |
| `-ReleaseUsbLetter` | switch | — | After copy, run `mountvol /d` to drop the drive-letter assignment; requires `-UsbDrive` |
| `-CctkSource` | string | — | Path to extracted Dell CCTK directory; copies `cctk.exe` and installs HAPI driver into `boot.wim` |

```powershell
# Build only — output at C:\WinPE_Build\media\
.\scripts\build_boot_wim.ps1

# Clean rebuild, write to USB boot partition
.\scripts\build_boot_wim.ps1 -Clean -UsbDrive P: -ReleaseUsbLetter
```

---

### scripts/refresh_usb.ps1

Thin wrapper for the "new ISO, refresh the USB" workflow. Sequences
`prepare_wim.ps1` and optionally `build_boot_wim.ps1`. Adds no new behavior —
just wires up defaults and order so it's a single command to run when
Microsoft drops updated media.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-SourceIso` | string | **Required** | Path to the Windows ISO |
| `-OutputName` | string | ISO filename (no extension) | Basename for the output WIM |
| `-ImagesPath` | string | `I:\images` | Directory for the resulting WIM |
| `-DriverPath` | string | — | Passthrough to `prepare_wim.ps1 -DriverPath` |
| `-WhitelistFile` | string | — | Passthrough to `prepare_wim.ps1 -WhitelistFile` |
| `-DisableCopilot` | switch | — | Passthrough to `prepare_wim.ps1 -DisableCopilot` |
| `-RebuildBootWim` | `Yes`/`No`/`Ask` | `Ask` | Whether to also rebuild WinPE boot.wim; most refreshes are image-only |
| `-BootUsbDrive` | string | `P:` | Used only with `-RebuildBootWim Yes` |
| `-CctkSource` | string | — | Used only with `-RebuildBootWim Yes`; optional Dell CCTK path to embed |

```powershell
# Simplest: refresh just the image
.\scripts\refresh_usb.ps1 -SourceIso 'D:\iso\Win11_24H2.iso'

# Drivers + Copilot disabled
.\scripts\refresh_usb.ps1 `
    -SourceIso 'D:\iso\Win11_24H2.iso' `
    -DriverPath 'C:\Drivers\Dell' `
    -DisableCopilot

# Refresh image and WinPE boot.wim (run from ADK env)
.\scripts\refresh_usb.ps1 `
    -SourceIso 'D:\iso\Win11_24H2.iso' `
    -RebuildBootWim Yes
```
