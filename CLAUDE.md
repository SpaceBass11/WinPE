# Manual Clonezilla - Claude Code Guide

## Project Direction (read first)

This branch is the **active development line**. The end goal is a
single self-deploying Clonezilla ISO that fully images a Dell laptop
fleet with Windows 11, TPM+PIN BitLocker, and a Dell BIOS posture --
no deployment server, no per-machine variation, no MDM.

> **Posture note (branch `claude/wizardly-meitner-Wj9fu` and successors):**
> This line extends the workflow beyond "restore and walk away". The gold
> master is built in **audit mode** under the built-in Administrator; the
> first-boot chain (unattend + `SetupComplete.cmd` PS1s) intentionally makes
> the deployed machine **diverge** from the GM: it provisions named accounts
> (`Level 0`-`Level 3`, `IT_Admin`), applies Level 0 lockdown ACLs, hardens
> the built-in Administrator (STIG rename/disable), disables RDP, installs
> Notepad++, and enables BitLocker. That divergence is the deploy-time half
> of the audit-mode build, **not** a violation of the "identical deploys"
> idea -- every deployed machine still ends up identically configured. The
> "no app install / walk away minimalism" entries in the locked table below
> describe the *narrower* clonezilla-v2 origin; on this line they have been
> deliberately relaxed by the user. Do not re-flag account creation, app
> install, or the `C:\ProgramData\BitLockers` key path as scope violations.

**Branches in the repo and what they mean:**

| Branch | Status | Use |
|---|---|---|
| `main` | active alternate | WinPE per-USB deploy tool. Different design point (per-machine variation: different PIN per laptop, different image per model). Kept for environments that need it. Do not pollute with Clonezilla-specific work. |
| `claude/clonezilla-v2` | **current active** | The Clonezilla pivot. This is the one being iterated. |
| `feature-clonezilla` | parent / archive | The original Clonezilla branch that this one was forked from. Carried MDT scaffolding alongside; `claude/clonezilla-v2` is the cleaned-up successor. |
| `feature-mdt`, `feature-manual-mdt-guide` | dead end | Earlier MDT-based pivot. Abandoned -- too much surface area for a static fleet. |
| `feature-SimplifiedManualUse` | dead end | Earlier exploration. Superseded. |
| `archive-*` | archive | Historical states preserved for reference. Don't build on these. |

**If you're starting a fresh session and not sure which branch to use:**
- For Clonezilla work -> `claude/clonezilla-v2` (or the branch it
  eventually merges into).
- For the WinPE per-USB tool -> `main`.
- Anything else -> ask the user first; the repo has a lot of history.

## Established Design Decisions (do not relitigate)

These were settled in the design conversation that produced this
branch. A future session should treat them as fixed input, not open
questions. If the user explicitly says "let's revisit X", fine -- but
don't propose changing them unprompted.

| Decision | Position |
|---|---|
| Per-machine vs. fleet-wide BitLocker PIN | **Same PIN across the fleet.** Accepted risk. The Yubikey or static-password mechanism that the operator uses to type the PIN at the BitLocker prompt is **out of scope for this repo** -- it's configured on the gold image's BitLocker policy and at PIN-entry time, not by these scripts. The scripts just take a plaintext PIN from `Config\bitlocker-pin.txt` and pass it to `Enable-BitLocker`. |
| BitLocker recovery key escrow | **Local-only.** Written to `C:\ProgramData\BitLockers\BitLocker-RecoveryKey-<host>-<ts>.txt` on the deployed machine (ACL-locked to SYSTEM + Administrators). No AD, no MDM, no SMB upload. Operator collects via SOP. The user does **not** want AD/MDM/Intune integration. If a future session is asked to add escrow, confirm the user has changed environments before implementing. |
| Computer name | **Random** via Windows default (`ComputerName` not set in unattend). No fixed pattern. |
| Sysprep rearm limit | **Not a concern.** Modern Windows lifts the limit. Don't add `SkipRearm` workarounds. |
| AHCI vs. RAID at deploy time | **Handled by operator SOP, not by these scripts.** Clonezilla won't see RAID-mode disks, which is a clean fail. The operator PDF tells them to switch to AHCI in BIOS and retry. Do not try to fix RAID mode programmatically. |
| Hardware diversity | **One image per hardware family.** Drivers are baked in. New laptop model = new gold image = new ISO. Do not add online driver fetch or runtime model detection. |
| Network at deploy time | **None.** Offline, unmanaged. No PXE, no MDT server, no MDM enrollment. |
| Per-USB customization | **Not needed.** Every deployed machine is identical. The `deploy.args` mechanism from the WinPE branch does not exist here and should not be ported. |
| Operator workflow | Download ISO -> Rufus -> USB -> boot -> walk away. **No PowerShell, no diskpart, no scripts.** Anything more than that is a regression. |
| IT_Admin password | **Static, fleet-wide**, from `accounts.csv`, same trust model as the BitLocker PIN. Accepted risk: one compromised laptop yields IT_Admin creds valid across identical machines. Per-machine rotation/escrow was considered and **declined** by the user. Documented in README. Don't add LAPS-style rotation unless the user changes this. |
| Named-account password expiry | Role accounts (`Level 0`-`Level 3`, `IT_Admin`) are created `PasswordNeverExpires`. This is an **accepted deviation** from the `MaximumPasswordAge` control that `Apply-StigHardening.ps1` sets via secedit -- a static fleet image shouldn't lock its role accounts out on a timer. A STIG scanner will flag the never-expire accounts; that's expected. |

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
    2. Scrub-AuditArtifacts.ps1  (clear Winlogon autologon + Panther unattend)
    3. New-LocalAccounts.ps1     (Level 0-3 + IT_Admin from accounts.csv)
    4. Set-Level0ACL.ps1         (Deny ACE for Level 0 on restricted folders)
    5. Disable-RDP.ps1           (fail-safe RDP off)
    6. Harden-Administrator.ps1  (STIG rotate/disable/rename built-in admin)
    7. Apply-StigHardening.ps1   (Guest, password/lockout, UAC, firewall, banner)
    8. Enable-BitLocker.ps1      (TPM+PIN on C:, export recovery key to C:\ProgramData\BitLockers\)
    9. Install-NotepadPP.ps1     (silent /S install; NON-FATAL)
   10. Finalize-Cleanup.ps1      (delete dell-config.cctk, bitlocker-pin.txt, accounts.csv)
