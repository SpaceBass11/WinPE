# Operations: Versioning, Rollback, and Guardrails

## Versioning standard

Track image metadata at:

- `C:\ProgramData\ManualClonezilla\ImageVersion.json`
- Include at minimum: release date, base OS build, model scope, script package
  version, and source image checksum.

## Guardrails

- Keep post-deploy scripts idempotent.
- Hard-fail when BIOS config import is required and fails.
- Hard-fail when BitLocker TpmPin or RecoveryPassword protectors are missing
  after `Enable-BitLocker.ps1` runs - an encrypted volume with no recovery
  protector is worse than no encryption at all.
- Soft-fail only for non-critical post steps.
- Persist logs to `C:\ProgramData\ManualClonezilla\Logs`.
- Persist BitLocker recovery key exports to `C:\ProgramData\ManualClonezilla\RecoveryKeys\`.
  Files are named `BitLocker-RecoveryKey-<hostname>-<timestamp>.txt`.
  Operators are responsible for collecting these files **off the machine**
  before user handoff.

## Dell model compatibility guardrails

- Do not assume one BIOS package is portable across all Dell families/generations.
- Track compatibility as a matrix (model family x BIOS package version x BIOS firmware version).
- Re-validate after BIOS firmware updates, because token availability/behavior can change.
- If mixed fleets must share one base image, make BIOS import model-aware rather than universal.
- Require explicit target-disk confirmation in operator SOP to prevent accidental
  wipe of non-target storage.

## Suggested release cadence

- Monthly patch-image refresh.
- Emergency release on critical CVE or tooling break.
- Retire N-2 images from operator distribution.

## Rollback

If validation fails or field issues rise:

1. Pull current ISO from distribution.
2. Reissue last known-good ISO.
3. Log issue and root cause before next release cut.
4. Publish an operator advisory including the exact rollback ISO filename.

## Support triage artifacts

Collect from impacted endpoint:

- `C:\ProgramData\ManualClonezilla\Logs\SetupComplete.log`
- `C:\ProgramData\ManualClonezilla\Logs\Apply-DellConfig.log`
- `C:\ProgramData\ManualClonezilla\Logs\Enable-BitLocker.log`
- `C:\ProgramData\ManualClonezilla\Logs\Finalize-Cleanup.log`

Additionally collect for Dell BIOS drift analysis:

- SMBIOS model and BIOS version (`wmic computersystem get model` and `wmic bios get smbiosbiosversion`).
- `cctk --export` output from the affected endpoint for diff against expected baseline.

Also collect:

- The ISO filename used during deployment.
- Device model and BIOS version.
- Timestamp of deployment attempt.

For BitLocker triage specifically:

- `C:\ProgramData\ManualClonezilla\RecoveryKeys\BitLocker-RecoveryKey-*.txt` (if any)
- `manage-bde -status C:` output
- `manage-bde -protectors -get C:` output
- `Get-Tpm | Format-List *` output (PowerShell)
