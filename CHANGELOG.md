# Changelog

All notable changes to this project will be documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Version numbers are tracked in the script header for reference; no
tagged GitHub releases are published.

## Unreleased

### Changed
- **`docs/DEPLOY_ARGS.md` documents the file-encoding constraint.**
  Appended a `Constraints` bullet: `deploy.args` must be saved as
  ASCII (or UTF-8 without BOM) so `set /p` doesn't glue a BOM to
  the first parameter — otherwise PowerShell rejects it with an
  opaque `parameter cannot be found` error. Lists the three common
  hand-author paths that produce a BOM (Windows PowerShell 5.1's
  `Set-Content -Encoding UTF8`, older Notepad "Save As → UTF-8", VS
  Code's "UTF-8 with BOM") and gives copy-paste safe recipes for
  each. `scripts/build_iso.ps1` was already writing ASCII by
  construction; this only affects hand-authored files in the
  two-partition USB flow.

- **`Get-SystemDisks` classifier now has fixture-test coverage.**
  New `tests/test_disk_enumeration.ps1` exercises the disk-filter
  predicate (8 cases: USB, USB-SATA enclosure, SD reader, CD-ROM by
  MediaType, DVD by Model, zero-size, and two passing internal disks)
  and the partition-info rendering path (pure-Windows, Linux/LVM,
  mixed, empty, and null-`Partitions` WMI quirk). Includes a drift
  guard that fails if the eight safety-critical literals (USB/CD/
  removable filter clauses, `Win32_DiskDrive.Partitions` precedence,
  `No partitions` label, `non-Windows - e.g. Linux/LVM` string, and
  the `(+N non-Windows)` suffix template) move in the deploy script.
  Wired into the CI `syntax` job. No production code changed.

### Removed
- **`ForbiddenBitLockerPins` list and PIN content policy.** Earlier
  builds rejected `ChangeMe123!`, `password`, `Password1`, and `123456`
  as BitLocker startup PINs. That list was paternalism — the
  `ChangeMe123!` "placeholder" wasn't a real historical default in
  this repo, and the others were second-guessing admins who know
  their threat model. The script now passes the PIN through; only
  the Windows-mandated 6-20 character window is checked (so a
  malformed PIN still fails at deploy time, not first boot). Same
  removal applied to `scripts/build_iso.ps1`. Removed the
  corresponding Pester rows and CI masterize check #21.

### Added
- **TUI PIN prompt for BitLocker in non-silent mode.** When
  `-EnableBitLocker` is set without `-BitLockerPin` in non-silent
  mode, the script now prompts at the WinPE console via `Read-Host`.
  PIN is visible on screen so the operator can verify the typed
  value — and is staged plaintext into `bitlocker-setup.ps1` on `C:`
  downstream anyway, so hiding at the prompt would be theater that
  just makes typos invisible. Silent mode still hard-fails (a prompt
  would deadlock an unattended deploy). 6-20 char validation still
  applies to the typed value. See `docs/RELEASE_VALIDATION.md`
  scenario #11 and `docs/BITLOCKER.md` "Example invocations".
- **Per-USB `deploy.args` file.** `scripts/build_boot_wim.ps1` now
  writes a `startnet.cmd` that looks for `<IMAGES>\deploy.args` on
  boot and passes its single-line contents as parameters to
  `unified_winpe_deploy.ps1`. Lets you retarget a USB (different
  image, different PIN, interactive vs silent) by editing one text
  file — no `boot.wim` rebuild. Missing file = fully interactive
  TUI (unchanged default). New `configs/deploy.args.example`
  template and `docs/DEPLOY_ARGS.md` walkthrough.

### Changed
- **`tests/test_parse.ps1` now covers every shipped pipeline script.**
  Added syntax checks for `scripts/build_iso.ps1` (the end-user ISO
  packager added in PR #35) and `scripts/first-login.ps1` (the
  per-user first-boot tweak script staged into target images by
  `prepare_wim.ps1 -DisableExtraBloat`). Previously the dedicated
  local syntax test silently skipped both — PSSA in CI caught hard
  parse errors recursively, but the test that CLAUDE.md / AGENTS.md
  point operators at was lagging the repo's actual script inventory.

### Changed (security / safety)
- **BitLocker / data-disk feature is now opt-in.** The v4.6.x BitLocker
  / data-disk feature (added in PR #33) defaulted `DataDiskNumber = 1`
  and shipped a hardcoded `BitLockerPin = 'ChangeMe123!'`, meaning every
  deploy silently wiped a hardcoded second disk and every machine
  booted with the same factory PIN. Reworked in v4.7.0:
  - Default `DataDiskNumber` is now `-1` (off). Default
    `EnableBitLocker` is `$false`. Default `BitLockerPin` is `$null`.
  - New runtime parameters: `-DataDiskNumber`, `-EnableBitLocker`,
    `-BitLockerPin`, `-BitLockerKeyPath`.
  - Placeholder PINs (`ChangeMe123!`, `password`, `Password1`,
    `123456`) are rejected at runtime.
  - New typed `WIPE DATA` confirmation gates the data-disk format.
    `-Force` skips it; `-Silent` requires `-Force`.
  - `-DataDiskNumber` is validated against the same exclusion rules as
    the target (must exist, must not be the target, must not be the
    system disk, must not be USB, must not overlap the
    additional-wipe list).
  - Recovery keys escrow to `<IMAGES>\BitLockerKeys` by default
    instead of `D:\BitLocker` (which lived on the encrypted volume
    it was meant to recover).
  - `New-DiskpartScript` refuses to `mountvol /d` the drive letter
    that hosts the WIM source, so DISM doesn't lose access mid-deploy
    if the IMAGES partition is auto-assigned to `D:`.
  - The staged `bitlocker-setup.ps1` and `SetupComplete.cmd`
    self-delete after the encryption consumes the plaintext PIN.
- Script version bumped to **4.7.0**, then **4.7.1** for the
  BitLocker recovery-key escrow fix below.
- New doc: [`docs/BITLOCKER.md`](docs/BITLOCKER.md). README parameter
  table, USB layout, and `docs/TROUBLESHOOTING.md` updated to match.

### Fixed
- **BitLocker recovery-key escrow drive-letter mismatch (v4.7.1).**
  The v4.7.0 implementation of `Resolve-BitLockerKeyPath` baked the
  WinPE-time drive letter of the IMAGES partition (typically `I:`)
  into the staged first-boot `bitlocker-setup.ps1`. On first boot
  Windows is free to assign the USB IMAGES partition a different
  letter, which silently failed the `Add-BitLockerKeyProtector
  -RecoveryKeyPath` call inside a `try/catch` — leaving the volume
  with TPM+PIN only and no recovery key. A subsequent TPM reset,
  board swap, or firmware update would have left the volume
  unrecoverable. v4.7.1 looks up the IMAGES partition by volume
  label (`Get-Volume -FileSystemLabel 'IMAGES'`) at first-boot time
  so escrow works regardless of how Windows assigns letters; falls
  back to `C:\Windows\Setup\BitLockerKeys` with a loud `Write-BL`
  warning if the label can't be resolved (USB unplugged or
  relabeled). The USB must remain plugged in through the first
  reboot when default escrow is used. README (Loop C step C2, ISO
  flow, Safety Features) and `docs/BITLOCKER.md` updated to call
  this out; `-BitLockerKeyPath` docstring rewritten.
- `prepare_wim.ps1` now names the exported WIM after the selected source
  image (`$target.ImageName`) instead of the default `$Edition` literal.
  Before: `-SourceWim foo.wim -Index 1` always produced a WIM labeled
  `Windows 11 Enterprise (Custom)` regardless of what the source was,
  which then surfaced as the wrong edition name in the deploy script's
  `Select-ImageIndex` menu. Falls back to `$Edition` only when the source
  image has no name set.

### Added
- **`-SourceWim` parameter on `prepare_wim.ps1`** — alternative starting
  point for when the source is an already-captured WIM (e.g. from
  `Dism /Capture-Image` of a reference machine) instead of a stock
  Windows ISO. Parameter sets enforce "one or the other, not both."
  After the source step the workflow is identical: pick the index,
  mount, debloat / tweak / inject drivers, re-export. The source file
  is copied to a working location and never modified in place.
- **`-Index` parameter on `prepare_wim.ps1`** — numeric image-index
  override for picking which image inside a multi-index WIM to
  customize. Useful for captured WIMs that don't use standard edition
  names. Falls back to `-Edition` name match, or index 1 for captured
  WIMs with no explicit selection.
- **`-DisableExtraBloat` parameter on `prepare_wim.ps1`** — superset of
  `-DisableCopilot`. Applies seven additional HKLM policy tweaks via the
  same offline-hive mechanism: disable Recall, Widgets / News & Interests,
  Bing in Start search (2 keys), telemetry, consumer feature auto-installs,
  Edge first-run nag, and Teams Consumer Chat auto-install. All policies
  are applied in a single hive load/unload cycle.
- **`scripts/first-login.ps1`** — companion script staged into the image
  at `C:\Windows\Setup\Scripts\first-login.ps1` when `-DisableExtraBloat`
  is used. Runs once at first user sign-in (called from an `unattend.xml`
  `FirstLogonCommands` entry) to apply per-user HKCU tweaks: show file
  extensions, compact Explorer, hide Widgets/Chat taskbar icons, search
  box → icon only, suggested apps off, classic right-click menu, OneDrive
  uninstall. Applies each tweak to **two** locations in one pass:
    1. The currently logged-in user (HKCU live hive) — covers whoever
       AutoLogon brought in, typically the maintenance admin.
    2. The Default User hive (`C:\Users\Default\NTUSER.DAT`) — so every
       future user (Level0 / Level1 / Level2 / etc) inherits the same
       tweaks the first time they log in, without re-running the script.
  Each tweak is idempotent and logs to
  `C:\Windows\Setup\Scripts\first-login.log`.
- **`configs/unattend.example.xml`** — template `unattend.xml` with
  sensible defaults: skip OOBE pages (EULA, OEM reg, online-account,
  wireless setup), set en-US locale + Central Standard Time, demonstrate
  multi-account creation (one Administrator + three Users in a tiered
  pattern, each with its own base64-encoded password placeholder),
  one-shot `<AutoLogon>` block for truly unattended first boot, default
  ComputerName, and a `FirstLogonCommands` entry that calls the staged
  `first-login.ps1`.
- **`docs/UNATTEND.md`** — companion walkthrough for editing the
  template. Includes a copy-pasteable PowerShell helper for the base64
  password encoding (`<plaintext> + 'Password'` → UTF-16LE → base64),
  rules for the `<AutoLogon>` block, TimeZone reference, parse-check
  step, and a troubleshooting section covering the four most common
  failure modes (wrong encoding, AutoLogon mismatch, missing
  FirstLogonCommands script, specialize-pass skipped).
- `scripts/refresh_usb.ps1` — thin workflow wrapper for the recurring
  "new Windows media, refresh the USB" loop. Sequences `prepare_wim.ps1`
  and (optionally) `build_boot_wim.ps1`, with auto-derived output names,
  a single prompt for the boot-rebuild question, and pre-flight checks
  that fail early if the ADK environment is missing.
- **`-SourceWim`, `-Index`, `-Edition`, `-DisableExtraBloat` on
  `scripts/refresh_usb.ps1`** — wrapper-script parity with `prepare_wim.ps1`.
  `refresh_usb.ps1` previously only exposed the `-SourceIso` flow; the
  captured-WIM path added by `prepare_wim.ps1 -SourceWim` had no wrapper
  entry point. `-SourceIso` and `-SourceWim` are now in mutually
  exclusive parameter sets (`FromIso` / `FromWim`); auto-derived output
  name uses whichever source is bound.

### Changed
- `-UnattendFile` validation now parses the file as XML up front, in
  addition to the existing `Test-Path` check. A malformed unattend.xml
  is silently ignored by Windows Setup at first boot (falls through to
  manual OOBE) — failing here, before any disk wipe, saves the operator
  a full re-deploy. Matches the manual `[xml](Get-Content ...)` sanity
  check documented in `docs/UNATTEND.md` section 6.
- Documentation restructured to cut maintenance burden:
  - `docs/KNOWN_ISSUES.md` merged into `docs/TROUBLESHOOTING.md` as a
    new "Known Caveats" section. "Recently Fixed" entries removed in
    favor of `CHANGELOG.md` as the single source of truth for release
    history.
  - `docs/MASTERIZE.md` moved to `.claude/MASTERIZE.md` — it's internal
    release process, not user-facing documentation.
  - `docs/DEEP_REVIEW.md` archived to `.claude/reviews/` with a
    date-prefixed filename. Point-in-time review artifacts no longer
    live as permanent docs.
  - `CLAUDE.md` adds a "Stable Files" list (boilerplate that AI
    sessions should skip by default to save context).
  - CI version + script-coverage checks updated to reflect the new
    file layout (TROUBLESHOOTING dropped from those lists; it's not
    an overview doc).
- `scripts/validate_script.ps1` merged into the masterize CI job and
  removed. Its unique checks (diskpart GPT layout, drive letters,
  BCDBoot UEFI configuration, exit-code chain, safety confirmation
  strings) are now Phase 1B checks 15-19. The dedicated
  `static-analysis` CI job is removed; the same coverage runs on
  Ubuntu in masterize.
- `tests/test_parse.ps1` "Required functions" list extended to cover
  four functions added since v4.5.0 that were silently uncovered:
  `Invoke-CctkConfig` (Dell BIOS pre-apply gate),
  `Select-AdditionalWipeDisks` (multi-disk wipe stage),
  `Test-FinalWipeConfirmation` (the typed-confirmation parser shared by
  both wipe paths), and `Show-ImageList` (backs the public `-ListOnly`
  flag). A regression that removed or renamed any of these would have
  passed the syntax test before this change.

### Removed
- `.github/CODEOWNERS` — single-owner ceremony with no co-owners; the
  list of "safety-critical files require review by @spacebass11" was
  enforcing review by the only person who'd ever review it.
- Tag-release infrastructure: `.github/workflows/release.yml`, the
  CHANGELOG footer reference links, the SemVer claim, and the
  CI/lychee scaffolding that supported them. No tagged GitHub
  releases are planned.
- Overlapping slash commands in `.claude/commands/`:
  `audit-safety.md`, `check-syntax.md`, `improve.md`. The remaining
  three (`review`, `deep-review`, `strip-dead-code`) cover the same
  ground without redundancy.

## 4.6.0 - 2026-05-11

### Added
- **Driver injection in `prepare_wim.ps1`** via new `-DriverPath` parameter.
  Pass a folder containing `.inf` driver packages; the script injects them
  into the offline WIM via `Add-WindowsDriver -Recurse -ForceUnsigned` while
  the image is mounted (before the save/re-export step). Drivers are
  pre-validated (`.inf` count check) before mount. Best for uniform fleets:
  bake chipset, NVMe, and NIC drivers once; every deployed machine gets them
  without a post-deploy injection step.
- **Unattend.xml staging** via new `-UnattendFile` parameter on the deploy
  script. After the Windows image is applied and `C:\Windows\System32`
  verification passes, the file is copied to `C:\Windows\Panther\unattend.xml`
  — one of the canonical locations Windows Setup searches on first boot.
  Enables OOBE skip, computer name assignment, autologon, and domain join
  without needing MDT or SCCM. File is validated before any destructive disk
  work begins (fail fast).
- `scripts/prepare_wim.ps1` — companion WIM preparation script. Mounts a
  stock Windows ISO, picks the requested edition, debloats provisioned
  AppX with a whitelist (default = sane Microsoft set; override with
  `-Whitelist` array or `-WhitelistFile`), optionally applies the
  Copilot-disable registry tweak, optionally injects drivers (`-DriverPath`),
  and re-exports a `Compress:max` + `CheckIntegrity` WIM. Mounts wrap in
  `try/finally` and discard on mid-run failure.
- `-MinImageSizeMB` parameter on the deploy script. Replaces the
  hardcoded `100MB` discovery filter with a runtime override (default
  still 100). Lower it for small lab images.
- Full `.PARAMETER` documentation on the deploy script header so
  `Get-Help unified_winpe_deploy.ps1` now describes all parameters.

### Changed
- `tests/test_parse.ps1` extended to also syntax-check
  `scripts/prepare_wim.ps1`.
- README "Don't use this if you" section updated — unattend.xml orchestration
  and domain join are no longer listed as non-goals (both are now supported
  via `-UnattendFile`). Driver injection removed from non-goals (supported
  via `prepare_wim.ps1 -DriverPath`).
- Version bumped to **4.6.0** in `$Script:Config.ScriptVersion` and the
  `.VERSION` header block.

## 4.5.0 - 2026-04-22

### Added
- **Dell CCTK pre-apply BIOS configuration.** Builder gains `-CctkSource`
  to embed Dell's Client Configuration Toolkit plus its HAPI driver
  into `boot.wim`. Deploy script runs CCTK after environment checks
  and before disk selection, picking the config in this precedence
  order from `<IMAGES>\cctk\`:
  1. `<SERVICETAG>.ini` — per-machine (matches `Win32_BIOS.SerialNumber`)
  2. `<MODEL>.ini` — per-model (alnum-normalized `Win32_ComputerSystem.Model`)
  3. `default.ini` — catch-all
  4. None → skip CCTK, continue to deploy
  A non-zero CCTK exit aborts the deploy before anything destructive
  runs. Primary use case: flipping new Dell hardware from RAID to
  AHCI and setting setup/system passwords in the same pass that
  applies Windows. See `docs/CCTK.md` for config format, selection
  rules, and security tradeoffs.
- **Multi-disk wipe stage.** After the primary target is confirmed,
  an optional menu lists remaining non-USB fixed disks. User enters
  comma-separated disk numbers; a single `WIPE ALL` confirmation
  covers the whole set. Each selected disk gets a `diskpart clean`
  before the primary deploy, in the same diskpart session. Solves
  the "vendor OEM appeared as D: on the second NVMe" problem without
  a separate WinPE round-trip.
- `-WipeDisks "1,2"` parameter for unattended automation. Validated
  against the comma-separated-integers format in silent-mode checks;
  requires `-Force` like other destructive flags.
- `docs/CCTK.md` — full setup, config precedence, password-rotation
  patterns, and an honest accounting of plaintext-secrecy limits.

### Changed
- `New-DiskpartScript` accepts an `-ExtraWipeDisks` array. Extras are
  emitted as `clean`-only preamble before the primary target's full
  GPT + EFI + MSR + NTFS sequence — no repartitioning, just wiped.
- `Start-Deployment` now calls `Invoke-CctkConfig` between the memory
  check and disk selection, and `Select-AdditionalWipeDisks` right
  after the target disk is confirmed.
- Version bumped to **4.5.0** in `$Script:Config.ScriptVersion` and
  the `.VERSION` header block.

## Infrastructure (merged into 4.5.0)

### Added
- Open-source repo infrastructure: `LICENSE` (MIT), `SECURITY.md`,
  `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1),
  `CHANGELOG.md`, `.gitignore`, `.editorconfig`, `.gitattributes`.
