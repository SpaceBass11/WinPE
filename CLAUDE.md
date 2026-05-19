# MDT USB Payload Factory - Claude Code Guide

## Project Overview

**This is the MDT branch.** This repo is an MDT standalone media workflow —
PowerShell scripts that configure MDT as a USB payload factory. The WinPE tool
scripts (`unified_winpe_deploy.ps1`, `build_boot_wim.ps1`, `prepare_wim.ps1`)
live on the `main` branch and are **not present here**. Do not look for them,
reference them in new code, or treat them as the focus of work in this branch.

**What this branch does:** Admin runs three scripts on their workstation to
build a self-contained bootable ISO. Operator downloads the ISO, Rufus → USB,
boots a laptop, walks away. Fully automated: no prompts, no decisions, no
network at deploy time. See `docs/MDT.md` and `scripts/mdt/`.

### Docs style on this branch

Both the scripted (PowerShell) and GUI (MDT Deployment Workbench) paths are
documented in the user-facing guides. When a user asks "how do I add drivers?"
or "how do I set up CCTK?" give the GUI steps first (most admins click through
Workbench for one-offs), then the PowerShell equivalent for repeatable/automated
builds. See `docs/MDT.md` and `docs/CCTK.md` for the established dual-path
pattern to follow.

## Architecture

### MDT Payload Factory Flow

```
Admin workstation (one-time setup, then per update)
  │
  ├── Initialize-MDTDeploymentShare.ps1   (one-time)
  │     Creates deployment share, imports WIM(s), builds task sequences,
  │     writes zero-touch config (CustomSettings.ini / Bootstrap.ini),
  │     applies MDT + Windows 11 ADK compatibility fixes
  │
  ├── Import-WimImages.ps1                (add/replace WIMs)
  │
  └── New-MDTMedia.ps1                    (build payload ISO)
          │
          ▼
  LiteTouchMedia_x64.iso  →  upload to download link
          │
          ▼
  Operator: download → Rufus → USB (~20 min) → boot laptop → done
  (fully automated: partitions, applies image, reboots — no prompts)
```

The ISO is completely self-contained. No network required at deploy time.
Updating the image means rebuilding the ISO once and replacing the download link.

## Key Files

| File | Purpose |
|------|---------|
| `START.bat` | Double-click launcher -- handles UAC elevation and calls `Start-MDT.ps1` |
| `Start-MDT.ps1` | Interactive menu: Initialize / Import WIM / Build ISO |
| `scripts/mdt/Initialize-MDTDeploymentShare.ps1` | One-time setup: creates share, imports WIM, builds task sequences, writes zero-touch config, applies Win11 ADK fixes |
| `scripts/mdt/Import-WimImages.ps1` | Add/replace WIMs in an existing share |
| `scripts/mdt/New-MDTMedia.ps1` | Build the operator payload ISO (`LiteTouchMedia_x64.iso`) |
| `configs/mdt/CustomSettings.ini` | Zero-touch settings baked into the ISO (all SkipXxx=YES) |
| `configs/mdt/Bootstrap.ini` | WinPE boot config — `DeployRoot=.` for standalone USB |
| `configs/unattend.example.xml` | Example unattend.xml for OOBE skip, autologon, accounts |
| `docs/MDT.md` | Full MDT setup guide with GUI + PowerShell paths |
| `docs/CCTK.md` | Dell CCTK BIOS pre-configuration — MDT Application method |
| `docs/UNATTEND.md` | Unattend.xml reference — MDT Workbench + WinPE tool methods |
| `docs/SCRIPT_REFERENCE.md` | MDT script parameter reference |
| `docs/ARCHITECTURE.md` | MDT payload factory design |
| `docs/TROUBLESHOOTING.md` | MDT deployment issues and fixes |
| `tests/test_parse.ps1` | PowerShell syntax validation for MDT scripts |
| `PSScriptAnalyzerSettings.psd1` | PSSA rule config used in CI |
| `.claude/MASTERIZE.md` | Internal release-audit playbook |

## Stable Files (Skip by Default)

Don't read these unless the user is specifically asking about contribution
policy, license, or security disclosure:

- `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE`
- `.editorconfig`, `.gitattributes`, `.gitignore`

## Review & Validation Workflows

### Running Checks
```bash
# Syntax validation — MDT scripts
pwsh -NoProfile -Command "& ./tests/test_parse.ps1"
```

CI runs masterize checks on every push (`masterize` job in `.github/workflows/ci.yml`).
Phase 1B (WinPE safety invariants) has been removed — it referenced scripts
that no longer exist on this branch.

## Code Conventions

### MDT Script Conventions

- **PowerShell 5.1+ compatible** (MDT runs scripts via `cscript`/`wscript` wrappers)
- **ASCII only in `.ps1` files** — PowerShell 5.1 on Windows reads files without a UTF-8 BOM as Windows-1252. Any non-ASCII character (em dashes, smart quotes, arrows, box-drawing) is misread as garbage bytes, corrupting the tokenizer and producing false "missing closing brace" parse errors across the whole file. Use only plain ASCII in all scripts: `--` not `—`, `->` not `→`, straight quotes only.
- `#region`/`#endregion` blocks for organization
- Standard MDT module path: `C:\Program Files\Microsoft Deployment Toolkit\bin\MicrosoftDeploymentToolkit.psd1`
- PSDrive name convention: `DS001`
- All three scripts require `#Requires -RunAsAdministrator`
- Error handling: `$ErrorActionPreference = 'Stop'` plus explicit `Test-Path` checks before MDT cmdlets
- No hardcoded network paths — always `DeployRoot=.` for standalone media
- `-SourceFile` on `Import-MDTOperatingSystem` is undocumented but empirically works on MDT 8456 to import a single .wim without pulling the whole parent folder

