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
- Need unattended deployment (single-disk wipe + image apply + unattend.xml + optional TPM+PIN BitLocker on first boot)
- Are comfortable reading PowerShell and taking responsibility for the
  target disk

**Don't use this if you:**
- Need network-based (PXE / WDS / MDT / SCCM) deployment — use MDT/ConfigMgr
- Expect Windows Sandbox / Hyper-V / dev-VM provisioning — wrong scope

## How This Tool Is Used

Three loops, each runs at a different cadence. Skim this once so the
rest of the README makes sense.

| Loop | When | Where | What |
|------|------|-------|------|
| **A. One-time setup** | First time on a new admin workstation, or once per WinPE rev | Admin Windows + ADK | Install ADK, clone repo, partition the USB, build `boot.wim`, xcopy media. ~30 min. |
| **B. Per-image refresh** | New Windows ISO drops, or you want a different debloat profile | Admin Windows | `scripts/refresh_usb.ps1 -SourceIso ...` → produces a `.wim` on the IMAGES partition. ~10–20 min per image. |
| **C. Per-machine deploy** | Every target laptop / desktop | The USB itself | Plug in, boot from USB. If `deploy.args` is on the USB it runs unattended; otherwise the TUI prompts. ~5–10 min per machine. |

Loops A and B run on **your admin workstation** with ADK installed.
Loop C runs **inside WinPE** on the target hardware.

## Loop A — One-Time Setup (~30 min)

Do this once per admin workstation. You won't repeat it until you
need a new WinPE revision.

### A1. Install the Windows ADK + WinPE add-on