- GitHub community files: `.github/CODEOWNERS`,
  `.github/ISSUE_TEMPLATE/` (bug report, feature request, config),
  `.github/PULL_REQUEST_TEMPLATE.md` with a mandatory safety
  checklist for deployment-path changes.
- `.github/workflows/ci.yml`: PowerShell syntax parse,
  `scripts/validate_script.ps1`, PSScriptAnalyzer with shared settings,
  actionlint, and Markdown link checking (lychee).
- `.github/workflows/release.yml`: tag-triggered GitHub release with
  `unified_winpe_deploy.ps1`, `scripts/build_boot_wim.ps1`, and
  `SHA256SUMS` as artifacts; release notes pulled from the matching
  `CHANGELOG.md` section.
- `PSScriptAnalyzerSettings.psd1` — shared rule excludes (Write-Host,
  WMI, ApprovedVerbs, ShouldProcess) used by both local and CI runs.
- `docs/ARCHITECTURE.md` — design rationale, runtime data flow, why
  specific technical choices were made, and explicit non-goals.
- `docs/SIGNING.md` — instructions for enterprise code-signing of
  the deploy script and offline-hive cert import for `AllSigned`
  WinPE images.
- README badges (CI, license, PowerShell version, platform), a
  prominent disk-destruction warning callout, "Who this is for / not
  for" section, contributing section, and license footer.

