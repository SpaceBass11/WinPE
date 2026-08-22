# WinPE Image Deployment Tool - Claude Code Guide

## Project Overview

This is a **PowerShell-based WinPE image deployment tool** (v4.7.1) that automates
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
1. Boot from USB → WinPE loads → `startnet.cmd` reads optional `<IMAGES>\deploy.args` and launches the deploy script with those parameters (no file = fully interactive TUI; see `docs/DEPLOY_ARGS.md`)
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
19. **BitLocker / data-disk staging (opt-in)** — if `-DataDiskNumber` is set, the diskpart script (step 14) also formats that disk as NTFS `D:` after a typed `WIPE DATA` confirmation; if `-EnableBitLocker` is set, `Initialize-BitLockerSetup` writes `bitlocker-setup.ps1` + `SetupComplete.cmd` to `C:\Windows\Setup\Scripts\` so first boot does TPM+PIN on C: (and recovery key + auto-unlock on D: when present). Recovery keys escrow to `<IMAGES>\BitLockerKeys` by default. See `docs/BITLOCKER.md`.
20. BCDBoot configures UEFI boot on S: (EFI partition)
21. Optional shutdown prompt (uses shutdown.exe for WinPE reliability) — final reboot activates any queued CCTK BIOS changes + Windows processes unattend.xml

## Key Files

| File | Purpose |
|------|---------|
| `unified_winpe_deploy.ps1` | Main deployment script - the core deliverable |
| `scripts/build_boot_wim.ps1` | Reproducible WinPE boot.wim builder (components + reg tweaks + embed deploy script) |
| `scripts/prepare_wim.ps1` | Companion WIM prep: ISO -> debloated/customized install.wim ready to deploy |
| `scripts/build_iso.ps1` | Packages WinPE media + WIM into one bootable ISO for end-user distribution (Rufus) |
| `scripts/refresh_usb.ps1` | Thin workflow wrapper: new ISO -> prep + (optional) boot.wim rebuild |
| `tests/test_parse.ps1` | PowerShell syntax validation (every shipped .ps1 in the pipeline) |
| `PSScriptAnalyzerSettings.psd1` | Shared PSSA rule excludes used locally and in CI |
| `docs/USB_SETUP.md` | USB drive preparation guide |
| `docs/END_USER_DEPLOY.md` | Plain-English Rufus guide for non-IT end users |
| `docs/SCRIPT_REFERENCE.md` | Full parameter and function reference |
| `docs/ARCHITECTURE.md` | Design rationale, data flow, non-goals |
| `docs/TROUBLESHOOTING.md` | Common issues, fixes, and known caveats |
| `docs/CCTK.md` | Dell CCTK pre-apply BIOS configuration |
| `docs/BITLOCKER.md` | Opt-in BitLocker + data-disk staging |
| `docs/DEPLOY_ARGS.md` | Per-USB `deploy.args` file consumed by startnet.cmd |
| `docs/UNATTEND.md` | Unattend.xml authoring, encoding, and pre-deploy sanity checks (the deploy script points at §6 in its `-UnattendFile` well-formedness error) |
| `docs/RELEASE_VALIDATION.md` | Pre-distribution manual hardware/runtime checklist — the gate CI can't cover (linked from the Release Validation section below) |
| `configs/deploy.args.example` | Template for the per-USB args file |
| `docs/SIGNING.md` | Enterprise code-signing for the deploy script |
| `.claude/MASTERIZE.md` | Internal release-audit playbook (greps + read pass) |

## Stable Files (Skip by Default)

These exist for open-source repo hygiene and rarely change. **Don't read
them during a session unless the user is specifically asking about
contribution policy, license terms, or security disclosure.** Reading
them just to "be thorough" wastes context window:

- `CODE_OF_CONDUCT.md`
- `CONTRIBUTING.md`
- `SECURITY.md`
- `LICENSE`
- `.editorconfig`
- `.gitattributes`
- `.gitignore`

If they ever need to change, the user will say so explicitly.

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

The repo has three test files; know which is which before changing one:

| File | What it covers | Where it runs |
|------|----------------|---------------|
| `tests/test_parse.ps1` | PowerShell syntax + function presence + version consistency across every shipped pipeline script (`unified_winpe_deploy.ps1` + the five under `scripts/`) | Anywhere with `pwsh` (also CI) |
| `tests/test_wim_parser.ps1` | Fixture test for the DISM `/Get-WimInfo` regex parser used by `Get-WimImageInfo` — guards against silent edition mis-attribution | Anywhere with `pwsh` (also CI) |
| `tests/test_bitlocker_setup.ps1` | Fixture test for `Initialize-BitLockerSetup`'s generated `bitlocker-setup.ps1` — parses each branch (IMAGES-label / Literal, with and without DataDisk) and checks PIN apostrophe doubling so a malformed first-boot script can't ship to disk | Anywhere with `pwsh` (also CI) |
| `tests/validation-gates.Tests.ps1` | **Pester suite.** v4.7.0 BitLocker default-config invariants, `Resolve-BitLockerKeyPath` precedence, `New-DiskpartScript` source-drive protection, `Start-Deployment` validation gates | **CI only** — see Pester note below |

```bash
# Syntax + parser fixtures - runs anywhere with pwsh installed
pwsh -NoProfile -File ./tests/test_parse.ps1
pwsh -NoProfile -File ./tests/test_wim_parser.ps1
pwsh -NoProfile -File ./tests/test_bitlocker_setup.ps1
```

The deeper safety/diskpart/BCDBoot greps that used to live in
`validate_script.ps1` are now in the masterize CI job (Phase 1B —
code-safety invariants). They run on every push — no local replica
needed.

**Pester (`tests/validation-gates.Tests.ps1`) runs in CI only.** The
Claude Code on the Web container's network policy typically blocks
outbound access to PSGallery, so `Install-Module Pester` fails with
"No match was found for the specified search criteria." `pwsh` itself
is also not preinstalled in the container — install it once per
session with:
```bash
curl -fsSL https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-linux-x64.tar.gz \
  -o /tmp/pwsh.tgz && mkdir -p /opt/pwsh && tar -xzf /tmp/pwsh.tgz -C /opt/pwsh && chmod +x /opt/pwsh/pwsh
