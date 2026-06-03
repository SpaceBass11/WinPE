# Manual Clonezilla Runbook

## 1) Build the golden image

- Install Windows 11 on reference hardware/VM.
- Apply cumulative updates and required software.
- Validate hardware support scope (model list).
- Remove machine-specific artifacts (temporary users, cached credentials).

## 2) Stage first-boot automation assets

Place assets before sysprep in `C:\ProgramData\ManualClonezilla`:

- `Scripts\SetupComplete.cmd`
- `Scripts\Common.ps1` (shared helper functions; dot-sourced by the scripts below -- must be staged or they fail)
- `Scripts\Apply-DellConfig.ps1`
- `Scripts\Scrub-AuditArtifacts.ps1`
- `Scripts\New-LocalAccounts.ps1`
- `Scripts\Stage-DockerData.ps1` (optional; only does anything if a Docker payload is staged -- see "Docker data disk" below)
- `Scripts\Set-Level0ACL.ps1`
- `Scripts\Disable-RDP.ps1` (currently lined out of `SetupComplete.cmd`; still staged)
- `Scripts\Harden-Administrator.ps1`
- `Scripts\Apply-StigHardening.ps1` (currently lined out of `SetupComplete.cmd`; still staged)
- `Scripts\Enable-BitLocker.ps1`
- `Scripts\Install-NotepadPP.ps1`
- `Scripts\Finalize-Cleanup.ps1`
- `Config\dell-config.cctk` (Dell Command Configure package)
- `Config\bitlocker-pin.txt` (single-line plaintext PIN for TPM+PIN -- copy
  `configs/bitlocker-pin.example.txt` and replace the placeholder)
- `Config\accounts.csv` (named local accounts; `Username,Password,Role` --
  see `configs/accounts.example.csv`. Plaintext, baked into the image, same
  accepted risk as the PIN file; deleted by `Finalize-Cleanup.ps1`.)
- `Installers\npp-installer.exe` (Notepad++ NSIS installer; installed silently
  with `/S` at first boot since sysprep strips provisioned apps)
- `Payload\docker_data.vhdx` (optional; the Docker Desktop WSL persistent data
  disk to seed into Level 1 -- see "Docker data disk" below. Omit if the fleet
  has no Docker payload.)

The first-boot chain runs in this order: Apply-DellConfig -> Scrub-AuditArtifacts
-> New-LocalAccounts -> Stage-DockerData (non-fatal) -> Set-Level0ACL ->
~~Disable-RDP~~ (lined out) -> Harden-Administrator -> ~~Apply-StigHardening~~
(lined out) -> Enable-BitLocker -> Install-NotepadPP (non-fatal) ->
Finalize-Cleanup. Build the gold master in
**audit mode** under the built-in
Administrator; the named accounts and hardening are applied at first boot, not
in the GM. Set unattend `CopyProfile=true` (specialize pass) if you want new
accounts to inherit the Administrator profile -- it is processed before the
first-boot Administrator rename/disable, so the two do not race.

> **Temporarily disabled steps:** the `Disable-RDP` and `Apply-StigHardening`
> calls are currently REM-commented in `SetupComplete.cmd`. Until they are
> restored, deployed machines keep **RDP enabled** and do **not** receive the
> STIG baseline (Guest disable, password/lockout policy, UAC hardening, logon
> banner, and the only-IT_Admin-in-Administrators assertion).

### Clean the Administrator profile before sysprep

Because `CopyProfile=true` clones the *entire* built-in Administrator profile
into the Default profile during specialize, any junk accumulated while building
in audit mode (browser/Edge first-run state, `%TEMP%`, recent-docs) gets baked
into Default and inherited by every new account. Before sysprep, clean the
Administrator profile -- clear `%TEMP%`, browser data, and recent items -- so
the Default template stays tidy. Do **not** delete the Administrator profile
itself here: CopyProfile needs it at sysprep time. `sysprep /generalize`
processes CopyProfile (copying the Administrator profile to Default) and then
**deletes the built-in Administrator profile itself**, so a properly generalized
deploy has no leftover `C:\Users\Administrator` -- no deploy-side cleanup script
is required. (If you see `C:\Users\Administrator` while still in audit mode,
that is expected: the generalize step that removes it has not run yet.)

