# Manual Clonezilla Runbook

## 1) Build the golden image

- Install Windows 11 on reference hardware/VM.
- Apply cumulative updates and required software.
- Validate hardware support scope (model list).
- Remove machine-specific artifacts (temporary users, cached credentials).

## 2) Stage first-boot automation assets

Place assets before sysprep in `C:\ProgramData\ManualClonezilla`:

- `Scripts\SetupComplete.cmd`
- `Scripts\Apply-DellConfig.ps1`
- `Scripts\Enable-BitLocker.ps1`
- `Scripts\Finalize-Cleanup.ps1`
- `Config\dell-config.cctk` (or generated Dell Command Configure package)

Dell Command | Configure caveats:

- Install Dell Command | Configure in the golden image and verify `cctk.exe`
  exists at `C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe`.
- Keep BIOS packages scoped per model family where possible and stage only the
  matching package for the target image.
- If supporting multiple model families, cut separate images or implement a
  model-aware wrapper that maps SMBIOS model to a matching `.cctk` file.

Then copy the SetupComplete launcher to the **required Windows Setup hook path**:

```cmd
mkdir C:\Windows\Setup\Scripts 2>nul
copy /y C:\ProgramData\ManualClonezilla\Scripts\SetupComplete.cmd C:\Windows\Setup\Scripts\SetupComplete.cmd
```

`SetupComplete.cmd` only auto-runs from `C:\Windows\Setup\Scripts`. If this copy step is skipped,
none of the post-deploy scripts execute.

Use `configs/unattend.xml` in this repository as the starting point for OOBE
suppression and local administrator behavior.

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
- Confirm BitLocker protector status and recovery key escrow process.
- Confirm cleanup removed one-time payloads.

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
   - Risk: Enabling BitLocker during `SetupComplete` can fail if TPM is present but not fully provisioned,
     or if your process requires escrow before encryption starts.
   - Fix: Keep the TPM readiness guard (already implemented) and validate escrow workflow in staging.
     If escrow must be guaranteed first, move encryption to a later managed step (for example MDM/GPO startup policy)
     instead of immediate `SetupComplete`.

3. **Cross-model BIOS package risk (medium):**
   - Risk: One Dell CCTK package may not apply cleanly across all model families.
   - Fix: Maintain model-scoped images/packages or add model detection logic before running CCTK.

4. **Sysprep recapture risk (low but common):**
   - Risk: Booting the reference OS after sysprep modifies state and can break capture consistency.
   - Fix: Enforce a strict capture-immediately policy and re-run sysprep if accidental boot occurs.
