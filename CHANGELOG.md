# Changelog

All notable changes to this project will be documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Version numbers are tracked in the script header for reference; no
tagged GitHub releases are published.

## Unreleased

### Added (security hardening pass)
- `scripts/Scrub-AuditArtifacts.ps1` -- clears audit-mode/sysprep secret
  leftovers (Winlogon `AutoAdminLogon`/`DefaultPassword`/`DefaultUserName`/
  `DefaultDomainName` and processed `Panther\unattend.xml` copies). Runs early
  in the chain.
- `scripts/Apply-StigHardening.ps1` -- STIG baseline not covered elsewhere:
  disable/rename Guest (RID 501); password + lockout policy via `secedit`;
  UAC (`EnableLUA`, secure-desktop consent, `FilterAdministratorToken`);
  firewall profiles on + default inbound block (best-effort); logon banner +
  `DontDisplayLastUserName`; and a hard-fail assertion that only `IT_Admin`
  and the disabled built-in admin are in local Administrators.
- **BitLocker recovery-key directory is ACL-locked** to SYSTEM +
  Administrators (`Set-KeyDirAcl`), so standard users can't read recovery
  passwords. The already-encrypted skip path now guarantees a RecoveryPassword
  protector + exported key file exist before returning (closes the
  "encrypted, no recovery path" re-run gap).

### Changed (correctness + robustness)
- `New-LocalAccounts.ps1`: group-membership check matches by qualified name
  with `-eq` (not a `-like` pattern), treats "already a member" as benign, and
  re-asserts password/enabled state on existing accounts.