```

## Key Files

| File | Purpose |
|------|---------|
| `scripts/SetupComplete.cmd` | First-boot orchestrator. Auto-runs from `C:\Windows\Setup\Scripts\` after Windows specialize. Calls the PS1s in order. Any non-zero exit logs and exits -- except the non-fatal Notepad++ install. Order: Apply-DellConfig -> Scrub-AuditArtifacts -> New-LocalAccounts -> Set-Level0ACL -> Disable-RDP -> Harden-Administrator -> Apply-StigHardening -> Enable-BitLocker -> Install-NotepadPP (non-fatal) -> Finalize-Cleanup. |
| `scripts/Apply-DellConfig.ps1` | Imports `Config\dell-config.cctk` via `cctk.exe --import`. Idempotent via SHA256 marker file in `State\`. Hard-fails when cctk.exe or the config file is missing (intentional — silent BIOS misconfig is worse than a loud failure). |
| `scripts/Scrub-AuditArtifacts.ps1` | Clears audit-mode/sysprep secret leftovers: Winlogon `AutoAdminLogon`/`DefaultPassword`/`DefaultUserName`/`DefaultDomainName`, and processed `Panther\unattend.xml` copies. Runs early so secrets are gone before the rest of the chain. Idempotent. |
| `scripts/New-LocalAccounts.ps1` | Creates `Level 0`-`Level 3` (Standard, local Users) and `IT_Admin` (Admin, local Administrators) from `Config\accounts.csv` (`Username,Password,Role`). Plaintext passwords, same trust model as the PIN file; wiped by Finalize-Cleanup. Idempotent (re-asserts password/enabled/membership). Groups resolved by well-known SID. |
| `scripts/Set-Level0ACL.ps1` | Inherited Deny (Full) ACE for `Level 0` on `C:\Programs` and `C:\Users\Public\Desktop\Quick Links` (can neither see nor modify). Idempotent (clears prior Deny first). Missing folder = warn; missing account = hard fail. |
| `scripts/Harden-Administrator.ps1` | STIG: disables built-in Administrator (first), rotates its password to random, renames it off "Administrator" to a random `x`-prefixed name. Found by RID 500 (SID), not name. Never logs the new name. `IT_Admin` is the admin going forward. |
| `scripts/Disable-RDP.ps1` | Fail-safe RDP off: `fDenyTSConnections=1` (read back + hard-fail if not applied), NLA, "Remote Desktop" firewall group disabled, `TermService`/`UmRdpService` Disabled. (RDP was only on for Hyper-V enhanced session during build.) |
| `scripts/Apply-StigHardening.ps1` | STIG baseline the other scripts don't cover: disables/renames Guest (RID 501); password + lockout policy via `secedit`; UAC (`EnableLUA`, secure-desktop consent, `FilterAdministratorToken`); firewall profiles on + default inbound block (best-effort); logon banner + `DontDisplayLastUserName`; and a **hard-fail assertion** that only `IT_Admin` + the disabled built-in admin are in local Administrators. |
| `scripts/Enable-BitLocker.ps1` | Enables TPM+PIN on C: using the PIN from `Config\bitlocker-pin.txt`. Adds RecoveryPassword protector. ACL-locks `C:\ProgramData\BitLockers` to SYSTEM + Administrators, then exports the recovery key to `BitLocker-RecoveryKey-<host>-<ts>.txt` there. Skip-path (already-encrypted) still guarantees a recovery protector + key file. Hard-fails if either protector is missing after enable. |
| `scripts/Install-NotepadPP.ps1` | Silent (`/S`) install from `Installers\npp-installer.exe`. **Non-fatal** by design (exits 0 even on failure) so it cannot abort the security chain. |
| `scripts/Finalize-Cleanup.ps1` | Removes `dell-config.cctk`, `bitlocker-pin.txt`, and `accounts.csv` from disk. **Does not** remove `State\`, `C:\ProgramData\BitLockers\` (recovery key files live there), or `Logs\`. |
| `configs/unattend.example.xml` | Skeleton answer file for the golden image. `specialize` CopyProfile=true + OOBE skip + UTC timezone + random ComputerName. Edit for your environment before baking into the gold. |
| `configs/accounts.example.csv` | Template for the staged `Config\accounts.csv`. Edit with real passwords before baking; never commit the real file. |
| `docs/RUNBOOK.md` | End-to-end admin build process. The source of truth. |
| `docs/OPERATIONS.md` | Day-2 ops: versioning, rotation, rollback, triage artifacts. |
| `docs/USB_SETUP.md` | Operator's SOP for Rufus + boot. |
| `docs/UNATTEND.md` | unattend.xml reference. |
| `docs/CCTK.md` | Dell CCTK details. |
| `docs/ARCHITECTURE.md` | Design rationale. |
| `docs/TROUBLESHOOTING.md` | Common failures. |

## Reading Order for a Fresh Session

If you're a new Claude session joining this project, read in this
order before doing anything:

1. This file's **Project Direction** and **Established Design
   Decisions** sections (above). Locks in scope.
2. `README.md`. Front-page narrative + the BitLocker PIN trust model.
3. `docs/RUNBOOK.md`. Source of truth for the admin build process.
4. `CHANGELOG.md` Unreleased section. What's landed on this branch.
5. `git log --oneline -20`. Recent direction.

If the user asks "what's pending?", point them at the "Known Pending
Work" section below.

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

## Known Pending Work

Not blocking the current branch but worth knowing about. A new session
can pick any of these up if the user asks for "what's next" or "any
loose ends."

1. **Bench-test `Enable-BitLocker.ps1` on a Windows sysprep VM with a
   virtual TPM.** The script is PSParser-clean and the logic is sound,
   but the actual `Enable-BitLocker -TpmAndPinProtector` and
   `Add-BitLockerKeyProtector -RecoveryPasswordProtector` calls have
   not been exercised on a real Windows host from this session
   (Claude Code Web has no Windows runner). The user should validate
   before cutting a release ISO.
2. **`.claude/MASTERIZE.md` and `.claude/masterize-log.md` still
   reference MDT / the old WinPE scripts** (the prior pivots' review
   playbooks). The stale slash-command files (`.claude/commands/review.md`,
   `deep-review.md`, `strip-dead-code.md`) that pointed at `scripts/mdt/`
   have been **deleted**. MASTERIZE.md / masterize-log.md remain and could
   still be rewritten for the Clonezilla shape, but no longer break a
   slash command.
3. **Repo rename consideration.** GitHub URL is still
   `SpaceBass11/WinPE`. Workflow has moved away from WinPE. The user's
   call -- don't rename without explicit instruction (URLs are sticky
   and break inbound links).
4. **Operator handoff PDF.** Mentioned in conversation as "the PDF
   guide tells operators how to switch to AHCI." That document is not
   in this repo. If the user wants it tracked here, they'd need to
   say so explicitly; otherwise it lives outside.
5. **Per-model BIOS config.** Current `Apply-DellConfig.ps1` reads a
   single `dell-config.cctk`. If the fleet ever expands to mixed Dell
   families (Latitude + OptiPlex), the script would need model
   detection (`wmic computersystem get model`) and per-family `.cctk`
   selection. Currently out of scope -- accepted "one image per
   hardware family" position.

## Git Workflow (Claude Code Web)

Direct push to `main` is blocked by the Claude Code Web harness. Push
to a side branch:

```
git push -u origin <branch-name>
```

User opens a PR via the GitHub UI and merges. Do not retry failed
pushes to main - they will all fail.
