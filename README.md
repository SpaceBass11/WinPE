# MDT USB Payload Factory

[![CI](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml/badge.svg)](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://learn.microsoft.com/powershell/)

**Admin builds once. Operator plugs in USB, boots laptop, walks away.**

Zero-touch Windows deployment using MDT standalone media. No deployment server.
No network at deploy time. The ISO is entirely self-contained.

```
Admin workstation
  |
  +--> START.bat  (guided menu)
         |
         +--> Initialize share  (one-time)
         +--> Build ISO  -->  LiteTouchMedia_x64.iso  -->  upload
                                                              |
Operator: download --> Rufus --> USB --> boot --> walk away <--
```

---

## Quick start

### Step 1 -- Install prerequisites (admin workstation, one-time)

Install in this order:

| # | Software | Notes |
|---|----------|-------|
| 1 | [Windows ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install) | Select *Deployment Tools* only |
| 2 | [ADK WinPE add-on](https://learn.microsoft.com/windows-hardware/get-started/adk-install) | Separate installer, same download page |
| 3 | [MDT 8456](https://www.microsoft.com/en-us/download/details.aspx?id=54259) | Last MDT version; supports Windows 11 |
| 4 | [Hotfix KB4564442](https://support.microsoft.com/kb/4564442) | Required for Windows 11 UEFI deployments |

You also need a Windows `.wim` or `.esd` image file (custom capture or
straight from Microsoft media).

### Step 2 -- Run START.bat

1. Download this repo as a ZIP and extract to any folder.
2. Double-click **`START.bat`** -- it handles the UAC elevation prompt.
3. Follow the numbered menu:

```
  First time  ->  1  2  3  5  (in order)
  New image   ->  4  5  then update your download link

  1  Check prerequisites
  2  Configure deployment settings  (BitLocker, naming, finish action)
  3  Initialize deployment share    (one-time; safe to re-run)
  4  Import additional WIM
  5  Build operator ISO
```

Step 5 generates `LiteTouchMedia_x64.iso` (10-30 min first run -- normal).

### Step 3 -- Upload and hand off

Upload the ISO to your file server or shared drive and send operators:

```
1. Download the ISO from [your link]
2. Download Rufus from https://rufus.ie
3. Open Rufus -- select the ISO, select the USB -- click START  (~20 min)
4. Plug USB into target laptop, press F12 at POST for boot menu
5. Select the USB -- walk away  (~20 min to deploy)
```

---

## What the ISO does on the target machine

- Partitions the disk: EFI 300 MB + MSR 16 MB + Windows (remainder)
- Applies the WIM image
- Runs the zero-touch task sequence:
  - Renames built-in Administrator to `X_Admin` and disables it (DoD STIG)
  - Renames built-in Guest to `Visitor` (DoD STIG)
  - Enables BitLocker on C: (TPM + startup PIN) and data drives (if PIN configured)
  - Saves BitLocker recovery keys to `D:\BitLocker` before encrypting
- Reboots (or shuts down -- configurable)

No prompts. No decisions. Fully automated.

---

## Updating the image

New WIM available (patch Tuesday, software update, recapture):

1. Double-click `START.bat`
2. Select `4` -- Import additional WIM
3. Select `5` -- Build operator ISO
4. Replace the download link

Operators use the same Rufus process. No instructions change.

---

## Configuration

Key settings are set during `START.bat` step 2 (Configure) and baked into the ISO.
For reference, the source files are:

| File | Purpose |
|------|---------|
| `configs/mdt/CustomSettings.ini` | Annotated reference for zero-touch settings |
| `configs/mdt/Bootstrap.ini` | WinPE boot config -- `DeployRoot=.` for standalone USB |
| `configs/unattend.example.xml` | Example unattend.xml (OOBE skip, autologon, STIG) |

For advanced configuration (drivers, CCTK BIOS management, custom task sequence
steps) see the full guide:

- [docs/MDT.md](docs/MDT.md) -- setup, drivers, task sequence tuning, troubleshooting
- [docs/CCTK.md](docs/CCTK.md) -- Dell BIOS pre-configuration via MDT Application
- [docs/UNATTEND.md](docs/UNATTEND.md) -- unattend.xml reference

---

## License

[MIT](LICENSE)