- `Harden-Administrator.ps1`: disables the built-in admin **before** rotating
  its password (a rotation failure can't leave it enabled), and never logs the
  randomized new name.
- `Disable-RDP.ps1`: reads back `fDenyTSConnections` and hard-fails if it
  didn't apply.
- All scripts: `Start-Transcript` is wrapped so a logging failure can't abort
  the step before it runs.
- `SetupComplete.cmd`: chain is now Apply-DellConfig -> Scrub-AuditArtifacts ->
  New-LocalAccounts -> Set-Level0ACL -> Disable-RDP -> Harden-Administrator ->
  Apply-StigHardening -> Enable-BitLocker -> Install-NotepadPP (non-fatal) ->
  Finalize-Cleanup.

### Changed (CI + repo hygiene)
- CI `masterize` now pins behavior, not just orchestration: Set-Level0ACL deny
  ACE, Harden-Administrator RID-500/disable/rename, Disable-RDP
  `fDenyTSConnections`, New-LocalAccounts group-by-SID, Install-NotepadPP
  `exit 0`, BitLocker ACL+skip-path guard, Scrub-AuditArtifacts autologon/Panther,
  Apply-StigHardening Guest/lockout/UAC, unattend `CopyProfile`, RUNBOOK
  `accounts.csv`, and a stale-`State\`-path guard. Check 4 is now
  whitespace-agnostic.
- Removed the dead `.claude/commands/{review,deep-review,strip-dead-code}.md`
  slash commands that referenced the abandoned `scripts/mdt/` tree.

### Documentation
- Propagated the recovery-key path (`State\` -> `C:\ProgramData\BitLockers\`)
  across README, USB_SETUP, TROUBLESHOOTING, CLAUDE, and the Finalize-Cleanup
  comment. Updated README/ARCHITECTURE to the full chain + new staged files.
  Added CopyProfile/audit-mode coverage to UNATTEND, new failure modes to
  TROUBLESHOOTING, and documented the IT_Admin shared-password and
  never-expire accepted risks in README/CLAUDE.

### Added (STIG hardening + multi-account deploy)
- **Posture extension.** This line now does more than restore-and-walk-away:
  the first-boot chain provisions named accounts, applies lockdown ACLs,
  hardens the built-in Administrator, disables RDP, and installs a bundled
  app. The deployed machine intentionally diverges from the gold master --
  that divergence is the deploy-time half of the audit-mode build.
- `scripts/New-LocalAccounts.ps1` -- creates `Level 0`-`Level 3` (Standard,
  local Users) and `IT_Admin` (Admin, local Administrators) from
  `Config\accounts.csv` (`Username,Password,Role`). Plaintext passwords,
  same trust model as `bitlocker-pin.txt`; wiped by Finalize-Cleanup.
  Idempotent (resets password + re-asserts group membership on re-run).
  Built-in groups resolved by well-known SID for locale safety.
- `scripts/Set-Level0ACL.ps1` -- applies an inherited Deny (Full) ACE for
  `Level 0` on `C:\Programs` and `C:\Users\Public\Desktop\Quick Links` so
  that account can neither see nor modify them. Idempotent (clears prior
  Deny ACE first). Missing folder = warning; missing account = hard fail.
- `scripts/Harden-Administrator.ps1` -- STIG: rotates the built-in
  Administrator password to a random value, disables it, and renames it
  away from "Administrator". Identifies the account by RID 500 (SID), not
  name, so it stays correct across re-runs. `IT_Admin` is the admin going
  forward.
- `scripts/Disable-RDP.ps1` -- fail-safe RDP disable: `fDenyTSConnections=1`,
  NLA required, "Remote Desktop" firewall group disabled, `TermService` /
  `UmRdpService` startup set to Disabled. (RDP was only on for Hyper-V
  enhanced session during the build.)
- `scripts/Install-NotepadPP.ps1` -- silent (`/S`) install of Notepad++
  from `Installers\npp-installer.exe` (sysprep strips provisioned apps).
  **Best-effort / non-fatal**: logs and exits 0 on missing/failed installer
  so it can never abort the security-critical chain.
- `configs/accounts.example.csv` -- template for the staged accounts file.
- **unattend `CopyProfile=true`** added in the `specialize` pass so new
  accounts inherit the audit-mode Administrator profile. Sequenced before
  first-boot Administrator hardening so the rename/disable cannot race the
  profile copy.

### Changed (BitLocker key path)
- Recovery keys now export to `C:\ProgramData\BitLockers\` (outside the
  ManualClonezilla tree, untouched by Finalize-Cleanup) for manual
  off-machine collection, instead of `...\ManualClonezilla\State\`.

### Changed (orchestration)
- `scripts/SetupComplete.cmd` chain is now: Apply-DellConfig ->
  New-LocalAccounts -> Set-Level0ACL -> Disable-RDP -> Harden-Administrator
  -> Enable-BitLocker -> Install-NotepadPP (non-fatal) -> Finalize-Cleanup.
  Security steps are fatal-on-error; the app install is not.
- `scripts/Finalize-Cleanup.ps1` now also removes `Config\accounts.csv`.

### Changed (pivot)
- **Repo identity is now manual-clonezilla.** The earlier WinPE per-USB
  tool (`unified_winpe_deploy.ps1`, `build_boot_wim.ps1`,
  `prepare_wim.ps1`, `refresh_usb.ps1`) lives on `main` and remains
  unchanged. The MDT pivot scaffolding (`docs/MDT.md`,
  `configs/mdt/*`, `scripts/mdt/*`, `Start-MDT.ps1`, `START.bat`,
  `Initialize-MDTDeploymentShare.ps1`) is removed - that direction was
  abandoned. The current branch is a self-deploying Clonezilla ISO
  workflow: build one golden Windows install, sysprep + capture, ship
  a Rufus-flashable ISO that restores and runs first-boot automation.
- **Layout flattened.** `manual-clonezilla/scripts/*` ->
  `scripts/`. `manual-clonezilla/configs/unattend.xml` ->
  `configs/unattend.example.xml` (replacing the old MDT-flavored
  208-line one). `manual-clonezilla/docs/*` -> `docs/`.

### Added (BitLocker)
- `scripts/Enable-BitLocker.ps1` now uses **TPM+PIN** instead of TPM-only.
  PIN is read from `C:\ProgramData\ManualClonezilla\Config\bitlocker-pin.txt`
  (single-line plaintext, baked into the gold image). Enhanced PIN
  policy must be enabled in the gold image if the PIN uses non-numeric
  characters.
- **Recovery key export.** After successful enable, the script adds a
  RecoveryPasswordProtector and writes the 48-digit recovery password
  to `C:\ProgramData\BitLockers\BitLocker-RecoveryKey-<host>-<ts>.txt`
  (see "Changed (BitLocker key path)" above for the move off `State\`).
  No upload, no escrow service - this is an offline, unmanaged workflow.
  Operator collects the file off-machine per SOP. To redirect to AD/MDM,
  replace the `Export-RecoveryKey` function body.
- **Hard-fail protector gates.** Throws if either the TpmPin or
  RecoveryPassword protector is missing after enable. An encrypted
  volume with no recovery path is worse than no encryption.

### Added (cleanup)
- `Finalize-Cleanup.ps1` now also removes `bitlocker-pin.txt` from
  disk (alongside `dell-config.cctk`). `State\` (Dell config SHA256
  marker), `C:\ProgramData\BitLockers\` (recovery keys), and `Logs\`
  (transcripts) are intentionally preserved post-cleanup.

### Removed (MDT pivot abandoned)
- `docs/MDT.md`, `configs/mdt/Bootstrap.ini`, `configs/mdt/CustomSettings.ini`.
- Everything MDT-related (`scripts/mdt/*`, `Start-MDT.ps1`, `START.bat`,
  `Initialize-MDTDeploymentShare.ps1`, `Import-WimImages.ps1`,
  `New-MDTMedia.ps1`) had already been removed in earlier feature-branch
  commits but is still listed in older entries below for traceability.

---

The entries below this line are the history of the MDT pivot that this
branch abandoned. They are preserved for traceability but describe files
and behavior that no longer exist on this branch.

### Added
- `START.bat` and `Start-MDT.ps1` -- interactive guided launcher with prereq check, session config persistence, PIN validation, and post-build operator handoff instructions
- `scripts/mdt/Enable-BitLocker.ps1` -- TPM+PIN encryption on C:, password+auto-unlock on D:, recovery keys saved to D:\BitLocker
- `Add-StigAccountsTsSteps` in `Initialize-MDTDeploymentShare.ps1` -- auto-injects three DoD STIG task sequence steps: rename Administrator->X_Admin (WN11-SO-000030), rename Guest->Visitor (WN11-SO-000040), disable X_Admin (WN11-SO-000025)
- `-BDEPin`, `-FinishAction`, `-OSDComputerName` parameters on `Initialize-MDTDeploymentShare.ps1`

### Fixed
- All `.ps1` files converted to pure ASCII -- PowerShell 5.1 on Windows reads files without UTF-8 BOM as Windows-1252, causing cascade parse failures on any non-ASCII character

### Added
- **MDT 8456 + Windows 11 ADK compatibility fixes** in
  `Initialize-MDTDeploymentShare.ps1`: guards against missing ADK
  environment variables, improved error messaging when the MDT module
  path is not found, and explicit `-SourceFile` handling for single-WIM
  imports on MDT 8456.

### Removed
- **WinPE tool scripts removed from MDT branch** —
  `unified_winpe_deploy.ps1`, `scripts/build_boot_wim.ps1`,
  `scripts/prepare_wim.ps1`, and `scripts/refresh_usb.ps1` are no longer
  present on this branch. They continue to live on the `main` branch.
  The MDT standalone media workflow replaces the manual WinPE USB workflow
  for all new deployments.

### Added
- **MDT standalone media workflow** — three new scripts build a self-contained
  bootable ISO for zero-touch USB deployment. No deployment server or network
  required at deploy time.
  - `scripts/mdt/Initialize-MDTDeploymentShare.ps1` — one-time deployment share
    setup: imports WIM(s), creates UEFI task sequences (EFI 300 MB + MSR 16 MB +
    Windows), writes zero-touch CustomSettings.ini and standalone Bootstrap.ini
  - `scripts/mdt/Import-WimImages.ps1` — add or replace OS images in an existing
    share without full rebuild
  - `scripts/mdt/New-MDTMedia.ps1` — builds the operator payload ISO
    (`LiteTouchMedia_x64.iso`); operator uses Rufus to write to USB
  - `configs/mdt/CustomSettings.ini` — zero-touch template (all SkipXxx=YES,
    OSDDiskIndex=0, FinishAction=REBOOT, DeployRoot=.)
  - `configs/mdt/Bootstrap.ini` — standalone WinPE boot config
  - `docs/MDT.md` — full setup guide, operator instructions, CCTK integration,
    driver management, troubleshooting
- **`docs/USB_SETUP.md`** — rewritten as operator USB creation guide (Rufus workflow)
  replacing the manual diskpart partitioning instructions

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

### Changed
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

### Removed
- **`docs/SIGNING.md`** — enterprise PS1 code-signing guide removed; not relevant
  to the MDT standalone media workflow
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

