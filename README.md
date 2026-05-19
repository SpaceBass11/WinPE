# MDT Manual Deployment Guide

[![CI](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml/badge.svg)](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Admin configures MDT once. Operator plugs in USB, boots laptop, walks away.**

Zero-touch Windows 11 deployment using MDT standalone media. No scripts to
maintain. No deployment server. No network at deploy time. The ISO is entirely
self-contained -- it carries the OS, drivers, task sequence, and settings.

```
Admin workstation (one-time setup, then per update)
  |
  +-- Install prerequisites
  +-- Create deployment share (Workbench GUI)
  +-- Import WIM
  +-- Create task sequence
  +-- Configure zero-touch settings
  +-- Build ISO  -->  LiteTouchMedia_x64.iso  -->  upload to shared link
                                                          |
Operator: download --> Rufus --> USB --> boot --> walk away
```

---

## Quick start

**[docs/MDT.md](docs/MDT.md)** -- the complete step-by-step guide.

Everything an admin needs to go from a bare workstation to a distributable ISO:
prerequisites, Deployment Workbench walkthrough, zero-touch INI configuration,
Windows 11 ADK compatibility fixes, drivers, applications, BIOS config, and
operator handoff.

---

## What the ISO does on the target machine

- Partitions the disk: EFI 300 MB + MSR 16 MB + Windows (remainder, GPT)
- Applies the WIM image
- Runs the zero-touch task sequence:
  - Renames built-in Administrator to `X_Admin` and disables it (DoD STIG)
  - Renames built-in Guest to `Visitor` (DoD STIG)
  - Enables BitLocker on C: (TPM + startup PIN)
  - Saves BitLocker recovery key to `D:\BitLocker` before encrypting
- Reboots (or shuts down -- configurable)

No prompts. No decisions. Fully automated.

---

## Reference config files

Paste these into Deployment Workbench -- no editing required for a standard
deployment:

| File | Purpose |
|------|---------|
| `configs/mdt/CustomSettings.ini` | Zero-touch rules (all SkipXxx=YES, task sequence ID, locale) |
| `configs/mdt/Bootstrap.ini` | WinPE boot config -- `DeployRoot=.` for standalone USB |
| `configs/unattend.example.xml` | Example unattend.xml for OOBE skip, autologon, local accounts |

---

## All docs

| Doc | Purpose |
|-----|---------|
| [docs/MDT.md](docs/MDT.md) | Full setup walkthrough, step by step |
| [docs/CCTK.md](docs/CCTK.md) | Dell BIOS pre-configuration via MDT Application |
| [docs/UNATTEND.md](docs/UNATTEND.md) | Unattend.xml reference |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Design overview |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Common issues and fixes |
| [docs/USB_SETUP.md](docs/USB_SETUP.md) | USB creation and boot instructions |

---

## Updating the image

New WIM (patch Tuesday, software update, recapture):

1. Import the new WIM in Deployment Workbench.
2. Update the task sequence to point to the new WIM.
3. Run **Update Deployment Share**, then **Update Media Content**.
4. Replace the download link.

Operators use the same Rufus process. No instruction changes needed.

---

## License

[MIT](LICENSE)