### BitLocker PIN file

`Enable-BitLocker.ps1` reads the PIN from
`C:\ProgramData\ManualClonezilla\Config\bitlocker-pin.txt` and enables a
TpmAndPin protector on `C:`. One line, no quoting, no trailing newline
required. The "Allow enhanced PINs for startup" policy must already be
enabled in the gold image if the PIN uses non-numeric characters.

The PIN file is **baked into the captured image**, so anyone with the ISO
can read it. This is an accepted-risk same-PIN-fleet-wide design; if you
need per-machine PINs, this workflow is the wrong tool. `Finalize-Cleanup.ps1`
deletes the PIN file at end of `SetupComplete`, so the deployed machine
does not retain it on disk.

### Docker data disk

If the fleet ships with pre-loaded Docker images/volumes, stage the Docker
Desktop WSL **data** disk so a deployed machine comes up with that data already
present for the `Level 1` user.

- Install Docker Desktop (WSL2 backend) **machine-wide** in the gold. The
  per-user WSL distro registration and an empty data disk are created on each
  user's first Docker run -- so this does **not** require Level 1 to exist in
  the gold, and the gold can stay a clean Administrator-only sysprep.
- Build/populate `docker_data.vhdx` once (any throwaway account or a separate
  workstation), then drop it at
  `C:\ProgramData\ManualClonezilla\Payload\docker_data.vhdx` before sysprep.
  Treat it as a versioned release artifact rather than rebuilding it inside
  every gold. (It is gitignored -- never commit the VHDX.)

