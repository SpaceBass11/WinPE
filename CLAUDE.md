# Manual Clonezilla - Claude Code Guide

## Project Overview

This repo is the source for a **self-deploying Clonezilla ISO workflow**:
an admin builds a golden Windows 11 install with first-boot automation
scripts pre-staged, sysprep + captures it with Clonezilla, generates a
self-restoring ISO, and hands it to operators. Operators use Rufus to
write the ISO to a USB and boot target laptops. No deployment server,
no MDT, no PXE, no MDM, no AD.

Target audience: small homogeneous fleets where every machine wants the
same OS, same accounts, same BIOS posture, same BitLocker PIN. Accepted
risks are spelled out in `README.md`.

This is **not** the WinPE-based per-machine deploy tool that lives on
the `main` branch. That tool supports per-USB variation (different PIN
per laptop, different image per model). This Clonezilla workflow is the
opposite design point: identical deploys to identical hardware.

## Architecture

```
Admin workstation (one-time per release)
  +-- Build golden Win11 install on reference VM/hardware
  +-- Stage C:\ProgramData\ManualClonezilla\ before sysprep:
  |     Scripts\SetupComplete.cmd          (also copied to C:\Windows\Setup\Scripts\)
  |     Scripts\Apply-DellConfig.ps1
  |     Scripts\Enable-BitLocker.ps1
  |     Scripts\Finalize-Cleanup.ps1
  |     Config\dell-config.cctk
  |     Config\bitlocker-pin.txt
  +-- sysprep /generalize /oobe /shutdown
  +-- Clonezilla Live capture
  +-- Generate self-restoring Clonezilla ISO
                            |
Operator: Rufus -> USB -> boot -> walk away
                            |
On first boot (after Windows specialize completes):
  C:\Windows\Setup\Scripts\SetupComplete.cmd runs once and calls in order:
    1. Apply-DellConfig.ps1      (cctk --import dell-config.cctk)
    2. Enable-BitLocker.ps1      (TPM+PIN on C:, export recovery key to State\)
    3. Finalize-Cleanup.ps1      (delete dell-config.cctk, bitlocker-pin.txt)
```

## Key Files

| File | Purpose |
|------|---------|
| `scripts/SetupComplete.cmd` | First-boot orchestrator. Auto-runs from `C:\Windows\Setup\Scripts\` after Windows specialize. Calls the three PS1s in order. Any non-zero exit logs and exits. |
| `scripts/Apply-DellConfig.ps1` | Imports `Config\dell-config.cctk` via `cctk.exe --import`. Idempotent via SHA256 marker file in `State\`. Hard-fails when cctk.exe or the config file is missing (intentional — silent BIOS misconfig is worse than a loud failure). |
| `scripts/Enable-BitLocker.ps1` | Enables TPM+PIN on C: using the PIN from `Config\bitlocker-pin.txt`. Adds RecoveryPassword protector. Exports the recovery key to `State\BitLocker-RecoveryKey-<host>-<ts>.txt`. Hard-fails if either protector is missing after enable. |
| `scripts/Finalize-Cleanup.ps1` | Removes `dell-config.cctk` and `bitlocker-pin.txt` from disk. **Does not** remove `State\` (recovery key file lives there) or `Logs\`. |
| `configs/unattend.example.xml` | Skeleton answer file for the golden image. OOBE skip + UTC timezone + random ComputerName. Edit for your environment before baking into the gold. |
| `docs/RUNBOOK.md` | End-to-end admin build process. The source of truth. |
| `docs/OPERATIONS.md` | Day-2 ops: versioning, rotation, rollback, triage artifacts. |
| `docs/USB_SETUP.md` | Operator's SOP for Rufus + boot. |
| `docs/UNATTEND.md` | unattend.xml reference. |
| `docs/CCTK.md` | Dell CCTK details. |
| `docs/ARCHITECTURE.md` | Design rationale. |
| `docs/TROUBLESHOOTING.md` | Common failures. |

## Stable Files (Skip by Default)

Don't read these unless the user is specifically asking about
contribution policy, license, or security disclosure:

- `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE`
- `.editorconfig`, `.gitattributes`, `.gitignore`, `.lychee.toml`

## When Modifying Scripts

1. **PowerShell 5.1 compatibility.** The scripts run on a freshly
   deployed Windows 11 install during first-boot OOBE. PS 5.1 is what
   ships and is what runs `SetupComplete`. Don't use PS 7+ syntax
   (ternary operator, null-coalescing, `&&`/`||`, pipeline parallel).
2. **ASCII only in .ps1 / .cmd files.** PS 5.1 on Windows reads files
   without UTF-8 BOM as Windows-1252; non-ASCII characters trigger
   cascade parse failures. Use `--` not en/em dashes, `'` not curly
   quotes, etc.
3. **Idempotent.** Every script must safely re-run. `Apply-DellConfig`
   uses a SHA256 marker. `Enable-BitLocker` checks `ProtectionStatus`
   and `VolumeStatus` and returns early if already enabled.
4. **Logs are append.** All scripts use `Start-Transcript -Append` to
   the same file path. Don't truncate.
5. **Never weaken the BitLocker protector gates.** The script throws if
   the TpmPin or RecoveryPassword protector is missing after enable. An
   encrypted volume with no recovery protector is worse than no
   encryption. Don't relax these checks even under "the PIN file was
   missing so just enable TPM-only for now" pressure - hard-fail
   instead and surface the staging mistake.
6. **Never store the PIN in `State\`.** State is preserved across
   cleanup. The PIN lives in `Config\` (which Finalize-Cleanup wipes).
7. **Don't add a SecureString to disk.** `bitlocker-pin.txt` is
   plaintext by design (the trust model is documented in README); do
   not add fake "encrypt the PIN file" code that would imply a stronger
   guarantee than the workflow actually provides.

## When Modifying Docs

1. README.md is operator + admin-facing. Keep it scannable.
2. RUNBOOK.md is the source of truth for the admin build process. Other
   docs link to it; do not duplicate sequences in multiple files.
3. CLAUDE.md (this file) is internal AI-coding guidance. Update it when
   you change architecture, key files, or script invariants. Do not
   delete sections without checking they aren't relied on by another
   doc.
4. ASCII only in .ps1, .cmd, and .ini. Markdown can use Unicode but
   keep it conservative (em dashes are fine; box-drawing characters
   are not).

## CI

`.github/workflows/ci.yml` runs three jobs on push:

- **actionlint** - GitHub Actions workflow linting.
- **link-check** - Markdown link check across all `**/*.md`.
- **masterize** - Doc/script consistency checks. The current checks
  pin the BitLocker invariants (TPM+PIN protector, recovery key export
  path, PIN file path), the SetupComplete script orchestration, and
  basic doc coverage. See `.github/workflows/ci.yml` for the exact
  greps.

There are no PowerShell-syntax CI checks on this branch (no `pwsh` on
the GitHub runner for this repo). Run PSParser locally before pushing
script changes:

```bash
pwsh -NoProfile -Command "[System.Management.Automation.PSParser]::Tokenize((Get-Content scripts/Enable-BitLocker.ps1 -Raw), [ref]\$null)"
```

## Git Workflow (Claude Code Web)

Direct push to `main` is blocked by the Claude Code Web harness. Push
to a side branch:

```
git push -u origin <branch-name>
```

User opens a PR via the GitHub UI and merges. Do not retry failed
pushes to main - they will all fail.
