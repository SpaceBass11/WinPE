# WinPE Image Deployment Tool

[![CI](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml/badge.svg)](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://learn.microsoft.com/powershell/)
[![Platform: WinPE](https://img.shields.io/badge/Platform-WinPE-informational.svg)](https://learn.microsoft.com/windows-hardware/manufacture/desktop/winpe-intro)

A PowerShell-based TUI tool for deploying Windows images (`.wim`/`.esd`) from a bootable USB drive in a WinPE environment. Built for IT admins and engineers doing bare-metal Windows deployments — air-gapped, security-hardened, Dell enterprise hardware, Windows 11 Enterprise.

The full workflow supports multiple images on one USB, unattended pipelines, Dell BIOS pre-configuration, BitLocker orchestration, and unattend.xml staging. When you're done building and want to hand it off to non-IT end users, the optional ISO packaging step wraps everything into a single file they flash with Rufus.

> [!WARNING]
> **This tool wipes entire disks.** It calls `diskpart clean` on the target disk, which is irreversible. Always double-check the selected disk number and never run with `-Force -Silent` on a host you have not explicitly targeted. There is no undo.

> [!IMPORTANT]
> **This repository is AI-authored.** The code is written by [Claude](https://claude.ai) (Anthropic) based on my requirements, domain knowledge, and iterative feedback. I'm not a PowerShell developer — I provide the deployment context, define the workflows, and test against real hardware. Claude writes the code. If you're auditing this for production use, read it yourself — independent review is always warranted for tooling that wipes disks.

---

## Who This Is For

**Use this if you:**
- Deploy Windows images to bare-metal hardware from a USB stick
- Need a reproducible WinPE build (no hand-edited ISOs, no guesswork)
- Want unattended deployment with unattend.xml, Dell BIOS pre-config, or BitLocker on first boot
- Are comfortable reading PowerShell and taking responsibility for the target disk

**Don't use this if you:**
- Need network-based deployment (PXE / WDS / MDT / SCCM) — use MDT or ConfigMgr
- Need Windows Sandbox / Hyper-V / dev-VM provisioning — wrong scope

---

## How This Tool Is Used

Three loops, each running at a different cadence. Skim this once so the rest of the README makes sense.

| Loop | When | Where | What |
|------|------|-------|------|
| **A. One-time setup** | First time on a new admin workstation, or once per WinPE revision | Admin Windows + ADK | Install ADK, clone repo, partition the USB, build `boot.wim`, xcopy media. ~30 min. |
| **B. Per-image refresh** | New Windows ISO drops, or different debloat profile needed | Admin Windows | `prepare_wim.ps1` or `refresh_usb.ps1` → produces a `.wim` on the IMAGES partition. ~10–20 min per image. |
| **C. Per-machine deploy** | Every target laptop / desktop | The USB itself | Plug in, boot from USB. If `deploy.args` is present it runs unattended; otherwise the TUI prompts. ~5–10 min per machine. |

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

Open **Deployment and Imaging Tools Environment** as Administrator (Start → Windows Kits), then from the repo root:

```powershell
.\scripts\build_boot_wim.ps1 -Clean -UsbDrive P: -ReleaseUsbLetter
```

This runs `copype`, installs the required WinPE components, applies the `NtfsEnableDirCaseSensitivity` registry fix (needed for Windows Containers layer apply), embeds the deploy script, writes `startnet.cmd`, and xcopies media to `P:`. `-ReleaseUsbLetter` releases `P:` afterwards.

> **Dell fleets:** add `-CctkSource 'C:\Program Files (x86)\Dell\Command Configure\X86_64'`
> to embed CCTK so each deploy can apply BIOS settings (RAID→AHCI, passwords, boot order) on target hardware.
> See [docs/CCTK.md](docs/CCTK.md).

Done. The USB boots into WinPE and auto-launches the deploy script.

---

## Loop B — Per-Image Refresh (~10–20 min)

Run this when a new ISO drops or you need a different debloat profile.

### B1. The simple path

```powershell
.\scripts\refresh_usb.ps1 -SourceIso 'D:\iso\Win11_24H2_English_x64.iso'
```

Mounts the ISO, picks the index you want, debloats provisioned AppX, optionally injects drivers and policy tweaks, writes the resulting `.wim` to `I:\images\`.

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

Copy [`configs/deploy.args.example`](configs/deploy.args.example) and edit:

```text
-WimFile "I:\images\Win11_Enterprise.wim" -TargetDisk 0 -UnattendFile "I:\configs\unattend.xml" -DataDiskNumber 1 -EnableBitLocker -BitLockerPin "YourRealPin42" -Force -Silent
```

See [docs/DEPLOY_ARGS.md](docs/DEPLOY_ARGS.md) for the full reference and the security note (PIN sits in plaintext on the USB — same trust model as CCTK passwords).

### C2. Boot from USB

1. Plug the USB into the target machine
2. Boot from USB in **UEFI mode** (typically F12 → "UEFI: USB …")
3. If `deploy.args` is present, the deploy runs unattended — otherwise the TUI prompts for image → edition → target disk → confirmations
4. When complete, remove USB and reboot

### C3. What happens on first boot

| Trigger | Behavior |
|---------|----------|
| CCTK embedded + matching config on USB | BIOS settings applied (RAID→AHCI, passwords, boot order) |
| `-UnattendFile` set | OOBE skipped, accounts created, computer name set, autologon (if configured), `first-login.ps1` runs per-user tweaks |
| `-EnableBitLocker -BitLockerPin` set | `SetupComplete.cmd` enables TPM+PIN on `C:`, recovery key + auto-unlock on `D:` if `-DataDiskNumber` set, keys escrow to `<IMAGES>\BitLockerKeys`, staging scripts self-delete, machine reboots |

---

## Streamlined End-User Distribution (Optional)

Once you've built your WinPE image and Windows WIM and have the workflow dialed in, you can package everything into a single distributable ISO. This is the path for handing a deployment to **non-IT end users — remote, worldwide, no technical background required.**

### Package into an ISO

```powershell
.\scripts\build_iso.ps1 `
    -WimFile   'I:\images\Win11_Enterprise.wim' `
    -OutputIso 'D:\dist\WinPE_Deploy_Win11.iso'
```

This bundles the WinPE boot image, your Windows WIM, configs, and any `deploy.args` into a single bootable ISO. Bake in `deploy.args` beforehand if you want fully unattended operation on the receiving end.

### What end users do

1. Download the ISO
2. Download [Rufus](https://rufus.ie) (free, no install required)
3. Plug in a USB drive (32 GB+)
4. Open Rufus, select the ISO, click START
5. Boot target machine from USB (F12 → "UEFI: USB …")
6. Follow on-screen prompts (or wait if unattended)
7. Remove USB and reboot when done

The full plain-English guide for non-IT users is in [docs/END_USER_DEPLOY.md](docs/END_USER_DEPLOY.md) — that's the document to include with the ISO or send alongside the download link.

---

## Manual / Interactive Use

You don't need `deploy.args` to use the tool. If absent, the script runs the interactive TUI. You can also run it directly from a WinPE console or a normal Windows console for testing:

```powershell
# Auto-discover images on all drives (the default WinPE flow)
.\unified_winpe_deploy.ps1

# Specific image, interactive disk + edition selection
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

## USB Drive Layout (Reference)

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

See [docs/USB_SETUP.md](docs/USB_SETUP.md) for step-by-step partitioning.

---

## Disk Partition Layout Created on Target

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
| `-UnattendFile` | String | Path to `unattend.xml`. Copied to `C:\Windows\Panther\` post-apply for first-boot OOBE skip, domain join, etc. |
| `-DataDiskNumber` | Int | Disk number to wipe and format as NTFS `D:`. Off by default (`-1`). Requires typed `WIPE DATA` confirmation. |
| `-EnableBitLocker` | Switch | Stage `SetupComplete.cmd` to enable BitLocker on first boot. Requires `-BitLockerPin`. |
| `-BitLockerPin` | String | Startup PIN for the TPM+PIN protector on `C:`. 6–20 characters. Placeholder PINs are rejected at runtime. |
| `-BitLockerKeyPath` | String | Override recovery-key escrow path. Default: `<IMAGES>\BitLockerKeys`. |
| `-Force` | Switch | Skip typed `ERASE` / `WIPE ALL` / `WIPE DATA` confirmations. **Never bypasses `DESTROY SYSTEM`.** |
| `-Silent` | Switch | Unattended mode. Requires `-WimFile`, `-TargetDisk`, `-Force`, and a single-index image. |
| `-ListOnly` | Switch | Show available images and exit |

---

## Safety Features

- **Requires Administrator privileges** — Hard stop, not a soft warning. `diskpart`, DISM, and BCDBoot all require elevation; the script refuses to run without it. In WinPE this is always satisfied automatically. On a live Windows host (e.g. testing outside WinPE), it prevents accidental partial execution if you forget to run as admin.
- **WinPE environment detection** — A different check serving a different purpose. If the script detects it's not running inside WinPE, it warns and prompts before continuing. This matters when running on a live admin workstation for testing — it reminds you that you're about to do disk operations on a running system, not a safe WinPE RAM environment. It's a soft guard, not a hard stop, because there are legitimate reasons to run the deploy script on a live machine (testing, recovery).
- **System memory validation** — Warns if less than 8 GB RAM is detected. WinPE runs entirely in memory; low RAM can cause apply failures mid-deploy.
- **Excludes USB drives from the target disk list** — The USB you booted from is filtered out of disk selection so it can't be accidentally wiped.
- **System disk detection with red warning** — If the selected target disk contains the current OS, it is highlighted in red and requires typing `DESTROY SYSTEM` to proceed. This confirmation is never bypassed by `-Force`.
- **Typed-confirmation chain** for every destructive operation:
  - `DESTROY SYSTEM` — system disk (never bypassed by `-Force`)
  - `ERASE` — primary target disk
  - `WIPE ALL` — additional-wipe disks (`-WipeDisks`)
  - `WIPE DATA` — data-disk format (`-DataDiskNumber`)
- Placeholder BitLocker PINs (`ChangeMe123!` and similar weak strings) rejected at runtime, including under `-Force -Silent`
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

**v4.7.0** — BitLocker / data-disk feature reworked to opt-in: new `-DataDiskNumber`, `-EnableBitLocker`, `-BitLockerPin`, `-BitLockerKeyPath` parameters. Default no longer wipes a hardcoded second disk. Recovery keys escrow to the IMAGES partition. Placeholder PINs rejected at runtime. See [docs/BITLOCKER.md](docs/BITLOCKER.md).

**v4.6.0** — Driver injection (`prepare_wim.ps1 -DriverPath`) to pre-bake drivers into the WIM. Unattend.xml staging (`-UnattendFile`) for first-boot OOBE skip, computer name, domain join.

**v4.5.0** — Dell CCTK pre-apply BIOS configuration. Multi-disk wipe stage with `WIPE ALL` confirmation and `-WipeDisks` parameter.

**v4.4.0** — Diskpart resilience, Linux/LVM partition detection, DISM `/CheckIntegrity`, reproducible boot.wim builder with `NtfsEnableDirCaseSensitivity` fix.

See [CHANGELOG.md](CHANGELOG.md) for full history.