/opt/pwsh/pwsh --version
```
For Pester logic changes, verify the assertion behavior manually
against the real values (`pwsh -c "..."` with the real return type)
and rely on CI to run the suite end-to-end. Don't waste time
retrying `Install-Module` in a loop.

### Release Validation
Before tagging or distributing a build (not as a merge gate — `main`
can hold WIP), run the manual hardware validation steps in
[`docs/RELEASE_VALIDATION.md`](docs/RELEASE_VALIDATION.md). It covers
WinPE boot, Hyper-V deploys, Dell+CCTK, BitLocker first-boot, unattend
handling, and deploy.args parsing — none of which CI exercises.

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
5. **Version field** lives in **five** places that must all match — masterize CI check #1 enforces the four file-level ones (the `.VERSION` block is currently a convention, not CI-enforced):
   - `$Script:Config.ScriptVersion` in `unified_winpe_deploy.ps1` (~line 39)
   - The `.VERSION` block in the script's header comment
   - CLAUDE.md line 5 (`(v4.X.Y)` in the Project Overview paragraph)
   - CHANGELOG.md (any mention of the new version anywhere in the file)
   - README.md (the footer "Current version: **vX.Y.Z**" line)

   Bumping the version means touching all of these in the same commit.
   If masterize CI #1 is red, this is almost always the cause.

   **CHANGELOG convention:** this repo doesn't cut tagged GitHub
   releases. Add new version entries inside the `## Unreleased`
   section (which accumulates everything since the last
   `## X.Y.Z - YYYY-MM-DD` heading). Don't introduce a new
   `## 4.7.1` heading just because the script version bumped —
   add a `### Fixed` / `### Changed` bullet that names the
   version in its prose, the way 4.7.0 was recorded.
6. **Drive letters S: and C:** are hardcoded for EFI and Windows partitions respectively
7. **Never unmount the system drive** - mountvol /d must check $env:SystemDrive first
8. **Use shutdown.exe, not Stop-Computer** - Stop-Computer is unreliable in WinPE
9. **BitLocker / data-disk must stay opt-in** - `DataDiskNumber` and `EnableBitLocker` default to `-1` / `$false`. The PIN must never have a non-null default. The `WIPE DATA` typed confirmation must remain. PIN *content* policy (forbidden lists, character classes) is intentionally NOT enforced - admins decide; the script only checks Windows' 6-20 char window so a malformed PIN fails at deploy time instead of first boot.

## When Editing Docs

- **GitHub anchor slugs strip em/en-dashes without replacement.** A
  heading like `## Loop B — Per-Image Refresh (~10–20 min)` slugs to
  `#loop-b--per-image-refresh-1020-min`, NOT `#loop-b--per-image-refresh-10-20-min`.
  GitHub's algorithm: lowercase, drop everything that isn't a letter /
  digit / hyphen / underscore / space, then replace spaces with hyphens.
  An em-dash (`—`) surrounded by spaces becomes `--`; an en-dash (`–`)
  inside `10–20` becomes nothing, collapsing to `1020`. When editing a
  TOC, verify the anchor matches what GitHub will actually generate —
  the existing TOC entries are not guaranteed to be correct.

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

## Masterize Process

Mechanical doc-consistency and code-safety checks run in CI on every
push (the `masterize` job in `.github/workflows/ci.yml`). Treat a red
build as the signal — there's nothing to run manually most of the time.

Once per release, before tagging, do the Phase 2 read pass described in
[`.claude/MASTERIZE.md`](.claude/MASTERIZE.md). That's the part CI can't
do. (The playbook lives under `.claude/` because it's internal release
process, not user-facing documentation.)

**Do not run masterize per session.** Earlier iterations did and it
burned tokens for little gain. If the user says "masterize," check
whether they mean "run Phase 2 for a release" or "look at the doc."

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

**One branch per topic, not per session.** Same topic = same
branch (add commits to the existing one, push, the PR updates).
Different independent topic = different branch (e.g. a runtime
code fix and a docs cleanup don't belong together — they need to
be independently reviewable and mergeable, since one may need
hardware testing and the other may not). It is fine to have
multiple side branches in flight from a single session.

What this is not: "always create multiple branches." If you find
yourself adding to a branch named after a now-stale topic, that's
the signal to start a fresh branch — not a directive to start one
every time you push.