## When Modifying MDT Scripts

1. **Don't break `Set-UEFIPartitionScheme`** — it patches `ts.xml` using MDT's indexed scalar variables (`OSDPartitions0Type`, `OSDPartitions0Size`, etc.). These are NOT an XML blob; each is a separate `<variable>` node. Do not rewrite to an `OSDPartitions` array — that format does not exist in MDT 8456's ts.xml.
2. **Workbench overwrites the partition patch** — If a user opens the task sequence in MDT Workbench and saves it, MDT regenerates `ts.xml` from its internal model and overwrites `Set-UEFIPartitionScheme`'s changes. Remind users to re-run `Initialize-MDTDeploymentShare.ps1` after Workbench edits.
3. **`SkipFinalSummary=YES` is required for zero-touch** — without it, MDT shows a "Deployment Complete" screen that blocks the unattended reboot. It must be in `CustomSettings.ini` alongside `SkipSummary=YES`.
4. **`-SourceFile` is undocumented** — see MDT Script Conventions above. If it breaks on a future MDT build, switch to `-SourcePath (Split-Path -Parent $wimPath)` plus a guard checking the folder contains only one WIM.
5. **Test syntax after every edit** — run `pwsh -NoProfile -File ./tests/test_parse.ps1`
6. **MediaName `MEDIA001` is stable** — `New-MDTMedia.ps1` defaults to this. Changing it creates a new orphaned media object in Workbench. Don't change it without also cleaning up the old one.

## Known Constraints

- MDT 8456 is the last version supporting Windows 11. Do not reference MDT 8450 or earlier.
- `Initialize-MDTDeploymentShare.ps1` applies Windows 11 ADK compatibility fixes automatically (x86 WinPE placeholder folder, x86 platform disabled, WSIM path patched to amd64). These are baked in — no manual workaround steps needed.
- `Update-MDTMedia` is slow (10–30 min first run) — expected behavior, not a hang
- `MediaName` must be consistent across runs (`MEDIA001` default) — changing it creates a new media object in Workbench and leaves the old one orphaned
- `DeployRoot=.` only works when reading from the same booted media — changing it to a UNC path enables network mode, but that is out of scope for this project
- `SkipFinalSummary=YES` in CustomSettings.ini is required for zero-touch — suppresses the post-deploy "Deployment Complete" screen
- `Set-UEFIPartitionScheme` patches individual indexed `<variable>` nodes in `ts.xml` — this is the correct MDT format; don't convert it to a blob
- CCTK binaries are never committed to the repo — Dell's EULA prohibits redistribution; `.gitignore` blocks common paths but don't rely on it alone
- `Initialize-MDTDeploymentShare.ps1` accepts `-BDEPin`, `-FinishAction`, and `-OSDComputerName` which are passed through by `Start-MDT.ps1` step 2 (Configure). These get baked into `CustomSettings.ini` in the deployment share.

## Masterize Process

Mechanical doc-consistency checks run in CI on every push (the `masterize`
job in `.github/workflows/ci.yml`). Treat a red build as the signal.

Once per release, before tagging, do the Phase 2 read pass in
[`.claude/MASTERIZE.md`](.claude/MASTERIZE.md).

**Do not run masterize per session.** If the user says "masterize," check
whether they mean "run Phase 2 for a release" or just "look at the doc."

### CI check summary (Phase 1A — doc consistency)

- **Check 1:** *(removed — no versioned WinPE script on this branch)*
- **Check 2:** *(removed — WinPE script coverage check; MDT-only branch)*
- **Check 3:** No stray `E:\images` references in docs/scripts
- **Check 4:** Volume labels must be `IMAGES`, `WinPE`, or `Windows`
- **Check 5:** Three-programs diagram in `docs/ARCHITECTURE.md` covers `driver`, `unattend`, `cctk`
- **Check 6:** *(skipped — USB drive layout check removed)*
- **Check 7:** *(removed — WinPE scripts no longer present)*

Phase 1B (WinPE safety invariants, checks 8–19) has been **removed** — those
checks ran against `unified_winpe_deploy.ps1` which does not exist on this branch.

---

## Git Workflow (Claude Code Web)

**Direct push to `main` is blocked by the Claude Code Web harness** — not a
GitHub branch-protection rule. `git push origin main` fails with HTTP 403.

**The supported workflow:**

1. Commit locally on `main` as usual.
2. Push to a side branch: `git push -u origin main:claude/<short-name>`.
3. User opens a PR from `claude/<short-name>` into `main` via GitHub UI and merges.
4. After merge, locally: `git pull origin main` to fast-forward.

**Don't waste tokens** retrying direct pushes to main — they will all fail.
Push to a side branch the first time.

**Don't create multiple side branches per session** if avoidable — add new
commits to the existing one so the user has one PR to review, not several.
