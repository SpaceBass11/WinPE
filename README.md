# WinPE Image Deployment Tool

[![CI](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml/badge.svg)](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://learn.microsoft.com/powershell/)
[![Platform: WinPE](https://img.shields.io/badge/Platform-WinPE-informational.svg)](https://learn.microsoft.com/windows-hardware/manufacture/desktop/winpe-intro)

A PowerShell-based Windows deployment tool built around a simple end-user goal: **download an ISO, flash it to USB with Rufus, boot it, follow the prompts.** No IT background required on the receiving end.

Designed for air-gapped, rebuild-oriented environments — Windows 11 Enterprise, Dell enterprise hardware, DISA STIG-oriented imaging, and security-hardened deployments.

> [!WARNING]
> **This tool wipes entire disks.** It calls `diskpart clean` on the target disk, which is irreversible. Always double-check the selected disk number and never run with `-Force -Silent` on a host you have not explicitly targeted. There is no undo.

---

## How This Was Built

This repository is **AI-authored**. The code is written by [Claude](https://claude.ai) (Anthropic) based on my requirements, domain knowledge, and iterative feedback. I'm not a PowerShell developer — I provide the deployment context, define the workflows, and test against real hardware. Claude writes the code.

If you're auditing this for production use, read it yourself. I do, but I'm not the one who wrote it. The CI pipeline runs syntax validation and static analysis on every push, and the safety confirmation design is deliberate — but independent review is always warranted for tooling that wipes disks.

---

## Who This Is For

**End users (the people receiving the USB):**
You don't need to read this README. You need the PDF guide included with your ISO. The short version: download the ISO → open Rufus → select the ISO → flash to USB → boot from USB → follow the on-screen prompts.

**Admins (the people building and distributing the USB):**
This README is for you. You build the ISO once, distribute it, and end users handle the rest. No ADK on their machine, no PowerShell knowledge, no network dependency.

**Don't use this if you:**
- Need network-based deployment (PXE / WDS / MDT / SCCM) — use MDT or ConfigMgr
- Need Windows Sandbox / Hyper-V / dev-VM provisioning — wrong scope

---

## The Two Workflows

Everything in this repo feeds one of two workflows.

| Workflow | Who runs it | When |
|----------|-------------|------|
| **Build** | Admin workstation (ADK installed) | Once per WinPE revision, once per new Windows ISO |
| **Deploy** | Anyone with the USB | Every target machine |

The build side produces a bootable ISO. The deploy side is that ISO flashed to a USB stick.

---

## Build Workflow (Admin Side)

Three steps, each at a different cadence.

### Step 1 — Install the Windows ADK + WinPE add-on

Download from [Microsoft's ADK page](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install).
Install only the **Deployment Tools** feature, then install the **Windows PE add-on** to the same path.

### Step 2 — Prep a clean Windows image (per ISO)

Run this on your admin workstation when a new Windows ISO drops or you want a different debloat profile:

```powershell
.\scripts\prepare_wim.ps1 `
    -SourceIso  'D:\iso\Win11_24H2_English_x64.iso' `
    -OutputWim  'D:\staging\Win11_Enterprise.wim'
```

Or use the wrapper for the common case:

```powershell
.\scripts\refresh_usb.ps1 -SourceIso 'D:\iso\Win11_24H2_English_x64.iso'
```

| Flag | Effect |
|------|--------|
| `-SourceIso` *or* `-SourceWim` | Start from a stock Windows ISO or an already-captured WIM |
| `-OutputWim` | Where to write the cleaned WIM |
| `-Index N` | Which image index to use from a multi-edition source |
| `-Edition 'Windows 11 Enterprise'` | Name-based alternative to `-Index` |
| `-DriverPath C:\Drivers\Model` | Pre-bake `.inf` drivers offline — recommended for 1–2 hardware models |
| `-DisableCopilot` | Single policy tweak — disable Copilot |
| `-DisableExtraBloat` | Broader policy set: Copilot, Recall, Widgets, Bing-in-Start, telemetry, consumer apps, Edge first-run, Teams Consumer Chat. Also stages `first-login.ps1` for per-user tweaks. |
| `-WhitelistFile path\to\list.txt` | Override the default AppX whitelist |

**Driver strategy:**

| Situation | Recommendation |
|-----------|----------------|
| 1–2 hardware models | Pre-inject with `-DriverPath`. Build one WIM per model. |
| 3+ hardware models | One WIM with common drivers (chipset, NIC, storage). Let Windows Update fill vendor-specific. |
| Mixed laptop + desktop | Two WIMs even if it's only two models — mismatched drivers cause boot loops. |

### Step 3 — Build the WinPE boot image (per WinPE revision)

Open **Deployment and Imaging Tools Environment** as Administrator (Start → Windows Kits), then:

```powershell
.\scripts\build_boot_wim.ps1 -Clean
```

This installs the required WinPE components, applies the `NtfsEnableDirCaseSensitivity` registry fix (needed for Windows Containers layer apply), and embeds the deploy script.

> **Dell fleets:** add `-CctkSource 'C:\Program Files (x86)\Dell\Command Configure\X86_64'`
> to embed CCTK so the deploy can apply BIOS settings (RAID→AHCI, passwords, boot order) on each target.
> See [docs/CCTK.md](docs/CCTK.md).

### Step 4 — Package everything into a distributable ISO

```powershell
.\scripts\build_iso.ps1 `
    -WimFile     'D:\staging\Win11_Enterprise.wim' `
    -OutputIso   'D:\dist\WinPE_Deploy_Win11.iso'
```

This bundles the WinPE boot image, your Windows WIM, any configs, and optionally a `deploy.args` file into a single bootable ISO. End users download this ISO and flash it with Rufus.

---

## End-User Deploy Workflow

This is what the person receiving the ISO does. The full plain-English version is in [docs/END_USER_DEPLOY.md](docs/END_USER_DEPLOY.md) — that's the document to hand to non-IT staff.

**Short version:**

1. Download the ISO file
2. Download [Rufus](https://rufus.ie) (free, no install required)
3. Plug in a USB drive (32 GB+ recommended)
4. Open Rufus, select the ISO, click START
5. Plug the USB into the target machine and boot from USB (typically F12 → "UEFI: USB …")
6. Follow the on-screen prompts
7. When complete, remove USB and reboot

If the admin pre-configured a `deploy.args` file in the ISO, the deployment runs unattended — the user just waits for it to finish.

---

## Unattended / Silent Mode

For deployments where the end user should not be prompted at all, the admin bakes a `deploy.args` file into the ISO:

```text
-WimFile "I:\images\Win11_Enterprise.wim" -TargetDisk 0 -UnattendFile "I:\configs\unattend.xml" -Force -Silent
```

Full reference: [docs/DEPLOY_ARGS.md](docs/DEPLOY_ARGS.md)

With an unattend file:

| Trigger | Behavior on first boot after deploy |
|---------|-------------------------------------|
| CCTK embedded + matching config | BIOS settings applied (RAID→AHCI, passwords, boot order, etc.) |
| `-UnattendFile` set | OOBE skipped, accounts created, computer name set, autologon, `first-login.ps1` runs per-user tweaks |
| `-EnableBitLocker -BitLockerPin` set | `SetupComplete.cmd` enables TPM+PIN on `C:` (and recovery key + auto-unlock on `D:` if `-DataDiskNumber` set), escrows recovery keys, self-deletes staging scripts, reboots |

See [docs/BITLOCKER.md](docs/BITLOCKER.md) for the full BitLocker setup.

---

## USB Drive Layout (Reference)

The ISO unpacks to this layout on the USB:

```
USB Drive (32 GB+ recommended)
├── Partition 1: WinPE Boot (FAT32, ~2 GB, label "WinPE")
│   └── WinPE media + startnet.cmd
│
└── Partition 2: Data (NTFS, remaining space, label "IMAGES")
    ├── deploy.args              ← optional one-line params (baked in by admin)
    ├── images/
    │   ├── Win11_Enterprise.wim
    │   └── (any .wim or .esd files)
    ├── configs/
    │   └── unattend.xml
    ├── cctk/                    ← Dell BIOS configs (optional)
    │   ├── default.ini
    │   ├── <SERVICETAG>.ini     ← per-machine override
    │   └── <MODEL>.ini          ← per-model override
    └── BitLockerKeys/           ← auto-created when -EnableBitLocker used
```

See [docs/USB_SETUP.md](docs/USB_SETUP.md) for step-by-step partitioning.

---

## Disk Partition Layout Created on Target

The deploy script creates a standard UEFI/GPT layout on the target machine:

| Partition | Size | Format | Letter | Purpose |
|-----------|------|--------|--------|---------|
| EFI System | 300 MB | FAT32 | S: | UEFI boot files |
| MSR | 16 MB | — | — | Microsoft Reserved |
| Primary | Remaining | NTFS | C: | Windows installation |

---

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-ImagePath` | String | Directory to search for images (skips drive scanning) |
| `-WimFile` | String | Direct path to a `.wim`/`.esd` file |
| `-TargetDisk` | Int | Disk number to deploy to (skips disk selection TUI) |
| `-WipeDisks` | String | Comma-separated disk numbers to also wipe (clean-only) alongside the primary target, e.g. `"1,2"`. Requires `-Force` in silent mode. |
| `-MinImageSizeMB` | Int | Auto-discovery minimum image size in MB (default 100) |
| `-UnattendFile` | String | Path to an `unattend.xml` answer file. Copied to `C:\Windows\Panther\` post-apply for first-boot OOBE skip, domain join, etc. |
| `-DataDiskNumber` | Int | Disk number to wipe and format as NTFS `D:`. Off by default (`-1`). Requires a typed `WIPE DATA` confirmation. |
| `-EnableBitLocker` | Switch | Stage `SetupComplete.cmd` to enable BitLocker on first boot. Requires `-BitLockerPin`. |
| `-BitLockerPin` | String | Startup PIN for the TPM+PIN protector on `C:`. 6–20 characters. Placeholder PINs are rejected. |
| `-BitLockerKeyPath` | String | Override recovery-key escrow path. Default: `<IMAGES>\BitLockerKeys`. |
| `-Force` | Switch | Skip typed `ERASE` / `WIPE ALL` / `WIPE DATA` confirmations. **Never bypasses `DESTROY SYSTEM`.** |
| `-Silent` | Switch | Unattended mode. Requires `-WimFile`, `-TargetDisk`, `-Force`, and a single-index image. |
| `-ListOnly` | Switch | Show available images and exit |

---

## Safety Features

- Requires Administrator privileges
- WinPE environment detection
- System memory validation (8 GB+ recommended)
- Excludes USB drives from the target disk list
- System disk detection with red warning
- **Typed-confirmation chain** — every destructive operation requires a specific phrase:
  - `DESTROY SYSTEM` — system disk (never bypassed by `-Force`)
  - `ERASE` — primary target disk
  - `WIPE ALL` — additional-wipe disks (`-WipeDisks`)
  - `WIPE DATA` — data-disk format (`-DataDiskNumber`)
- Placeholder BitLocker PINs (`ChangeMe123!` and similar weak strings) are rejected at runtime, including under `-Force -Silent`
- Recovery keys escrow off the encrypted volume by default

---

## Companion Scripts

| Script | Purpose | Runs On |
|--------|---------|---------|
| `unified_winpe_deploy.ps1` | Core deploy tool — wipes target, applies WIM, configures UEFI boot | WinPE (booted from USB) |
| `scripts/build_iso.ps1` | Packages WinPE + WIM into a single distributable ISO for Rufus | Admin workstation |
| `scripts/build_boot_wim.ps1` | Builds the WinPE `boot.wim` with required components + `NtfsEnableDirCaseSensitivity` reg fix | Admin workstation (ADK required) |
| `scripts/prepare_wim.ps1` | Debloats a stock Windows ISO into a clean `.wim` ready to deploy | Admin workstation |
| `scripts/refresh_usb.ps1` | Wrapper: new ISO → prep + optional boot.wim rebuild | Admin workstation |
| `tests/test_parse.ps1` | Syntax validation for all scripts. Used by CI. | Any host with PowerShell |

---

## Documentation

- [End User Deploy Guide](docs/END_USER_DEPLOY.md) — plain-English Rufus guide for non-IT users
- [USB Setup Guide](docs/USB_SETUP.md) — preparing the bootable USB manually
- [Script Reference](docs/SCRIPT_REFERENCE.md) — full parameter and function docs
- [Architecture](docs/ARCHITECTURE.md) — design rationale and data flow
- [BIOS Configuration (CCTK)](docs/CCTK.md) — pre-apply BIOS setup for Dell fleets
- [BitLocker / Data Disk](docs/BITLOCKER.md) — opt-in encrypted first-boot config
- [Per-USB deploy.args](docs/DEPLOY_ARGS.md) — one-line params file for unattended deploys
- [Code Signing](docs/SIGNING.md) — signing the script for enterprise use
- [Troubleshooting](docs/TROUBLESHOOTING.md) — common issues and solutions
- [Changelog](CHANGELOG.md) — version history
- [Security Policy](SECURITY.md) — reporting vulnerabilities

---

## Requirements

- Windows PE (WinPE) boot environment
- PowerShell 5.1+ (included in WinPE)
- Administrator privileges
- UEFI-capable target system
- USB drive 32 GB+ (8 GB minimum for WinPE + one image)

---

## Contributing

Pull requests welcome, especially hardware-compatibility fixes. Before opening one:

1. Read the safety conventions in [CLAUDE.md](CLAUDE.md) — in particular, never weaken the typed-confirmation chain.
2. Run the local syntax validator:
   ```powershell
   pwsh -NoProfile -File ./tests/test_parse.ps1
   ```
3. Describe manual test coverage in the PR — CI verifies syntax and static analysis, not real WinPE behavior.

---

## License

[MIT](LICENSE) — © 2026 spacebass11. You use this tool at your own risk; see the license for the full disclaimer of warranty.

---

## Version

**v4.7.0** — BitLocker / data-disk feature reworked to opt-in: new `-DataDiskNumber`, `-EnableBitLocker`, `-BitLockerPin`, `-BitLockerKeyPath` parameters. Default no longer wipes a hardcoded second disk. Recovery keys escrow to the IMAGES partition (or a caller-supplied path). Placeholder PINs rejected at runtime. See [docs/BITLOCKER.md](docs/BITLOCKER.md).

**v4.6.0** — Driver injection (`prepare_wim.ps1 -DriverPath`) to pre-bake drivers into the WIM. Unattend.xml staging (`-UnattendFile`) for first-boot OOBE skip, computer name, domain join.

**v4.5.0** — Dell CCTK pre-apply BIOS configuration. Multi-disk wipe stage with `WIPE ALL` confirmation and `-WipeDisks` parameter.

**v4.4.0** — Diskpart resilience, Linux/LVM partition detection, DISM `/CheckIntegrity`, reproducible boot.wim builder with `NtfsEnableDirCaseSensitivity` fix.

See [CHANGELOG.md](CHANGELOG.md) for full history.
