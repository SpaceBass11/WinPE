# WinPE Image Deployment Tool

[![CI](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml/badge.svg)](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://learn.microsoft.com/powershell/)
[![Platform: WinPE](https://img.shields.io/badge/Platform-WinPE-informational.svg)](https://learn.microsoft.com/windows-hardware/manufacture/desktop/winpe-intro)

A PowerShell-based TUI tool for deploying Windows images (`.wim`/`.esd`) from a bootable USB drive in a WinPE environment. Designed for IT admins, engineers, and field technicians who need reliable, repeatable bare-metal Windows deployments.

> [!WARNING]
> **This tool wipes entire disks.** It calls `diskpart clean` on the target
> disk, which is irreversible. Always double-check the selected disk number
> and never run with `-Force -Silent` on a host you have not explicitly
> targeted. There is no undo.

## Who This Is For

**Use this if you:**
- Deploy Windows images to bare-metal hardware from a USB stick
- Want a reproducible WinPE build (no Rufus-and-hope, no hand-edited ISOs)
- Need unattended deployment via `-Silent -WimFile X -TargetDisk N -Force`
- Are comfortable reading PowerShell and taking responsibility for the
  target disk

**Don't use this if you:**
- Need network-based (PXE / WDS / MDT / SCCM) deployment — use MDT/ConfigMgr
- Expect Windows Sandbox / Hyper-V / dev-VM provisioning — wrong scope

## Getting Started

Complete path from a fresh repo download to a deployed machine.

### Prerequisites (one-time, on your admin workstation)

1. **Windows ADK + WinPE add-on** — download from
   [Microsoft's ADK page](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install).
   Install only the **Deployment Tools** feature.
2. **A Windows ISO** — from VLSC, Visual Studio subscriptions, or an existing
   `.wim`/`.esd` if you already have one.
3. **A USB drive** — 32 GB+ recommended (8 GB minimum for WinPE + one image).

### Step 1 — Partition the USB

Open diskpart as Administrator (this erases the USB):

```cmd
diskpart
list disk
select disk <USB_NUMBER>     ← double-check this
clean
create partition primary size=2048
format quick fs=fat32 label="WinPE"
assign letter=P
create partition primary
format quick fs=ntfs label="IMAGES"
assign letter=I
exit
```

Full details and warnings: [docs/USB_SETUP.md](docs/USB_SETUP.md).

### Step 2 — Prepare your Windows image (optional but recommended)

Run on your **admin workstation** (not in WinPE). Takes a stock ISO and
produces a debloated, customized `.wim` ready to deploy:

```powershell
# Requires admin. Run from the repo root.
.\scripts\prepare_wim.ps1 `
    -SourceIso 'D:\iso\Win11_24H2_English_x64.iso' `
    -OutputWim 'I:\images\Win11_Enterprise.wim' `
    -DisableCopilot
```

Skip this step if you already have a `.wim`/`.esd` — just copy it to
`I:\images\` directly.

Optional extras:
- **Pre-bake drivers** (chipset, NVMe, NIC): add `-DriverPath 'C:\Drivers\Model'`
- **Custom app whitelist**: add `-WhitelistFile 'C:\configs\whitelist.txt'`

### Step 3 — Build the WinPE boot image

Open **Deployment and Imaging Tools Environment** as Administrator (from the
Start menu under Windows Kits), then run the builder from the repo root:

```powershell
# Writes WinPE media directly to the USB boot partition
.\scripts\build_boot_wim.ps1 -Clean -UsbDrive P: -ReleaseUsbLetter
```

This runs `copype`, installs required WinPE components, applies the
`NtfsEnableDirCaseSensitivity` registry fix, embeds the deploy script at
`X:\scripts\`, writes `startnet.cmd`, and xcopies the media to `P:`.
`-ReleaseUsbLetter` releases `P:` afterwards (USB stays bootable).

> **Dell fleets only:** add `-CctkSource 'C:\Program Files (x86)\Dell\Command Configure\X86_64'`
> to embed CCTK for pre-deploy BIOS configuration (RAID→AHCI, passwords, boot order).
> See [docs/CCTK.md](docs/CCTK.md).

### Step 4 — Deploy

1. Plug the USB into the target machine.
2. Boot from USB in **UEFI mode** (usually F12 → select "UEFI: USB …").
3. WinPE loads → the deploy script auto-starts.
4. Follow the TUI: select image → select edition → select target disk → confirm.
5. When complete: remove USB and reboot.

For unattended (scripted) deployments, see the `-Silent` flag in the
Parameters table below.

## What It Does

1. **Boots from USB** into WinPE (UEFI)
2. **Auto-discovers** `.wim`/`.esd` image files on the USB data partition
3. **Presents a TUI menu** for image and disk selection
4. **Wipes and partitions** the target disk (GPT layout for UEFI)
5. **Applies the Windows image** via DISM
6. **Stages `unattend.xml`** to `C:\Windows\Panther\` (if `-UnattendFile` given)
7. **Configures UEFI boot** via BCDBoot
8. **Ready for first boot** — Windows Setup processes the answer file on first POST

## USB Drive Layout

```
USB Drive (32GB+ recommended)
├── Partition 1: WinPE Boot (FAT32, ~2GB)
│   └── Contains WinPE with auto-start configuration
└── Partition 2: Data (NTFS, remaining space)
    ├── images/
    │   ├── Win11_Pro_24H2.wim
    │   ├── Win10_Enterprise_LTSC.wim
    │   └── (any .wim or .esd files)
    ├── configs/                    (optional, unattend.xml answer files)
    │   └── unattend.xml            (used with -UnattendFile)
    └── cctk/                       (optional, Dell BIOS configs)
        └── default.ini             (and/or per-tag, per-model overrides)
```

See [docs/USB_SETUP.md](docs/USB_SETUP.md) for step-by-step USB preparation instructions.

## Quick Start

### From WinPE (normal use)
The script launches automatically via `startnet.cmd` when WinPE boots. No manual intervention needed - just plug in the USB and boot from it.

### Manual / Testing
```powershell
# Auto-discover images on all drives
.\unified_winpe_deploy.ps1

# Point to a specific image directory
.\unified_winpe_deploy.ps1 -ImagePath "D:\images"

# Use a specific WIM file directly
.\unified_winpe_deploy.ps1 -WimFile "D:\images\Win11_Pro.wim"

# Deploy with an unattend.xml for first-boot config (OOBE skip, domain join, etc.)
.\unified_winpe_deploy.ps1 -WimFile "D:\images\Win11.wim" -UnattendFile "D:\configs\unattend.xml"

# List available images without deploying
.\unified_winpe_deploy.ps1 -ListOnly

# Fully automated (for scripted deployments)
.\unified_winpe_deploy.ps1 -WimFile "D:\images\Win11.wim" -TargetDisk 0 -Force -Silent
```

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-ImagePath` | String | Directory to search for images (skips drive scanning) |
| `-WimFile` | String | Direct path to a `.wim`/`.esd` file |
| `-TargetDisk` | Int | Disk number to deploy to (skips disk selection) |
| `-WipeDisks` | String | Comma-separated disk numbers to *also* wipe (clean-only) alongside the primary target (e.g. `"1,2"`). Requires `-Force` in silent mode. |
| `-MinImageSizeMB` | Int | Auto-discovery minimum image size in MB (default 100). Lower for small lab images. |
| `-UnattendFile` | String | Path to an `unattend.xml` answer file. Copied to `C:\Windows\Panther\unattend.xml` post-apply so Windows Setup processes it on first boot (OOBE skip, domain join, etc.). |
| `-Force` | Switch | Skip the typed `ERASE` / `WIPE ALL` confirmations. Never bypasses `DESTROY SYSTEM`. |
| `-Silent` | Switch | Unattended mode. Requires `-WimFile`, `-TargetDisk`, and `-Force` (unless using `-ListOnly`), and a single-index image. |
| `-ListOnly` | Switch | Show available images and exit |

## Disk Partition Layout Created

The script creates a standard UEFI/GPT partition layout:

| Partition | Size | Format | Letter | Purpose |
|-----------|------|--------|--------|---------|
| EFI System | 300 MB | FAT32 | S: | UEFI boot files |
| MSR | 16 MB | - | - | Microsoft Reserved |
| Primary | Remaining | NTFS | C: | Windows installation |

## Safety Features

- Requires Administrator privileges
- WinPE environment detection
- System memory validation (8GB+ recommended)
- Excludes USB drives from target disk list
- System disk detection with red warning
- **Two-step confirmation** for disk destruction:
  - Type `DESTROY SYSTEM` for system disk
  - Type `ERASE` for final confirmation

## Companion Scripts

| Script | Purpose | Runs On |
|--------|---------|---------|
| `unified_winpe_deploy.ps1` | The deploy tool. Wipes target, applies WIM, configures UEFI boot. | Inside WinPE (booted from USB) |
| `scripts/build_boot_wim.ps1` | Builds the WinPE `boot.wim` with the right components, the `NtfsEnableDirCaseSensitivity` reg tweak, and optionally embedded Dell CCTK. | Admin Windows workstation (ADK installed) |
| `scripts/prepare_wim.ps1` | Takes a stock Windows ISO, debloats provisioned AppX with a whitelist, optionally disables Copilot, exports a clean WIM ready to deploy. | Admin Windows workstation |
| `scripts/validate_script.ps1` | Static-analysis checks for the deploy script. Used by CI. | Any host with PowerShell |
| `tests/test_parse.ps1` | Syntax validation for all three scripts above. Used by CI. | Any host with PowerShell |

## Documentation

- [USB Setup Guide](docs/USB_SETUP.md) - Preparing the bootable USB drive
- [Script Reference](docs/SCRIPT_REFERENCE.md) - Detailed function and parameter docs
- [Architecture](docs/ARCHITECTURE.md) - Design rationale and data flow
- [BIOS Configuration (CCTK)](docs/CCTK.md) - Pre-apply BIOS setup for Dell fleets
- [Code Signing](docs/SIGNING.md) - Signing the script for enterprise use
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues and solutions
- [Known Issues](docs/KNOWN_ISSUES.md) - Current limitations and recent fixes
- [Contributing](CONTRIBUTING.md) - How to contribute
- [Code of Conduct](CODE_OF_CONDUCT.md) - Contributor Covenant v2.1
- [Changelog](CHANGELOG.md) - Version history
- [Security Policy](SECURITY.md) - Reporting vulnerabilities

## Requirements

- Windows PE (WinPE) boot environment
- PowerShell 5.1+ (included in WinPE)
- Administrator privileges
- UEFI-capable target system
- USB drive 32GB+ (8GB minimum for WinPE + 1 image)

## Contributing

Pull requests welcome, especially for hardware-compatibility fixes. Before
opening one, please:

1. Read the safety conventions in [CLAUDE.md](CLAUDE.md) — in particular,
   never weaken the typed-confirmation chain.
2. Run the local validators:
   ```powershell
   pwsh -NoProfile -File ./tests/test_parse.ps1
   pwsh -NoProfile -File ./scripts/validate_script.ps1
   ```
3. Describe manual test coverage in the PR template — CI only verifies
   syntax and static analysis, not real WinPE behavior.

## License

[MIT](LICENSE) — © 2026 spacebass11. You use this tool at your own risk;
see the license for the full disclaimer of warranty.

## Version

**v4.6.0** - Driver injection (`prepare_wim.ps1 -DriverPath`) to pre-bake
drivers into the WIM at prep time. Unattend.xml staging (`-UnattendFile`)
— answer file is dropped to `C:\Windows\Panther\` post-apply for first-boot
OOBE skip, computer name, domain join, etc.

**v4.5.0** - Dell CCTK pre-apply BIOS configuration (RAID→AHCI,
passwords, boot order — embedded in `boot.wim` via
`build_boot_wim.ps1 -CctkSource`; per-machine `<SERVICETAG>.ini` on
the IMAGES partition). Multi-disk wipe stage with streamlined
`WIPE ALL` confirmation and new `-WipeDisks` silent-mode parameter.

**v4.4.0** - Diskpart resilience (`noerr` on readonly clear), Linux/LVM
partition detection, DISM `/CheckIntegrity` + exit-1 recovery guidance,
reproducible boot.wim builder (`scripts/build_boot_wim.ps1`) with the
`NtfsEnableDirCaseSensitivity` fix for Windows Containers layer apply.

See [CHANGELOG.md](CHANGELOG.md) for full history.
