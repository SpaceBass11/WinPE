# Deep Review (2026-05-11)

This review covers `unified_winpe_deploy.ps1`, `scripts/build_boot_wim.ps1`,
and `scripts/prepare_wim.ps1` at v4.6.0, with an emphasis on deployment
safety, operator ergonomics, and resilience in WinPE.

## Scope Reviewed

- Main deployment script flow and guardrails.
- Confirmation model around destructive operations.
- Image discovery and index parsing behavior.
- Partition/apply/boot verification sequence.
- Unattend.xml staging and first-boot answer-file path.
- CCTK pre-apply BIOS configuration flow.
- Multi-disk wipe stage and silent-mode validation.
- WIM prep companion script (`prepare_wim.ps1`): debloat, driver injection,
  Copilot registry tweak.
- Boot.wim builder (`build_boot_wim.ps1`): component install, reg tweaks,
  CCTK embed, startnet.cmd generation.
- Validation/test tooling availability and gaps.

## Strengths

1. **Layered destructive-action safeguards are well-designed.**
   - System disk protection has a separate `DESTROY SYSTEM` gate that
     `-Force` and `-Silent` can never bypass.
   - Generic wipe confirmation requires explicit `ERASE` text input.
   - Multi-disk wipe uses a single `WIPE ALL` gate covering the whole set.

2. **Operational reliability checks are present at key failure points.**
   - Post-diskpart drive-letter verification for both `S:` and `C:`.
   - Post-apply checks validate `C:\Windows` and `C:\Windows\System32`.
   - Unattend copy happens after verification and before BCDBoot — correct
     sequencing so a bad WIM apply can't leave a partial answer-file drop.
   - Boot setup failure path includes actionable manual remediation.

3. **WinPE-oriented implementation choices are intentional.**
   - Avoids advanced modules; uses CLI tools (`diskpart`, `dism`, `bcdboot`).
   - `Get-WmiObject` instead of `Get-CimInstance` for PS5.1 / WinPE compat.
   - `shutdown.exe /s /t` instead of `Stop-Computer` (reliable in WinPE).
   - Console fallback for Forms dialogs when `System.Windows.Forms` is absent.

4. **Fail-fast philosophy is consistently applied.**
   - `-UnattendFile` validated before any disk work (bad path aborts early).
   - `-DriverPath` validated before WIM mount (`.inf` count check).
   - CCTK non-zero exit aborts deploy before any disk is touched.
   - DISM `/CheckIntegrity` surfaces WIM corruption at apply time.
   - `-Silent` contract validated immediately on entry.

5. **try/finally cleanup in all three scripts.**
   - `build_boot_wim.ps1`: mid-build failure discards the mount, never
     commits a half-built image.
   - `prepare_wim.ps1`: ISO dismount, WIM dismount, and hive unload all
     in `finally` blocks; stale mount from prior failed run is detected and
     discarded before starting.
   - Deploy script: diskpart temp file cleaned up after success and failure.

## Risk Review

### High-risk areas that are currently mitigated

- **Wrong-disk targeting:** visible disk menu, system-disk danger labeling,
  and typed confirmations.
- **Silent partitioning failure:** post-operation verification of expected
  mount points (`S:` and `C:`) before DISM is called.
- **Image mismatch/corruption:** DISM `/CheckIntegrity` + explicit failure
  guidance on exit code 1.
- **Containers/Hyper-V layer apply failure:** `NtfsEnableDirCaseSensitivity`
  reg tweak baked into `boot.wim` by `build_boot_wim.ps1`; documented in
  TROUBLESHOOTING.md.
- **Linux/LVM disks appearing as empty:** `Get-SystemDisks` uses
  `Win32_DiskDrive.Partitions` (raw count) not `Win32_DiskPartition`.

### Medium-risk areas and current status

1. **Environment-level preflight validation is shell-dependent.**
   - `tests/test_parse.ps1` and `scripts/validate_script.ps1` require `pwsh`
     and cannot run in environments without PowerShell.
   - **Status:** Documented in KNOWN_ISSUES.md item 1. Workaround: run from
     any host with PowerShell installed. Non-Windows CI runners are out of
     scope for this tool.

2. **Review outcomes captured in durable artifacts.**
   - **Status:** Resolved. This file is the review artifact. The Masterize
     Checklist in `CLAUDE.md` provides a reproducible release-gate process
     with concrete grep/read checks covering all dimensions of this review.

3. **Recovery guidance log-location reminder.**
   - The script logs extensively to a timestamped file in the WinPE temp
     dir, but not every fatal exit re-prints the log file path.
   - **Status:** Resolved (2026-05-16). The outer `try/catch` at the
     bottom of `unified_winpe_deploy.ps1` now writes
     `Full log: $($Script:SystemPaths.LogFile)` on every fatal exit —
     both the `Start-Deployment` failed-return branch and the critical-
     exception `catch` block — guarded on `LogFile` being set.

## Ongoing Review Checklist

Use before each release (these checks are also encoded in the Masterize
Checklist in `CLAUDE.md` with executable grep commands):

- [ ] Version consistency: `.VERSION` header, `$Script:Config.ScriptVersion`,
      `CHANGELOG.md`, `KNOWN_ISSUES.md`, `CLAUDE.md`, `README.md`
- [ ] `-Force` behavior does **not** bypass system-disk typed confirmation
- [ ] Diskpart script: GPT + EFI(300MB/S:) + MSR(16MB) + Primary NTFS(C:)
- [ ] Post-diskpart verification (S: and C: exist) is intact
- [ ] Post-apply verification (`C:\Windows\System32` exists) is intact
- [ ] Unattend staging is between post-apply verify and BCDBoot call
- [ ] `dism /Get-WimInfo` uses `/English` for locale-safe parsing
- [ ] `bcdboot C:\Windows /s S: /f UEFI` is the configured boot path
- [ ] CCTK non-zero exit aborts before disk selection (no disks touched)
- [ ] `prepare_wim.ps1 -DriverPath` validates `.inf` count before mount
- [ ] All `try/finally` cleanup blocks intact in all three scripts

## Validation Notes

- PowerShell runtime (`pwsh`) is not present in the Linux CI/dev environment;
  syntax checks via `[System.Management.Automation.PSParser]::Tokenize` were
  not run. Static review was performed directly on repository source files.
- All three scripts pass structural grep checks (balanced braces, parameter
  presence, required function definitions) as verified by the Masterize
  Checklist run on 2026-05-11.
