# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/spacebass11/winpe/compare/v4.4.0...HEAD
[4.4.0]: https://github.com/spacebass11/winpe/releases/tag/v4.4.0
[4.3.0]: https://github.com/spacebass11/winpe/releases/tag/v4.3.0
