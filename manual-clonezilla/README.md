# manual-clonezilla

Self-deploying Clonezilla workflow for offline, low-touch Windows 11 reimaging.

This feature package is for teams that want a pragmatic alternative to MDT: build
one golden image, capture once, generate a self-restoring ISO, and let operators
run a single USB boot workflow.

## Outcome

**Operator flow:** download ISO -> Rufus -> boot target machine -> walk away.

## Workflow (admin)

1. Build and validate a golden Windows install.
2. Stage one-time deployment assets (Dell config + post-deploy scripts) and copy `SetupComplete.cmd` to `C:\Windows\Setup\Scripts`.
3. Run `sysprep /generalize /oobe /shutdown`.
4. Capture image with Clonezilla.
5. Create self-deploying Clonezilla ISO.
6. Hand ISO to operators.

Detailed runbook: [docs/RUNBOOK.md](docs/RUNBOOK.md)

## Included assets

- `docs/RUNBOOK.md` - End-to-end build and release process.
- `docs/OPERATIONS.md` - Day-2 operations, rotation, and rollback.
- `configs/unattend.xml` - First-boot automation hook skeleton.
- `scripts/SetupComplete.cmd` - Orchestrates post-deploy PowerShell scripts.
- `scripts/Apply-DellConfig.ps1` - Imports Dell Command | Configure package.
- `scripts/Enable-BitLocker.ps1` - Safe BitLocker enablement gates.
- `scripts/Finalize-Cleanup.ps1` - Deletes one-time deployment artifacts.

## Design goals

- No deployment network required at imaging time.
- Minimal operator decisions.
- Idempotent post-deploy scripts with persistent logging.
- Clear release/version markers and rollback path.

## Security notes

Treat deployment ISO as sensitive media when it contains BIOS config packages,
certificates, or operational secrets. Rotate and retire old images with a fixed
cadence.

## Dell Command | Configure compatibility notes

- Current automation is **Dell-only** and expects Dell Command | Configure
  `cctk.exe` at `C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe`.
- `scripts/Apply-DellConfig.ps1` hard-fails when either `dell-config.cctk` or
  `cctk.exe` is missing. This is intentional to avoid silently shipping systems
  with incorrect BIOS posture.
- The same `.cctk` package may not apply cleanly across different Dell model
  families (for example, Latitude vs OptiPlex vs Precision) because available
  BIOS tokens differ by generation/platform.
- Maintain per-model-family config packages and validate each family in staging
  before release.
