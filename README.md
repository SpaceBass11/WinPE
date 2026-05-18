# MDT USB Payload Factory

[![CI](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml/badge.svg)](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://learn.microsoft.com/powershell/)

PowerShell scripts for building self-contained, zero-touch Windows deployment USB sticks using Microsoft Deployment Toolkit (MDT) standalone media.

**Admin builds once. Operator plugs in USB, boots laptop, walks away.**

```
Admin workstation
  ├── Initialize-MDTDeploymentShare.ps1   (one-time setup)
  ├── Import-WimImages.ps1                (add/update OS images)
  └── New-MDTMedia.ps1                    (build payload ISO)
          │
          ▼
  LiteTouchMedia_x64.iso  →  upload to download link
          │
          ▼
  Operator: download → Rufus → USB → boot laptop → done
```

No deployment server. No network at deploy time. The ISO is entirely self-contained.

## Prerequisites

Install in this order on your **admin workstation**:

1. [Windows ADK](https://docs.microsoft.com/en-us/windows-hardware/get-started/adk-install) — select *Deployment Tools* only
2. [ADK WinPE add-on](https://docs.microsoft.com/en-us/windows-hardware/get-started/adk-install) — separate installer, same page
3. [MDT 8456](https://www.microsoft.com/en-us/download/details.aspx?id=54259)
4. [MDT hotfix KB4564442](https://support.microsoft.com/en-us/topic/windows-10-deployments-fail-with-microsoft-deployment-toolkit-on-computers-with-bios-type-firmware-70557b0b-6be3-81d2-556f-b313e29e2cb7) — required for Windows 11 UEFI deployments

A Windows `.wim` or `.esd` image file for each OS you want to deploy.

## Admin Workflow

### Step 1 — One-time setup

```powershell
# Elevated PowerShell
.\scripts\mdt\Initialize-MDTDeploymentShare.ps1 `
    -WimPaths 'C:\images\Win11_Pro_24H2.wim' `
    -OrgName  'Contoso IT'
```

Creates the MDT deployment share at `C:\MDTDeploymentShare`, imports the WIM,
and creates a fully zero-touch task sequence (GPT: EFI 300 MB + MSR 16 MB +
Windows — all wizard pages suppressed, reboots automatically when done).

### Step 2 — Build the payload ISO

```powershell
.\scripts\mdt\New-MDTMedia.ps1
# Output: C:\MDTMedia\LiteTouchMedia_x64.iso
```

Upload `LiteTouchMedia_x64.iso` to your file share / download link.

### Updating the payload

```powershell
# New WIM version:
.\scripts\mdt\Import-WimImages.ps1 -WimPaths 'C:\images\Win11_Pro_24H2_v2.wim'

# Rebuild and re-upload:
.\scripts\mdt\New-MDTMedia.ps1
```

## Operator Workflow

1. Download the ISO from the link
2. Open [Rufus](https://rufus.ie) → select ISO → select USB → **START** (~20 min)
3. Plug USB into target laptop, boot from USB (F12 boot menu)
4. Walk away — laptop partitions, installs Windows, and reboots automatically

## Disk Partition Layout

Every deployment creates a clean UEFI/GPT layout:

| Partition | Size | Format | Letter |
|-----------|------|--------|--------|
| EFI System | 300 MB | FAT32 | S: |
| MSR | 16 MB | — | — |
| Windows | Remaining | NTFS | C: |

## Configuration

| File | Purpose |
|------|---------|
| `configs/mdt/CustomSettings.ini` | Zero-touch settings: task sequence ID, disk index, locale, FinishAction |
| `configs/mdt/Bootstrap.ini` | WinPE boot config — `DeployRoot=.` tells LiteTouch to read from the booted USB |

Edit these files and rebuild the ISO to change deployment behavior. See
[docs/MDT.md](docs/MDT.md) for the full configuration reference.

## Scripts

| Script | When to run |
|--------|-------------|
| `scripts/mdt/Initialize-MDTDeploymentShare.ps1` | Once, on first setup |
| `scripts/mdt/Import-WimImages.ps1` | When adding or replacing a WIM |
| `scripts/mdt/New-MDTMedia.ps1` | Every time you want to publish an updated payload |

## Documentation

- [MDT Setup Guide](docs/MDT.md) — full walkthrough, driver integration, Dell CCTK, troubleshooting

## License

[MIT](LICENSE)
