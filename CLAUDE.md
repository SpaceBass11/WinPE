# WinPE Image Deployment Tool - Claude Code Guide

## Project Overview

This is a **PowerShell-based WinPE image deployment tool** (v4.6.0) that automates
Windows installation from `.wim`/`.esd` files in a WinPE boot environment. The tool
is designed to run from a USB drive with a dual-partition layout: a small WinPE boot
partition and a larger data partition holding Windows images.

## Architecture

```
USB Drive Layout:
├── Partition 1: WinPE Boot (FAT32, ~2GB)
│   └── WinPE with startnet.cmd → unified_winpe_deploy.ps1
└── Partition 2: Data (NTFS, remaining space)
    └── images/
        ├── Win11_Pro.wim
        ├── Win10_LTSC.wim
        └── ...
```

**Primary script:** `unified_winpe_deploy.ps1`

**Pipeline overview** (three programs, one product):
1. `scripts/prepare_wim.ps1` — *prerequisite, run once per WIM:* prep a clean
   debloated install.wim from a stock Windows ISO (admin Windows host)
2. `scripts/build_boot_wim.ps1` — *prerequisite, run once per WinPE rev:* build
   the WinPE boot.wim that hosts the deploy script (admin Windows host)
3. `unified_winpe_deploy.ps1` — *runtime, every deploy:* the flow below

### Deployment Flow
1. Boot from USB → WinPE loads → script auto-starts
2. Administrator check (script requires elevation)
3. Silent-mode validation (if `-Silent`: requires `-WimFile`, `-TargetDisk`, `-Force`; `-WipeDisks` format validated if given)
4. Script scans for `.wim`/`.esd` files on non-system drives
5. User selects image via TUI menu
6. User selects Windows edition (WIM index) via DISM enumeration
7. WinPE environment check (warns and prompts if not in WinPE)
8. Memory check (warns if < 8 GB RAM)
9. **CCTK pre-apply (Dell)** — if `X:\cctk\cctk.exe` is embedded, pick config from `<IMAGES>\cctk\` by service tag → model → default, apply via `cctk --infile=`; non-zero exit aborts the deploy
10. User selects target disk (with safety confirmations)
11. **Optional additional-wipe prompt** — list non-target non-USB disks, user picks numbers, single `WIPE ALL` confirmation (or `-WipeDisks` / `-Force` in silent mode)
12. Disk size validated against image size
13. Drive letters C:/S: freed if in use (never the system drive)
14. Diskpart wipes + partitions target (GPT: EFI 300MB + MSR 16MB + NTFS primary), with `clean`-only preamble for any extra-wipe disks in the same diskpart session
15. Post-diskpart verification (S: and C: available)
16. DISM applies the WIM to C:\ (progress shown inline)
17. Post-deploy verification (C:\Windows\System32 exists)
18. **Unattend staging** — if `-UnattendFile` given, copies answer file to `C:\Windows\Panther\unattend.xml` for Windows Setup to process on first boot (OOBE skip, domain join, computer name, autologon)
19. BCDBoot configures UEFI boot on S: (EFI partition)
20. Optional shutdown prompt (uses shutdown.exe for WinPE reliability) — final reboot activates any queued CCTK BIOS changes + Windows processes unattend.xml

## Key Files

| File | Purpose |
|------|---------|
| `unified_winpe_deploy.ps1` | Main deployment script - the core deliverable |
| `scripts/build_boot_wim.ps1` | Reproducible WinPE boot.wim builder (components + reg tweaks + embed deploy script) |
| `scripts/prepare_wim.ps1` | Companion WIM prep: ISO -> debloated/customized install.wim ready to deploy |
| `scripts/validate_script.ps1` | Static analysis checks for the deploy script |
| `tests/test_parse.ps1` | PowerShell syntax validation (deploy + builder + prep) |
| `PSScriptAnalyzerSettings.psd1` | Shared PSSA rule excludes used locally and in CI |
| `docs/USB_SETUP.md` | USB drive preparation guide |
| `docs/SCRIPT_REFERENCE.md` | Full parameter and function reference |
| `docs/ARCHITECTURE.md` | Design rationale, data flow, non-goals |
| `docs/TROUBLESHOOTING.md` | Common issues and fixes |
| `docs/KNOWN_ISSUES.md` | Active caveats and recent fixes |
| `docs/CCTK.md` | Dell CCTK pre-apply BIOS configuration |
| `docs/SIGNING.md` | Enterprise code-signing for the deploy script |

## Review & Validation Workflows

### Quick Review Loop
Use `/review` to run a comprehensive check of the deployment script covering:
- PowerShell syntax parsing
- Version consistency
- Safety check validation (admin, WinPE blocking, memory, disk confirmations, -Force behavior)
- Diskpart script correctness (GPT, EFI, MSR, NTFS, drive letter cleanup)
- Post-diskpart and post-deploy verification
- WIM index enumeration and edition selection
- BCDBoot configuration
- Error handling coverage (recovery guidance, log file)
- Disk size validation

### Running Checks
```bash
# Syntax validation only
pwsh -NoProfile -Command "& ./tests/test_parse.ps1"