### Changed
- Trimmed trailing whitespace from `unified_winpe_deploy.ps1`
  (whitespace-only, no logic change).
- Normalized every `spacebass11/winpe` URL to the canonical
  `spacebass11/WinPE` across README, CHANGELOG, SECURITY, issue
  template config, and the CI link-check exclude list.

## 4.4.0 - 2026-04-21

### Added
- `scripts/build_boot_wim.ps1` — reproducible WinPE boot.wim builder. Wraps
  `copype`, optional-component install, offline registry tweaks, embedded
  deploy script, and `startnet.cmd` generation. Supports `-UsbDrive` for
  direct xcopy to a pre-partitioned boot partition and `-ReleaseUsbLetter`
  to release the drive-letter mount afterwards.
- `NtfsEnableDirCaseSensitivity = 1` registry tweak in the offline SYSTEM
  hive of the built boot.wim. Required for DISM `/apply-image` on WIMs that
  contain Windows Containers / Hyper-V layer files (the layers use
  `CASE_SENSITIVE_DIR`, which the WinPE kernel rejects without this key).
- `/CheckIntegrity` on `dism /apply-image`. Surfaces WIM corruption up front
  rather than as a cryptic mid-apply "Incorrect function".
- Exit-code-1 specific recovery guidance in `Apply-WindowsImage` (verify WIM,
  re-copy from source, try a different USB port, `/NoRpFix` fallback).
