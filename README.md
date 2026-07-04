# WinPE Image Deployment Tool

[![CI](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml/badge.svg)](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://learn.microsoft.com/powershell/)
[![Platform: WinPE](https://img.shields.io/badge/Platform-WinPE-informational.svg)](https://learn.microsoft.com/windows-hardware/manufacture/desktop/winpe-intro)

A PowerShell-based TUI tool for deploying Windows images (`.wim`/`.esd`) from a bootable USB drive in a WinPE environment. Built for IT admins doing bare-metal Windows deployments — air-gapped, security-hardened, Dell enterprise hardware, Windows 11 Enterprise.

**What you get:**

- One USB, many images — pick at deploy time from a TUI
- Unattended pipelines via a per-USB `deploy.args` file (no `boot.wim` rebuild)
- Dell BIOS pre-apply via CCTK (RAID→AHCI, passwords, boot order)
- BitLocker on first boot (TPM+PIN on `C:`, recovery key + auto-unlock on `D:`)
- Unattend.xml staging for OOBE skip, computer name, domain join, autologon
- Optional ISO packaging — when the workflow is dialed in, wrap everything into one file that non-IT end users flash with Rufus

> [!WARNING]
> **This tool wipes entire disks.** It calls `diskpart clean` on the target disk, which is irreversible. Always double-check the selected disk number and never run with `-Force -Silent` on a host you have not explicitly targeted. There is no undo.

> [!IMPORTANT]
> **This repository is AI-authored.** The code is written by [Claude](https://claude.ai) (Anthropic) based on my requirements, domain knowledge, and iterative feedback. I'm not a PowerShell developer — I provide the deployment context, define the workflows, and test against real hardware. Claude writes the code. If you're auditing this for production use, read it yourself — independent review is always warranted for tooling that wipes disks.

---

## Contents

- [Who This Is For](#who-this-is-for)
- [Workflow Overview](#workflow-overview)
- [Loop A — One-Time Setup](#loop-a--one-time-setup-30-min)
- [Loop B — Per-Image Refresh](#loop-b--per-image-refresh-1020-min)
- [Loop C — Per-Machine Deploy](#loop-c--per-machine-deploy-510-min)
- [Streamlined End-User Distribution](#streamlined-end-user-distribution-optional)
- [Direct Script Invocation](#direct-script-invocation)
- [USB Drive Layout](#usb-drive-layout)
- [Disk Partition Layout on Target](#disk-partition-layout-on-target)
- [Parameters](#parameters)
- [Safety Features](#safety-features)
- [Companion Scripts](#companion-scripts)
- [Documentation](#documentation)
- [Requirements](#requirements)
- [Contributing](#contributing)
- [License](#license)

---

## Who This Is For

**Use this if you:**
- Deploy Windows images to bare-metal hardware from a USB stick
- Need a reproducible WinPE build — no hand-edited ISOs, no guesswork
- Want unattended deployment with unattend.xml, Dell BIOS pre-config, or BitLocker on first boot
- Are comfortable reading PowerShell and taking responsibility for the target disk

**Don't use this if you:**
- Need network-based deployment (PXE / WDS / MDT / SCCM) — use MDT or ConfigMgr
- Need Windows Sandbox / Hyper-V / dev-VM provisioning — wrong scope

---

## Workflow Overview

Three loops, each at a different cadence. Skim this once so the rest of the README makes sense.

| Loop | Cadence | Runs On | What It Does |
|------|---------|---------|--------------|
| **A — One-time setup** | Once per admin workstation or WinPE revision | Admin Windows + ADK | Install ADK, partition USB, build `boot.wim`. ~30 min. |
| **B — Per-image refresh** | Each new Windows ISO or debloat profile | Admin Windows | Debloat ISO → clean `.wim` on the IMAGES partition. ~10–20 min. |
| **C — Per-machine deploy** | Every target machine | The USB in WinPE | Boot, select image, confirm, done. ~5–10 min. |

Loops A and B run on **your admin workstation** with ADK installed.
Loop C runs **inside WinPE** on the target hardware.

---

## Loop A — One-Time Setup (~30 min)

Do this once per admin workstation. You won't repeat it until you need a new WinPE revision.

### A1. Install the Windows ADK + WinPE add-on

Download from [Microsoft's ADK page](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install).
Install only the **Deployment Tools** feature, then install the **Windows PE add-on** to the same path.

### A2. Clone the repo

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

Open **Deployment and Imaging Tools Environment** as Administrator — three ways: type **Deploy** in Start (fastest, right-click → Run as administrator); navigate **Start → Windows Kits → Deployment and Imaging Tools Environment**; or open an elevated cmd and run `DandISetEnv.bat` (see USB_SETUP.md) — then from the repo root:

```powershell
.\scripts\build_boot_wim.ps1 -Clean -UsbDrive P: -ReleaseUsbLetter
```

This runs `copype`, installs the required WinPE components, applies the `NtfsEnableDirCaseSensitivity` registry fix (needed for Windows Containers layer apply), embeds the deploy script, writes `startnet.cmd`, and xcopies media to `P:`. `-ReleaseUsbLetter` releases `P:` when done.

> [!TIP]
> **Dell fleets:** add `-CctkSource 'C:\Program Files (x86)\Dell\Command Configure\X86_64'`
> to embed CCTK so each deploy can apply BIOS settings (RAID→AHCI, passwords, boot order) on target hardware.
> See [docs/CCTK.md](docs/CCTK.md).

Done. The USB boots into WinPE and auto-launches the deploy script.

---

## Loop B — Per-Image Refresh (~10–20 min)

Run this when a new Windows ISO drops or you need a different debloat profile.

### B1. The simple path

```powershell
.\scripts\refresh_usb.ps1 -SourceIso 'D:\iso\Win11_24H2_English_x64.iso'
```

Mounts the ISO, picks the index you want, debloats provisioned AppX, optionally injects drivers and policy tweaks, and writes the resulting `.wim` to `I:\images\`.

### B2. The explicit path

```powershell
.\scripts\prepare_wim.ps1 `
    -SourceIso       'D:\iso\Win11_24H2_English_x64.iso' `
    -OutputWim       'I:\images\Win11_Enterprise.wim' `
    -DriverPath      'C:\Drivers\OptiPlex7090' `
    -DisableExtraBloat
```

| Flag | Effect |
|------|--------|
| `-SourceIso` *or* `-SourceWim` | Start from a stock Windows ISO or an already-captured WIM |
| `-OutputWim` | Where to write the cleaned WIM |
| `-Index N` | Which image index to use from a multi-edition source |
| `-Edition 'Windows 11 Enterprise'` | Name-based alternative to `-Index` |
| `-DriverPath C:\Drivers\Model` | Pre-bake `.inf` drivers offline — recommended for 1–2 hardware models |
| `-DisableCopilot` | Single policy tweak — disable Copilot |
| `-DisableExtraBloat` | Broader policy set: Copilot, Recall, Widgets, Bing-in-Start, telemetry, consumer apps, Edge first-run, Teams Consumer Chat. Also stages `first-login.ps1` for per-user HKCU tweaks. |
| `-WhitelistFile path\to\list.txt` | Override the default AppX whitelist |

### B3. Driver strategy

| Situation | Recommendation |
|-----------|----------------|
| 1–2 hardware models | Pre-inject with `-DriverPath`. One WIM per model. Smaller, faster, no surprises. |
| 3+ hardware models | One WIM with common drivers (chipset, NIC, storage). Let Windows Update fill vendor-specific. |
| Mixed laptop + desktop | Two WIMs even if it's only two models — mismatched drivers cause boot loops. |

### B4. Unattend / first-boot automation

Copy [`configs/unattend.example.xml`](configs/unattend.example.xml) to your USB, edit per [docs/UNATTEND.md](docs/UNATTEND.md) (account creation, OOBE skip, autologon, `FirstLogonCommands`), and reference it from `deploy.args` as `-UnattendFile I:\configs\unattend.xml`.

---

## Loop C — Per-Machine Deploy (~5–10 min)

### C1. Configure deploy.args (optional but recommended)

Drop a one-line `deploy.args` file at the root of the IMAGES partition. The bootloader reads it and passes those parameters to the deploy script — no `boot.wim` rebuild required. Without the file, the script runs the interactive TUI.

Copy [`configs/deploy.args.example`](configs/deploy.args.example) and edit. The example below is the **air-gapped operator USB pattern** — full silent deploy with a pre-staged BitLocker PIN. The USB itself becomes the credential. See [docs/BITLOCKER.md](docs/BITLOCKER.md) for the trade-offs (USB-as-credential, unique PIN per batch, physical-handling expectations):

```text
-WimFile "I:\images\Win11_Enterprise.wim" -TargetDisk 0 -UnattendFile "I:\configs\unattend.xml" -DataDiskNumber 1 -EnableBitLocker -BitLockerPin "YourRealPin42" -Force -Silent
```

See [docs/DEPLOY_ARGS.md](docs/DEPLOY_ARGS.md) for the full parameter reference.

### C2. Boot from USB

1. Plug the USB into the target machine
2. Boot from USB in **UEFI mode** (typically F12 → "UEFI: USB …")
3. If `deploy.args` is present, the deploy runs unattended — otherwise the TUI prompts for image → edition → target disk → confirmations
4. When complete, remove USB and reboot — **unless you're using BitLocker with default escrow** (see note below)

> [!IMPORTANT]
> **Keep the USB plugged in through the first reboot when `-EnableBitLocker` is used *without* `-BitLockerKeyPath`.** The recovery key escrows to the IMAGES partition on first boot. If you pull the USB before then, the staged script falls back to writing the key to `C:\Windows\Setup\BitLockerKeys` — on the volume it's protecting — with only a log warning. Use `-BitLockerKeyPath \\fileserver\share` to escrow over the network instead and pull the USB normally.

### C3. What happens on first boot

| Trigger | Behavior |
|---------|----------|
| CCTK embedded + matching config on USB | BIOS settings applied (RAID→AHCI, passwords, boot order) |
| `-UnattendFile` set | OOBE skipped, accounts created, computer name set, autologon (if configured), `first-login.ps1` runs per-user tweaks |
| `-EnableBitLocker -BitLockerPin` set | `SetupComplete.cmd` enables TPM+PIN on `C:`, recovery key + auto-unlock on `D:` if `-DataDiskNumber` set, keys escrow to `<IMAGES>\BitLockerKeys`, staging scripts self-delete, machine reboots |

---

## Streamlined End-User Distribution (Optional)

Once the workflow is dialed in, you can package everything into a single distributable ISO. This is the path for handing a deployment to **non-IT end users — remote, worldwide, no technical background required.**

### Package into an ISO

```powershell
.\scripts\build_iso.ps1 `
    -WimFile   'I:\images\Win11_Enterprise.wim' `
    -OutputIso 'D:\dist\WinPE_Deploy_Win11.iso' `
    -ConfirmSilentDestructiveIso
```

This bundles the WinPE boot image, your Windows WIM, configs, and any `deploy.args` into one bootable ISO. Bake in a pre-configured `deploy.args` if you want fully unattended operation on the receiving end.

The `-ConfirmSilentDestructiveIso` switch is **mandatory** when building a silent ISO. It acknowledges that the resulting ISO will wipe whichever physical disk Windows enumerates as `-TargetDisk` (default: `0`) on the end-user's machine, with **no operator confirmation**. Use `-Interactive` instead to build an ISO that prompts the operator for disk selection and confirmations.

### What end users do

1. Download the ISO
2. Download [Rufus](https://rufus.ie) — free, no install required
3. Plug in a USB drive (32 GB+)
4. Open Rufus, select the ISO, click START
5. Boot the target machine from USB (F12 → "UEFI: USB …")
6. Follow the on-screen prompts — or just wait if it's unattended
7. Remove USB and reboot when done

> [!TIP]
> If your packaged `deploy.args` enables BitLocker with default escrow, the on-screen prompt at the end will tell the user to leave the USB plugged in through the next reboot, then remove it. For zero-touch builds where the USB must come out immediately, pre-bake `-BitLockerKeyPath \\share\path` (UNC escrow) into the `deploy.args` so escrow doesn't depend on the USB at first boot.

The full plain-English guide is in [docs/END_USER_DEPLOY.md](docs/END_USER_DEPLOY.md) — include that PDF alongside the ISO download.

---

## Direct Script Invocation

Without a `deploy.args` file, the script falls back to an interactive TUI. The examples below show calling the script directly — useful for testing on an admin workstation or running it from the WinPE console.

```powershell
# Auto-discover images on all drives (standard WinPE flow)
.\unified_winpe_deploy.ps1

# Target a specific image, interactive disk + edition selection
.\unified_winpe_deploy.ps1 -WimFile "I:\images\Win11.wim"

# List available images without deploying
.\unified_winpe_deploy.ps1 -ListOnly

# Fully automated, single-disk
.\unified_winpe_deploy.ps1 `
    -WimFile      "I:\images\Win11.wim" `
    -TargetDisk   0 `
    -UnattendFile "I:\configs\unattend.xml" `
    -Force -Silent

# Fully automated, dual-disk with BitLocker
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

## USB Drive Layout

```
USB Drive (32 GB+ recommended)
├── Partition 1: WinPE Boot (FAT32, ~2 GB, label "WinPE")
│   └── WinPE media + startnet.cmd
│
└── Partition 2: Data (NTFS, remaining space, label "IMAGES")
    ├── deploy.args              ← optional one-line params file
    ├── images/
    │   ├── Win11_Pro_24H2.wim
    │   ├── Win10_Enterprise_LTSC.wim
    │   └── (any .wim or .esd files)
    ├── configs/
    │   └── unattend.xml
    ├── cctk/                    ← Dell BIOS configs (optional)
    │   ├── default.ini
    │   ├── <SERVICETAG>.ini     ← per-machine override
    │   └── <MODEL>.ini          ← per-model override
    └── BitLockerKeys/           ← auto-created when -EnableBitLocker used
        └── <hostname>/          ← recovery key escrow
```

See [docs/USB_SETUP.md](docs/USB_SETUP.md) for step-by-step partitioning instructions.

---

## Disk Partition Layout on Target

The deploy script creates a standard UEFI/GPT layout on the target machine:

| Partition | Size | Format | Drive Letter | Purpose |
|-----------|------|--------|--------------|---------|
| EFI System | 300 MB | FAT32 | S: | UEFI boot files |
| MSR | 16 MB | — | — | Microsoft Reserved |
| Primary | Remaining | NTFS | C: | Windows installation |

---

## Parameters

Full reference with examples lives in [docs/SCRIPT_REFERENCE.md](docs/SCRIPT_REFERENCE.md). Grouped here for quick scanning.

### Image selection

| Parameter | Type | Description |
|-----------|------|-------------|
| `-WimFile` | String | Direct path to a `.wim`/`.esd` file |
| `-ImagePath` | String | Directory to search for images (skips drive scanning) |
| `-MinImageSizeMB` | Int | Auto-discovery minimum image size in MB (default: 100) |
| `-ListOnly` | Switch | Show available images and exit |

### Target disk

| Parameter | Type | Description |
|-----------|------|-------------|
| `-TargetDisk` | Int | Disk number to deploy to (skips disk selection TUI) |
| `-WipeDisks` | String | Comma-separated disk numbers to also wipe (clean-only) alongside the primary target, e.g. `"1,2"`. Requires `-Force` in silent mode. |

### Automation

| Parameter | Type | Description |
|-----------|------|-------------|
| `-Force` | Switch | Skip typed `ERASE` / `WIPE ALL` / `WIPE DATA` confirmations. **Never bypasses `DESTROY SYSTEM`.** |
| `-Silent` | Switch | Unattended mode. Requires `-WimFile`, `-TargetDisk`, `-Force`, and a single-index image. |

### First-boot staging

| Parameter | Type | Description |
|-----------|------|-------------|
| `-UnattendFile` | String | Path to `unattend.xml`. Copied to `C:\Windows\Panther\` post-apply for first-boot OOBE skip, domain join, etc. |

### BitLocker / data disk (opt-in)

| Parameter | Type | Description |
|-----------|------|-------------|
| `-DataDiskNumber` | Int | Disk number to wipe and format as NTFS `D:`. Off by default (`-1`). Requires typed `WIPE DATA` confirmation. |
| `-EnableBitLocker` | Switch | Stage `SetupComplete.cmd` to enable BitLocker on first boot. Requires `-BitLockerPin`. |
| `-BitLockerPin` | String | Startup PIN for the TPM+PIN protector on `C:`. 6–20 characters. PIN content is the admin's call — only the Windows length window is enforced. |
| `-BitLockerKeyPath` | String | Override recovery-key escrow path. Default: `<IMAGES>\BitLockerKeys`. |

---

## Safety Features

### Environment checks

Two distinct checks with different purposes — and different behaviors.

| Check | Behavior | Why |
|-------|----------|-----|
| Administrator privileges | **Hard stop** | `diskpart`, DISM, and BCDBoot all require elevation. Always satisfied in WinPE; the check prevents partial execution on a live Windows host. |
| Running inside WinPE | **Soft warning** | Running outside WinPE has legitimate uses (testing, recovery), so the script only warns and prompts. It's a reminder that disk operations are about to hit a running system. |

### Disk protection

- USB drives are excluded from the target list — the boot USB can't be accidentally selected
- System memory is validated (warns if < 8 GB; WinPE runs entirely in RAM)
- System-disk detection — if `$env:SystemDrive` is selected as the target, the prompt requires typing `DESTROY SYSTEM`, which `-Force` never bypasses

> [!IMPORTANT]
> In WinPE, `$env:SystemDrive` is **always `X:` (the RAM disk)**, so a laptop's existing Windows install on disk 0 is just a regular disk to the script. It triggers only the normal `ERASE` confirmation — which `-Force` **does** bypass. The `DESTROY SYSTEM` guard primarily protects you when running the script on a live Windows host outside WinPE.

### Typed-confirmation chain

Every destructive operation requires a specific typed phrase:

| Phrase | Triggers On | Bypassable by `-Force`? |
|--------|-------------|------------------------|
| `DESTROY SYSTEM` | System disk | **No — never** |
| `ERASE` | Primary target disk | Yes |
| `WIPE ALL` | Additional wipe disks (`-WipeDisks`) | Yes |
| `WIPE DATA` | Data disk format (`-DataDiskNumber`) | Yes |

### BitLocker guardrails

- PIN content is the admin's call — the script enforces only Windows' 6-20 character window (Enhanced PIN policy is enabled in the staged first-boot script, so any alphanumeric/symbol within that window is accepted)
- Recovery keys escrow off the encrypted volume by default — to the IMAGES partition, resolved by volume label at first boot so it survives Windows reassigning the USB drive letter
- If the IMAGES partition can't be found at first boot (USB unplugged), escrow falls back to `C:\Windows\Setup\BitLockerKeys` (on the encrypted volume) with a loud log warning — verify `C:\Windows\Setup\Scripts\bitlocker-setup.log` after first reboot
- Use `-BitLockerKeyPath \\fileserver\share` for centralized escrow that doesn't depend on the USB staying plugged in

---

## Companion Scripts

| Script | What It Does | Runs On |
|--------|-------------|---------|
| `unified_winpe_deploy.ps1` | Core deploy — wipes target, applies WIM, configures UEFI boot | WinPE (booted from USB) |
| `scripts/build_iso.ps1` | Packages WinPE + WIM into a distributable ISO for Rufus | Admin workstation |
| `scripts/build_boot_wim.ps1` | Builds `boot.wim` with required WinPE components + `NtfsEnableDirCaseSensitivity` reg fix | Admin workstation (ADK required) |
| `scripts/prepare_wim.ps1` | Debloats a stock Windows ISO into a clean `.wim` | Admin workstation |
| `scripts/refresh_usb.ps1` | Thin wrapper: new ISO → prep + optional boot.wim rebuild | Admin workstation |
| `tests/test_parse.ps1` | Syntax validation for all scripts — used by CI | Any host with PowerShell |

---

## Documentation

**For admins building and maintaining the USB:**
- [USB Setup Guide](docs/USB_SETUP.md) — partitioning the drive manually
- [Script Reference](docs/SCRIPT_REFERENCE.md) — full parameter and function docs
- [Architecture](docs/ARCHITECTURE.md) — design rationale and data flow
- [Per-USB deploy.args](docs/DEPLOY_ARGS.md) — one-line params file for unattended deploys
- [BIOS Configuration (CCTK)](docs/CCTK.md) — Dell fleet pre-apply BIOS setup
- [BitLocker / Data Disk](docs/BITLOCKER.md) — opt-in encrypted first-boot config
- [Code Signing](docs/SIGNING.md) — signing the script for enterprise environments
- [Release Validation](docs/RELEASE_VALIDATION.md) — pre-distribution checklist for hardware/runtime behavior CI can't verify

**For end users receiving the USB or ISO:**
- [End User Deploy Guide](docs/END_USER_DEPLOY.md) — plain-English Rufus guide for non-IT users

**Reference:**
- [Troubleshooting](docs/TROUBLESHOOTING.md) — common issues and solutions
- [Changelog](CHANGELOG.md) — version history
- [Security Policy](SECURITY.md) — reporting vulnerabilities

---

## Requirements

| Requirement | Notes |
|-------------|-------|
| Windows PE (WinPE) | The runtime environment — script runs inside WinPE on boot |
| PowerShell 5.1+ | Included in WinPE — no separate install needed |
| Administrator privileges | Always satisfied in WinPE; required explicitly on live hosts |
| UEFI-capable target system | GPT + UEFI layout only — legacy BIOS/MBR not supported |
| USB drive 32 GB+ | 8 GB minimum for WinPE + one image; 32 GB comfortable for multiple |

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

Current version: **v4.7.1** — see [CHANGELOG.md](CHANGELOG.md) for full history.