# Full static analysis
pwsh -NoProfile -Command "& ./scripts/validate_script.ps1"
```

## Code Conventions

- **PowerShell 5.1+ compatible** (WinPE environment)
- Uses `#region`/`#endregion` blocks for organization
- Color-coded TUI output via `Write-Log` function (also writes to log file)
- All destructive operations require explicit typed confirmation
- `-Force` skips "ERASE" but NEVER skips system disk "DESTROY SYSTEM" prompt
- Script uses `$Script:` scope for shared configuration
- DISM `/Get-WimInfo` uses `/English` flag for locale-safe parsing

## When Modifying the Script

1. **Never remove safety confirmations** - the multi-step disk destruction confirmations are critical
2. **Never let -Force bypass system disk protection** - DESTROY SYSTEM must always be typed
3. **Test syntax after every edit** - run `pwsh -c "[System.Management.Automation.PSParser]::Tokenize((Get-Content unified_winpe_deploy.ps1 -Raw), [ref]$null)"`
4. **Keep WinPE compatibility** - no modules that aren't available in WinPE (no Az, no ImportExcel, etc.)
5. **Version field** lives in `$Script:Config.ScriptVersion` (line ~39) AND in the header comment block
6. **Drive letters S: and C:** are hardcoded for EFI and Windows partitions respectively
7. **Never unmount the system drive** - mountvol /d must check $env:SystemDrive first
8. **Use shutdown.exe, not Stop-Computer** - Stop-Computer is unreliable in WinPE

## Known Constraints

- WinPE has limited PowerShell modules available
- `System.Windows.Forms` may not load in all WinPE builds (script handles this gracefully with console Read-Host fallback for YesNo dialogs)
- `Get-WmiObject` is used instead of `Get-CimInstance` for broader WinPE compatibility
- No network dependency - everything runs offline from USB
- DISM runs with `-NoNewWindow` so progress is shown inline in the console
- Diskpart exit code 0 does not guarantee all commands succeeded - script verifies S: and C: exist after partitioning
- Log file lives in temp dir (typically X:\Windows\Temp in WinPE) - survives diskpart since X: is RAM disk

## Building boot.wim

The deploy script assumes a WinPE build with the right components and a
specific registry tweak. Use `scripts/build_boot_wim.ps1` (run from the
ADK "Deployment and Imaging Tools Environment" as admin) to produce a
compatible `boot.wim`.

The builder adds these optional components:
`WinPE-WMI`, `WinPE-NetFx`, `WinPE-Scripting`, `WinPE-PowerShell`,
`WinPE-DismCmdlets`, `WinPE-SecureStartup`, `WinPE-StorageWMI`,
`WinPE-EnhancedStorage`, `WinPE-FMAPI`.

And this registry tweak in the offline SYSTEM hive:
`HKLM\SYSTEM\ControlSet001\Control\FileSystem\NtfsEnableDirCaseSensitivity = 1`