Download from [Microsoft's ADK page](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install).
Install only the **Deployment Tools** feature, then install the
**Windows PE add-on** to the same path.

### A2. Clone the repo on your admin workstation

```powershell
git clone https://github.com/spacebass11/WinPE.git
cd WinPE
```

### A3. Partition the USB (32 GB+ recommended)

Open `diskpart` as Administrator. **This erases the USB.**

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

### A4. Build the WinPE boot image onto the USB

Open **Deployment and Imaging Tools Environment** as Administrator
(Start menu → Windows Kits), then from the repo root:

```powershell
.\scripts\build_boot_wim.ps1 -Clean -UsbDrive P: -ReleaseUsbLetter
```

This runs `copype`, installs the required WinPE components, applies
the `NtfsEnableDirCaseSensitivity` registry fix (needed for Windows
Containers layer apply), embeds the deploy script at `X:\scripts\`,
writes a `startnet.cmd` that reads optional per-USB args (see Loop
C below), and xcopies the media to `P:`. `-ReleaseUsbLetter`
releases `P:` afterwards (the USB stays bootable, just no longer
visible in Explorer).

> **Dell fleets:** add `-CctkSource 'C:\Program Files (x86)\Dell\Command Configure\X86_64'`
> to embed CCTK so the deploy can apply BIOS settings (RAID→AHCI,
> passwords, boot order) on each target during deploy.
> See [docs/CCTK.md](docs/CCTK.md).

Done. The USB now boots into WinPE and auto-launches the deploy
script.

---

## Loop B — Per-Image Refresh (~10–20 min)

You're back because Microsoft dropped a new ISO, or because you
need a different debloat profile. Run this on your admin
workstation.

### B1. The simple path

If your USB already exists and you just want to drop a fresher
image on it:

```powershell
.\scripts\refresh_usb.ps1 -SourceIso 'D:\iso\Win11_24H2_English_x64.iso'
```

That mounts the ISO, picks the index you want, debloats the
provisioned AppX list, optionally injects drivers and policy
tweaks, and writes the resulting `.wim` to `I:\images\` on the
USB. Output filename is derived from the ISO name.

### B2. The full path (when you need to be explicit)

```powershell
.\scripts\prepare_wim.ps1 `
    -SourceIso       'D:\iso\Win11_24H2_English_x64.iso' `
    -OutputWim       'I:\images\Win11_Enterprise.wim' `
    -DriverPath      'C:\Drivers\OptiPlex7090' `
    -DisableExtraBloat
```

| Flag | Effect |
|------|--------|
| `-SourceIso` *or* `-SourceWim` | Start from a stock Windows ISO **or** an already-captured reference WIM. |
| `-OutputWim` | Where to write the cleaned WIM. Drop it on the IMAGES partition. |
| `-Index N` | Which image in the source to customize (when multi-edition). |
| `-Edition 'Windows 11 Enterprise'` | Name-based alternative to `-Index`. |
| `-DriverPath C:\Drivers\Model` | Pre-bake `.inf` drivers offline. **Recommended for 1–2 hardware models.** See "Driver Strategy" below. |
| `-DisableCopilot` | Single policy tweak — turn off Copilot. |
| `-DisableExtraBloat` | Superset of `-DisableCopilot` plus 7 more HKLM policy tweaks (Recall, Widgets, Bing-in-Start, telemetry, consumer apps, Edge first-run, Teams Consumer Chat). Also stages `first-login.ps1` for per-user HKCU tweaks. |
| `-WhitelistFile path\to\list.txt` | Override the default AppX whitelist (one DisplayName per line). |

### B3. Driver strategy

| Situation | What to do |
|-----------|------------|
| 1–2 hardware models | **Pre-inject.** Build one WIM per model. Smaller, faster deploy, no surprises. Use `-DriverPath` per model. |
| 3+ hardware models | One WIM with the common driver classes (chipset, NIC, storage). Vendor-specific drivers stay out — Windows Update or post-deploy fills them. |
| Mixed laptop + desktop | Two WIMs, even if it's only two models. Mismatched drivers cause boot loops. |

### B4. Unattend / first-boot automation

Copy [`configs/unattend.example.xml`](configs/unattend.example.xml) to your USB
(e.g. `I:\configs\unattend.xml`), edit it per [docs/UNATTEND.md](docs/UNATTEND.md)
(account creation, OOBE skip, autologon, FirstLogonCommands), and reference it
from `deploy.args` (see Loop C) as `-UnattendFile I:\configs\unattend.xml`.

The example XML includes a base64 password helper and references
`first-login.ps1` for the per-user tweaks that `prepare_wim.ps1
-DisableExtraBloat` stages into the image.

---

## Loop C — Per-Machine Deploy (~5–10 min)

This happens at the workbench, not on your admin workstation.

### C1. Configure the per-USB deploy.args (optional but recommended)

Drop a one-line `deploy.args` file at the root of the IMAGES
partition. The bootloader reads it and runs the deploy script with
those parameters — no `boot.wim` rebuild. Without the file the
script boots into the interactive TUI.

Copy [`configs/deploy.args.example`](configs/deploy.args.example) to
the IMAGES partition root as `deploy.args` and edit:

```text
-WimFile "I:\images\Win11_Enterprise.wim" -TargetDisk 0 -UnattendFile "I:\configs\unattend.xml" -DataDiskNumber 1 -EnableBitLocker -BitLockerPin "ReplaceWithYourPin42" -Force -Silent
```

See [docs/DEPLOY_ARGS.md](docs/DEPLOY_ARGS.md) for the full reference
and the security caveat (PIN sits in plaintext on the USB — same
trust model as the CCTK passwords).

### C2. Boot from USB

1. Plug the USB into the target machine.
2. Boot from USB in **UEFI mode** (typically F12 → "UEFI: USB …").
3. If `deploy.args` is present, the deploy runs unattended. Otherwise
   you'll be prompted for image → edition → target disk → typed
   confirmations.
4. When complete, remove USB and reboot.

### C3. What runs on first boot (post-deploy)

If your `deploy.args` includes the right flags:

| Trigger | Behavior on first POST after deploy |
|---------|-------------------------------------|
| CCTK embedded + matching config on USB | BIOS settings applied (RAID→AHCI, passwords, etc). |
| `-UnattendFile` set | OOBE skipped, accounts created, computer name set, autologon (if configured), `FirstLogonCommands` runs `first-login.ps1` for per-user tweaks. |
| `-EnableBitLocker -BitLockerPin` set | `SetupComplete.cmd` enables TPM+PIN on `C:` (and recovery-key + auto-unlock on `D:` if `-DataDiskNumber` set), escrows recovery keys to `<IMAGES>\BitLockerKeys`, self-deletes the staging scripts, reboots. |

---

## Manual / Interactive Use

You don't need `deploy.args` to use the tool. If the file is absent
the script runs interactively. You can also run it manually from a
WinPE console (or a normal Windows console, for testing):

```powershell
# Auto-discover images on all drives (the default WinPE flow)
.\unified_winpe_deploy.ps1

# Specific image, interactive disk + edition selection
.\unified_winpe_deploy.ps1 -WimFile "I:\images\Win11.wim"

# List available images without deploying
.\unified_winpe_deploy.ps1 -ListOnly

# Fully automated, single-disk (no data partition, no BitLocker):
.\unified_winpe_deploy.ps1 `
    -WimFile      "I:\images\Win11.wim" `
    -TargetDisk   0 `
    -UnattendFile "I:\configs\unattend.xml" `
    -Force -Silent

# Fully automated, dual-disk with BitLocker (the full v4.7.0 stack):
.\unified_winpe_deploy.ps1 `
    -WimFile         "I:\images\Win11_Enterprise.wim" `
    -TargetDisk      0 `
    -UnattendFile    "I:\configs\unattend.xml" `
    -DataDiskNumber  1 `
    -EnableBitLocker `
    -BitLockerPin    'YourRealPin42' `
    -Force -Silent
```

---

## Distributing To Operators

When you need someone else (a field tech, a remote operator) to
prep a USB without installing ADK on their machine:

1. **You** (the admin) build the boot.wim and one or more WIM
   images on your workstation as described in Loop A + Loop B.
2. **Bundle** the contents of the prepared USB into a zip:
   `boot.wim` media, `images/`, `configs/`, `cctk/` (if used), and
   the `deploy.args` template.
3. **Ship** the zip + a 1-page PDF that says "extract this onto
   your USB partitions exactly like the layout below, then plug
   it into the target and boot." Use the [USB Drive Layout](#usb-drive-layout-reference)
   diagram below as the visual.
4. **Operator** does not need ADK, does not need PowerShell
   skills, does not need to read this README. They just need
   `diskpart` (built into Windows) and 10 minutes.

A wrapper script (`MAKE_USB.ps1`) that does the partition + xcopy
step in one operator-friendly command is on the roadmap but not
yet implemented.

> **Don't use Rufus + bootable ISO** for this. ISOs are read-only;
> you'd lose the dual-partition / `deploy.args` per-USB
> customization model and have to rebuild `boot.wim` for every
> deploy variant. Stay with the dual-partition layout.

---

## USB Drive Layout (reference)

```
USB Drive (32 GB+ recommended)
├── Partition 1: WinPE Boot (FAT32, ~2 GB, label "WinPE")
│   └── Contains WinPE media + startnet.cmd
│
└── Partition 2: Data (NTFS, remaining space, label "IMAGES")
    ├── deploy.args              ← optional one-line params file (Loop C)
    ├── images/
    │   ├── Win11_Pro_24H2.wim
    │   ├── Win10_Enterprise_LTSC.wim
    │   └── (any .wim or .esd files)
    ├── configs/                 ← unattend.xml answer files
    │   └── unattend.xml         (referenced via -UnattendFile)
    ├── cctk/                    ← Dell BIOS configs (optional)
    │   ├── default.ini          ← catch-all
    │   ├── <SERVICETAG>.ini     ← per-machine override
    │   └── <MODEL>.ini          ← per-model override
    └── BitLockerKeys/           ← auto-created when -EnableBitLocker used
        └── <hostname-or-tag>/   ← BitLocker recovery key escrow
```

See [docs/USB_SETUP.md](docs/USB_SETUP.md) for step-by-step
partitioning instructions.

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-ImagePath` | String | Directory to search for images (skips drive scanning) |
| `-WimFile` | String | Direct path to a `.wim`/`.esd` file |
| `-TargetDisk` | Int | Disk number to deploy to (skips disk selection) |
| `-WipeDisks` | String | Comma-separated disk numbers to *also* wipe (clean-only) alongside the primary target (e.g. `"1,2"`). Requires `-Force` in silent mode. |
| `-MinImageSizeMB` | Int | Auto-discovery minimum image size in MB (default 100). Lower for small lab images. |
| `-UnattendFile` | String | Path to an `unattend.xml` answer file. Copied to `C:\Windows\Panther\unattend.xml` post-apply so Windows Setup processes it on first boot (OOBE skip, domain join, etc.). |
| `-DataDiskNumber` | Int | Disk number of an additional internal drive to wipe and format as an NTFS data volume (`D:`). Off by default (`-1`). Requires a typed `WIPE DATA` confirmation. See [docs/BITLOCKER.md](docs/BITLOCKER.md). |
| `-EnableBitLocker` | Switch | Stage `SetupComplete.cmd` to enable BitLocker on first boot (TPM + Enhanced PIN on `C:`, recovery key + auto-unlock on `D:` when `-DataDiskNumber` is set). Requires `-BitLockerPin`. |
| `-BitLockerPin` | String | Startup PIN for the TPM+PIN protector on `C:`. Required when `-EnableBitLocker` is set. 6-20 characters; placeholder PINs (`ChangeMe123!`, etc.) are rejected. |
| `-BitLockerKeyPath` | String | Optional override for recovery-key escrow. Default: `<IMAGES>\BitLockerKeys`. Use a UNC share or removable-media path for centralized escrow. |
| `-Force` | Switch | Skip the typed `ERASE` / `WIPE ALL` / `WIPE DATA` confirmations. Never bypasses `DESTROY SYSTEM`. |
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
- System memory validation (8 GB+ recommended)
- Excludes USB drives from target disk list
- System disk detection with red warning
- **Typed-confirmation chain** for every destructive operation:
  - Type `DESTROY SYSTEM` for the system disk (NEVER bypassed by `-Force`)
  - Type `ERASE` for the primary target
  - Type `WIPE ALL` for the additional-wipe disks (`-WipeDisks`)
  - Type `WIPE DATA` for the data-disk format (`-DataDiskNumber`)
- Placeholder BitLocker PINs (`ChangeMe123!` and a handful of common
  weak strings) are rejected at runtime, even with `-Force -Silent`.
- Recovery keys escrow off the encrypted volume by default.

## Companion Scripts

| Script | Purpose | Runs On |
|--------|---------|---------|
| `unified_winpe_deploy.ps1` | The deploy tool. Wipes target, applies WIM, configures UEFI boot. | Inside WinPE (booted from USB) |
| `scripts/build_boot_wim.ps1` | Builds the WinPE `boot.wim` with the right components, the `NtfsEnableDirCaseSensitivity` reg tweak, and optionally embedded Dell CCTK. | Admin Windows workstation (ADK installed) |
| `scripts/prepare_wim.ps1` | Takes a stock Windows ISO, debloats provisioned AppX with a whitelist, optionally disables Copilot, exports a clean WIM ready to deploy. | Admin Windows workstation |
| `scripts/refresh_usb.ps1` | Thin workflow wrapper: new ISO -> prep + (optional) boot.wim rebuild. | Admin Windows workstation |
| `tests/test_parse.ps1` | Syntax validation for all scripts above. Used by CI. | Any host with PowerShell |

## Documentation

- [USB Setup Guide](docs/USB_SETUP.md) - Preparing the bootable USB drive
- [Script Reference](docs/SCRIPT_REFERENCE.md) - Detailed function and parameter docs
- [Architecture](docs/ARCHITECTURE.md) - Design rationale and data flow
- [BIOS Configuration (CCTK)](docs/CCTK.md) - Pre-apply BIOS setup for Dell fleets
- [BitLocker / data-disk setup](docs/BITLOCKER.md) - Opt-in encrypted first-boot config
- [Per-USB deploy.args](docs/DEPLOY_ARGS.md) - Drop a one-line params file on the USB to retarget without rebuilding boot.wim
- [Code Signing](docs/SIGNING.md) - Signing the script for enterprise use
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues and solutions
- [Known Issues](docs/TROUBLESHOOTING.md#known-caveats) - Intentional design choices and environmental constraints
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
2. Run the local syntax validator:
   ```powershell
   pwsh -NoProfile -File ./tests/test_parse.ps1
   ```
   CI runs PSScriptAnalyzer + the masterize doc / safety greps on push;
   no need to replicate those locally.
3. Describe manual test coverage in the PR template — CI only verifies
   syntax and static analysis, not real WinPE behavior.

## License

[MIT](LICENSE) — © 2026 spacebass11. You use this tool at your own risk;
see the license for the full disclaimer of warranty.

## Version

**v4.7.0** - BitLocker / data-disk feature reworked to opt-in: new
`-DataDiskNumber`, `-EnableBitLocker`, `-BitLockerPin`,
`-BitLockerKeyPath` parameters. Default no longer wipes a hardcoded
second disk; recovery keys escrow to the IMAGES partition (or a
caller-supplied path) instead of the encrypted volume. Placeholder
PINs are rejected at runtime. See [docs/BITLOCKER.md](docs/BITLOCKER.md).

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