At first boot, `Stage-DockerData.ps1` runs after `New-LocalAccounts`. Level 1's
profile does **not** exist yet (the account is created but never logged in), so
the script calls the Win32 `CreateProfile` API to register a real profile for
Level 1 (seeded from Default) and copies the data disk into
`AppData\Local\Docker\wsl\disk\`. Because Level 1 has never logged in, Docker is
not running and the `.vhdx` is not locked -- no shutdown dance. The step is
**non-fatal**: a missing or failed payload never aborts the security chain, and
`Finalize-Cleanup.ps1` reclaims the staged copy once it has been seeded.

> **Bench-test before relying on it.** This *pre-seeds* the disk before Docker's
> first run for Level 1. Only *overwriting an already-present* disk is
> confirmed-working; whether Docker **adopts** a pre-placed disk on first launch
> (vs. recreating an empty one and stomping it) has not been validated. On a
> test deploy, log in as Level 1, start Docker, and confirm the seeded
> images/volumes are present. If Docker stomps the pre-seed, switch to a
> Level-1 first-logon overwrite (scheduled task that stops Docker + `wsl
> --shutdown`, then overwrites the disk Docker created).

### Dell Command | Configure

- Install Dell Command | Configure in the golden image and verify `cctk.exe`
  exists at `C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe`.
- Keep BIOS packages scoped per model family where possible and stage only the
  matching package for the target image.
- If supporting multiple model families, cut separate images or implement a
  model-aware wrapper that maps SMBIOS model to a matching `.cctk` file.

### Copy the SetupComplete launcher to the required Windows Setup hook path

```cmd
mkdir C:\Windows\Setup\Scripts 2>nul
copy /y C:\ProgramData\ManualClonezilla\Scripts\SetupComplete.cmd C:\Windows\Setup\Scripts\SetupComplete.cmd
```

`SetupComplete.cmd` only auto-runs from `C:\Windows\Setup\Scripts`. If this copy step is skipped,
none of the post-deploy scripts execute.

Use `configs/unattend.example.xml` in this repository as the starting point
for OOBE suppression and local administrator behavior.

## 3) Sysprep and shutdown

Run elevated:

```cmd
%WINDIR%\System32\Sysprep\Sysprep.exe /generalize /oobe /shutdown
```

Do not boot the OS after sysprep; capture immediately.

## 4) Capture with Clonezilla

- Boot Clonezilla live media.
- Choose device-image capture mode.
- Save to secured storage.
- Naming pattern recommendation:
  `win11-<release>-<yyyy-mm-dd>-<model-scope>-v<semver>`

Example:
`win11-24h2-2026-05-19-latitude7x40-v1.3.0`

## 5) Build self-deploying ISO

Use Clonezilla's recovery ISO generation feature against the captured image.
Enable unattended restore with a conservative post-action (reboot or poweroff,
per your workflow).

## 6) Validate in staging

- Restore to each supported model family.
- Verify `%WINDIR%\Setup\Scripts\SetupComplete.cmd` exists pre-capture and that
  `C:\ProgramData\ManualClonezilla\Logs\SetupComplete.log` is produced post-restore.
- Confirm Dell config import status and BIOS token application per model family.
- Confirm BitLocker:
  - `manage-bde -status C:` shows protection enabled (or encryption in progress).
  - `manage-bde -protectors -get C:` lists both a TPM And PIN protector and a
    Numerical Password (recovery) protector.
  - `C:\ProgramData\BitLockers\BitLocker-RecoveryKey-*.txt` exists
    and contains a 48-digit recovery password.
  - PIN file `C:\ProgramData\ManualClonezilla\Config\bitlocker-pin.txt` is
    gone (Finalize-Cleanup ran).
- Confirm accounts: `Level 0`-`Level 3` exist as standard users, `IT_Admin`
  is a local administrator, and `Level 0` cannot open `C:\Programs` or
  `C:\Users\Public\Desktop\Quick Links`.
- Confirm the built-in Administrator is disabled and renamed (RID 500 account).
- Confirm RDP is disabled (`fDenyTSConnections=1`, service Disabled).
- Confirm Notepad++ installed (`notepad++.exe` present).
- Confirm cleanup removed one-time payloads (including `Config\accounts.csv`).

Recommended Dell-specific validation per model family:

- Check `Apply-DellConfig.log` for non-zero exit codes.
- Export post-apply BIOS settings with `cctk --export` and compare against the
  expected baseline for that model family.
- Validate TPM/Secure Boot states required for your BitLocker policy.

## 7) Release

- Publish checksum + ISO version.
- Publish operator SOP (USB creation + boot instructions).
- Keep previous known-good ISO available for rollback.

## Sequencing risks and fixes

1. **SetupComplete location risk (high):**
   - Risk: Staging `SetupComplete.cmd` only under `C:\ProgramData\...` does not trigger execution.
   - Fix: Copy it to `C:\Windows\Setup\Scripts\SetupComplete.cmd` before sysprep.

2. **BitLocker timing risk (medium):**
   - Risk: Enabling BitLocker during `SetupComplete` can fail if TPM is present but not fully provisioned.
   - Fix: TPM readiness guard remains (`Get-Tpm` `TpmPresent`/`TpmReady`). If it
     fails on a clean machine, clear the TPM in BIOS and redeploy.

3. **Lost recovery key risk (medium):**
   - Risk: This is an offline, unmanaged workflow. Recovery keys are written to
     `C:\ProgramData\BitLockers\` (ACL-locked to administrators) and stay there
     until manually collected. A user-initiated reset or reimage wipes them.
   - Fix: Operator SOP must include "collect the recovery key file off the
     machine before handing over" (log in as `IT_Admin`; the built-in admin is
     disabled). If you need centralized escrow, replace `Export-RecoveryKey` in
     `Enable-BitLocker.ps1` with a write to your shared/SMB/MDM target instead
     of `C:\ProgramData\BitLockers\`.

4. **Cross-model BIOS package risk (medium):**
   - Risk: One Dell CCTK package may not apply cleanly across all model families.
   - Fix: Maintain model-scoped images/packages or add model detection logic before running CCTK.

5. **Sysprep recapture risk (low but common):**
   - Risk: Booting the reference OS after sysprep modifies state and can break capture consistency.
   - Fix: Enforce a strict capture-immediately policy and re-run sysprep if accidental boot occurs.

6. **Administrators-group assertion (by design):**
   - Risk: `Apply-StigHardening.ps1` hard-fails the deploy if any account other
     than `IT_Admin` and the disabled built-in admin is in local Administrators.
   - Fix: This is intentional -- it guarantees `Level 0`-`Level 3` stay standard
     users. If it fires, fix the `Role` column in `accounts.csv` (only `IT_Admin`
     should be `Admin`).
