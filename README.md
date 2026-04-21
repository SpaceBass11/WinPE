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
- Need driver injection, unattend.xml orchestration, or domain join as part
  of the apply — this is a focused "wipe, apply, bcdboot" tool
- Expect Windows Sandbox / Hyper-V / dev-VM provisioning — wrong scope

## What It Does

1. **Boots from USB** into WinPE (UEFI)
2. **Auto-discovers** `.wim`/`.esd` image files on the USB data partition
3. **Presents a TUI menu** for image and disk selection
4. **Wipes and partitions** the target disk (GPT layout for UEFI)
5. **Applies the Windows image** via DISM
6. **Configures UEFI boot** via BCDBoot
7. **Ready for first boot** - remove USB and reboot

## USB Drive Layout

```
USB Drive (32GB+ recommended)
├── Partition 1: WinPE Boot (FAT32, ~2GB)
│   └── Contains WinPE with auto-start configuration
└── Partition 2: Data (NTFS, remaining space)
    └── images/
        ├── Win11_Pro_24H2.wim
        ├── Win10_Enterprise_LTSC.wim
        └── (any .wim or .esd files)
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

## Documentation

- [USB Setup Guide](docs/USB_SETUP.md) - Preparing the bootable USB drive
- [Script Reference](docs/SCRIPT_REFERENCE.md) - Detailed function and parameter docs
- [Architecture](docs/ARCHITECTURE.md) - Design rationale and data flow
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

**v4.4.0** - Diskpart resilience (`noerr` on readonly clear), Linux/LVM
partition detection, DISM `/CheckIntegrity` + exit-1 recovery guidance,
reproducible boot.wim builder (`scripts/build_boot_wim.ps1`) with the
`NtfsEnableDirCaseSensitivity` fix for Windows Containers layer apply.

See [CHANGELOG.md](CHANGELOG.md) for full history.
