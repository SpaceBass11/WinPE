# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [4.6.0] - 2026-05-11

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

## [4.5.0] - 2026-04-22

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

## [Infrastructure - merged into 4.5.0 release]

### Added
- Open-source repo infrastructure: `LICENSE` (MIT), `SECURITY.md`,
  `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1),
  `CHANGELOG.md`, `.gitignore`, `.editorconfig`, `.gitattributes`.
- GitHub community files: `.github/CODEOWNERS`,
  `.github/dependabot.yml` (weekly GitHub Actions bumps),
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

## [4.4.0] - 2026-04-21

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

## [4.3.0] - 2026-03

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

[Unreleased]: https://github.com/spacebass11/WinPE/compare/v4.6.0...HEAD
[4.6.0]: https://github.com/spacebass11/WinPE/releases/tag/v4.6.0
[4.5.0]: https://github.com/spacebass11/WinPE/releases/tag/v4.5.0
[4.4.0]: https://github.com/spacebass11/WinPE/releases/tag/v4.4.0
[4.3.0]: https://github.com/spacebass11/WinPE/releases/tag/v4.3.0