**Why the reg key matters:** Windows Containers/Hyper-V layer files in a
captured WIM set the `CASE_SENSITIVE_DIR` flag. Without this key, DISM
apply fails with "Incorrect function" (exit 1) mid-apply on
`C:\ProgramData\Microsoft\Windows\Containers\Layers\...`. This was the
root cause behind the v4.3.x diskpart/DISM troubleshooting pass.

## Masterize Checklist

Run this after any significant change or before pushing a release branch. Each
item is a concrete grep/read check — not a vague directive. Work top to bottom;
fix anything that fails before moving on.

### 1. Version Consistency

| Location | What to check |
|----------|---------------|
| `unified_winpe_deploy.ps1` line ~4 | `.VERSION X.Y.Z` header comment |
| `unified_winpe_deploy.ps1` line ~39 | `$Script:Config.ScriptVersion = 'X.Y.Z'` |
| `CHANGELOG.md` | Latest `## [X.Y.Z]` section matches both above |
| `CHANGELOG.md` `[Unreleased]` link | Compare URL ends with `vX.Y.Z...HEAD` |
| `CHANGELOG.md` bottom | `[X.Y.Z]: .../releases/tag/vX.Y.Z` link exists |
| `docs/KNOWN_ISSUES.md` header | Title line says `(vX.Y.Z)` and lists all three scripts |
| `CLAUDE.md` Project Overview | First paragraph says `(vX.Y.Z)` |
| `README.md` | Version badge / footer matches |

```bash
# Quick grep — all should print the same version string
grep -n 'ScriptVersion\|\.VERSION\|^\## \[4' unified_winpe_deploy.ps1 CHANGELOG.md
grep -n 'v4\.' docs/KNOWN_ISSUES.md CLAUDE.md README.md | head -20
```

### 2. Cross-Doc Script Coverage

All three scripts must appear in every overview table:

- `README.md` — "Companion scripts" or "Parameters" table
- `ARCHITECTURE.md` — file layout / key files table
- `CLAUDE.md` — Key Files table (this file)
- `docs/KNOWN_ISSUES.md` — header line listing scripts

```bash
for f in README.md docs/ARCHITECTURE.md CLAUDE.md docs/KNOWN_ISSUES.md; do
  echo "=== $f ==="; grep -c 'prepare_wim\|build_boot_wim\|unified_winpe_deploy' "$f"
done
```

### 3. Drive-Letter Conventions

| Letter | Context | Correct usage |
|--------|---------|---------------|
| `I:\` | Admin workstation | IMAGES data partition when partitioning USB |
| `P:\` | Admin workstation | WinPE FAT32 boot partition |
| `D:\` | WinPE runtime | IMAGES partition as seen from booted WinPE |
| `X:\` | WinPE runtime | RAM disk (scripts, logs live here) |
| `C:\` | Target | Windows is deployed here |
| `S:\` | Target | EFI partition (hardcoded in diskpart script) |

Check for stray `E:\images\` references (the old incorrect convention):

```bash
grep -rn 'E:\\images\|E:/images' docs/ scripts/ unified_winpe_deploy.ps1
# Should produce zero matches
```

### 4. Volume Labels

Labels must be uppercase and consistent:

```bash
grep -rn 'label=' docs/ scripts/ | grep -iv '"IMAGES"\|"WinPE"'
# Any match here is a bug — labels should be IMAGES and WinPE exactly
```

### 5. Parameter Coverage in SCRIPT_REFERENCE.md

Every parameter in each script must have a matching section in
`docs/SCRIPT_REFERENCE.md`. Check by diffing param blocks against doc headers:

```bash
# Extract param names from each script
grep '^\s*\[' unified_winpe_deploy.ps1 | grep 'Parameter\|string\|switch\|int' | grep -v '#'
grep '^\s*\[' scripts/prepare_wim.ps1 | grep 'Parameter\|string\|switch\|int' | grep -v '#'

