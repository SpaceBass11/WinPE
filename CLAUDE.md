# MDT Manual Deployment Guide - Claude Code Guide

## Project Overview

This repo is a **documentation-only guide** for setting up MDT standalone
media deployments manually through the Deployment Workbench GUI. There are
no scripts to run or maintain. An admin follows the docs to build a
self-contained bootable ISO; operators download it, write it to USB with
Rufus, and boot laptops.

**No PowerShell scripts live here.** The scripted version of this workflow
lives on the `main` branch. Do not reference scripts, automation, or
`Start-MDT.ps1` in any content on this branch.

**What this branch contains:**

- Step-by-step Workbench GUI walkthrough (`docs/MDT.md`)
- Reference INI config files to paste into Workbench (`configs/`)
- Example unattend.xml (`configs/unattend.example.xml`)
- Supporting guides: CCTK, UNATTEND, TROUBLESHOOTING, ARCHITECTURE

### Docs style

The audience is an IT admin who will click through Deployment Workbench.
Write instructions as numbered steps with exact field values. When referencing
MDT Workbench UI elements, bold them (**Deployment Shares**, **New Media**, etc.).

Give GUI steps. If a setting also maps to an INI key or a command-line
equivalent (e.g., for scripting readers or troubleshooting), show it as a
secondary note after the GUI steps -- not the primary path.

See `docs/MDT.md` for the established format to follow.

## Key Files

| File | Purpose |
|------|---------|
| `docs/MDT.md` | Main guide -- full Workbench walkthrough, step by step |
| `docs/CCTK.md` | Dell CCTK BIOS pre-configuration via MDT Application |
| `docs/UNATTEND.md` | Unattend.xml reference |
| `docs/ARCHITECTURE.md` | Design overview of the MDT payload factory |
| `docs/TROUBLESHOOTING.md` | Common issues and fixes |
| `docs/USB_SETUP.md` | USB creation and operator boot instructions |
| `configs/mdt/CustomSettings.ini` | Zero-touch settings reference |
| `configs/mdt/Bootstrap.ini` | WinPE boot config reference |
| `configs/unattend.example.xml` | Example answer file |

## Stable Files (Skip by Default)

Don't read these unless the user is specifically asking about contribution
policy, license, or security disclosure:

- `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE`
- `.editorconfig`, `.gitattributes`, `.gitignore`

## When Adding or Updating Docs

1. Keep instructions concrete: exact field names, exact values, exact paths.
2. GUI steps first. Command-line equivalents as secondary notes.
3. Avoid references to scripts, automation, or PowerShell that does not exist
   on this branch.
4. INI file content shown in code blocks must be valid -- comments start with
   `;`, not `#`.
5. Do not add new code files (`.ps1`, `.bat`, `.cmd`). This is a docs repo.

## CI

CI runs Markdown link checking and a doc consistency check (masterize job)
on every push. Treat a red build as the signal.

### Masterize checks (Phase 1A)

- **Check 3:** No stray `E:\images` references in docs
- **Check 4:** Volume labels must be `IMAGES`, `WinPE`, or `Windows`
- **Check 5:** ARCHITECTURE.md covers `driver`, `unattend`, `cctk` in the
  correct sections (see ci.yml for section names)

There are no script-related checks. PowerShell syntax and PSScriptAnalyzer
jobs have been removed.

## Git Workflow (Claude Code Web)

Direct push to `main` is blocked. Push to a side branch:

```
git push -u origin main:claude/<short-name>
```

User opens a PR from the side branch into `main` via GitHub UI.