- Non-Windows partition detection in the disk menu. Disks with Linux / LVM /
  ext4 / xfs partitions now correctly show `[HAS DATA - WILL BE ERASED!]`
  instead of misleadingly appearing as empty.
- Targeted troubleshooting guidance when both `attributes disk clear readonly`
  and `clean` fail (physical write-protect, firmware / SED locks).
- Extended `tests/test_parse.ps1` to also syntax-check
  `scripts/build_boot_wim.ps1`.

### Changed
- Diskpart now uses `noerr` on `attributes disk clear readonly`. Previously,
  hardware that could not clear the read-only flag (exit code
  `-2147211247` / `0x80042811`) aborted the entire deploy. Diskpart now
  proceeds to `clean`, which usually succeeds on its own.
- `Get-SystemDisks` now uses `Win32_DiskDrive.Partitions` (raw partition-table
  count) instead of `Win32_DiskPartition` (Windows-recognized partitions
  only) to detect whether a disk has data. Prevents Linux installs from
  appearing as a safe empty target.
- README, `docs/SCRIPT_REFERENCE.md`, `docs/TROUBLESHOOTING.md`, and
  `docs/KNOWN_ISSUES.md` updated to reflect the builder and the new
  troubleshooting entries.

### Fixed
- DISM apply failing at ~19% with "Incorrect function" (exit 1) on images
  that include `C:\ProgramData\Microsoft\Windows\Containers\Layers\...`.
  Root cause was the WinPE boot image missing
  `NtfsEnableDirCaseSensitivity`. Fixed in the new builder and documented in
  troubleshooting.
- Deploy aborting before `clean` when the target disk has a read-only flag
  set that can't be cleared.

## 4.3.0 - 2026-03

### Added
- `$env:DEPLOY_IMAGE_DRIVE` fast-path image discovery (set by `startnet.cmd`
  when it finds a volume labeled `IMAGES`).
- Smart launcher support for testing outside WinPE.
- `-Silent` unattended deployment contract: requires `-WimFile`,
  `-TargetDisk`, and `-Force` (unless used with `-ListOnly`).
- `-WimFile` path validation — the file must exist and use a supported
  extension (`.wim` / `.esd`).

### Fixed
- Various smaller bug fixes in image discovery and confirmation prompts.