# Then confirm each name appears in SCRIPT_REFERENCE.md
grep '^\-\-\-\|^### `-' docs/SCRIPT_REFERENCE.md
```

### 6. Non-Goals Accuracy

`docs/ARCHITECTURE.md` and `README.md` "Don't use this if you" non-goals must
not list features that are now implemented:

- Driver injection → supported via `prepare_wim.ps1 -DriverPath` ✓
- Unattend.xml / OOBE / domain join → supported via `-UnattendFile` ✓
- BIOS config → supported via CCTK ✓

```bash
grep -n 'non.goal\|not.*support\|driver inject\|domain join\|unattend' \
  docs/ARCHITECTURE.md README.md | grep -iv 'supported\|now\|via'
```

### 7. Deployment Flow Completeness

The numbered steps must be consistent across three sources. Spot-check that
unattend staging, CCTK, and extra-wipe steps appear in all three:

- `CLAUDE.md` Deployment Flow (steps 1–20)
- `docs/ARCHITECTURE.md` runtime data flow diagram
- `docs/USB_SETUP.md` Step 6 test sequence (high-level, not every step)

```bash
grep -n 'Unattend\|unattend\|CCTK\|cctk\|wipe\|Wipe' \
  CLAUDE.md docs/ARCHITECTURE.md docs/USB_SETUP.md
```

### 8. In-Script .EXAMPLE Paths

`.EXAMPLE` blocks inside scripts must use documented conventions (`I:\images\`
for admin workstation, not `E:\` or `D:\`):

```bash
grep -n '\.EXAMPLE' -A 10 unified_winpe_deploy.ps1 scripts/prepare_wim.ps1 \
  scripts/build_boot_wim.ps1 | grep 'images\\'
# All paths shown should start with I:\images\
```

### 9. Safety Invariants (deploy script only)

Quick grep to confirm the two invariants that must never regress:

```bash
# -Force must NOT bypass the DESTROY SYSTEM confirmation
grep -n 'DESTROY SYSTEM\|Force.*DESTROY\|bypass.*system' unified_winpe_deploy.ps1

# Unattend copy must happen AFTER post-deploy verification, BEFORE bcdboot
grep -n 'Panther\|bcdboot\|Post.deploy\|System32' unified_winpe_deploy.ps1 | head -20
# Panther line must appear BETWEEN the System32 check and bcdboot line
```

### 10. CHANGELOG Link Integrity

```bash
# [Unreleased] compare URL
grep '\[Unreleased\]' CHANGELOG.md

# Every [X.Y.Z] section header has a matching link at the bottom
grep '^\## \[' CHANGELOG.md | grep -oP '\d+\.\d+\.\d+' | while read v; do
  grep -q "\[$v\]:" CHANGELOG.md && echo "OK $v" || echo "MISSING link for $v"
done
```

---

## Git Workflow (Claude Code Web)

**Direct push to `main` is blocked by the Claude Code Web harness as a
built-in protection — not a GitHub branch-protection rule.** A `git push
origin main` from this environment fails with HTTP 403 + `Everything
up-to-date` (a confusing combination that means "remote rejected"). The
repo's `main` itself has no GitHub branch protection — it's a harness
guardrail.

**The supported workflow:**

1. Make commits locally on `main` as usual.
2. Push to a side branch: `git push -u origin main:claude/<short-name>`.
3. The user opens a PR from `claude/<short-name>` into `main` via the
   GitHub UI and merges it.
4. After merge, locally: `git pull origin main` to fast-forward.
5. If the local-main is now ahead of origin (because you committed but
   the PR hasn't been merged yet), and the stop hook complains, you
   can `git reset --hard origin/main` — the work is safely on the side
   branch, and `git pull` brings it back after merge.

**Don't waste tokens** retrying direct pushes to main with
exponential backoff — they will all fail. Push to a side branch the
first time.

**Don't create multiple side branches per session** if avoidable —
add new commits to the existing one (`git checkout -b <name>
origin/<name>`, commit, push) so the user has one PR to review,
not several.
