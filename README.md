# WinPE Image Deployment Tool

A PowerShell-based TUI tool for deploying Windows images (`.wim`/`.esd`) from a bootable USB drive in a WinPE environment. Designed for IT admins, engineers, and field technicians who need reliable, repeatable bare-metal Windows deployments.

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
.\unified_winpe_deploy.ps1 -WimFile "D:\images\Win11.wim" -TargetDisk 0 -Silent
```

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-ImagePath` | String | Directory to search for images (skips drive scanning) |
| `-WimFile` | String | Direct path to a `.wim`/`.esd` file |
| `-TargetDisk` | Int | Disk number to deploy to (skips disk selection) |
| `-Silent` | Switch | No interactive prompts - continues through warnings |
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
  - Type `DELETE ALL DATA` for final confirmation

## Documentation

- [USB Setup Guide](docs/USB_SETUP.md) - Preparing the bootable USB drive
- [Script Reference](docs/SCRIPT_REFERENCE.md) - Detailed function and parameter docs
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues and solutions

## Requirements

- Windows PE (WinPE) boot environment
- PowerShell 5.1+ (included in WinPE)
- Administrator privileges
- UEFI-capable target system
- USB drive 32GB+ (8GB minimum for WinPE + 1 image)

## Version

**v4.1** - Generic Universal Version
