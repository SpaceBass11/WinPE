# Architecture

## Self-deploying Clonezilla ISO Workflow

The admin builds and syspreps a golden Windows 11 install, captures it
with Clonezilla, and produces a self-restoring ISO. The operator
flashes the ISO to a USB with Rufus, boots the target, and the ISO
restores Windows and runs first-boot automation without further
interaction.

```
Admin workstation (golden VM/hardware)
  |
  +-- Install Windows 11, apply updates, install required software
  +-- Stage first-boot automation under C:\ProgramData\ManualClonezilla\:
  |     Scripts\SetupComplete.cmd          (also copied to C:\Windows\Setup\Scripts\)
  |     Scripts\Apply-DellConfig.ps1
  |     Scripts\Enable-BitLocker.ps1
  |     Scripts\Finalize-Cleanup.ps1
  |     Config\dell-config.cctk
  |     Config\bitlocker-pin.txt
  +-- Stage answer file at C:\Windows\Panther\unattend.xml
  +-- sysprep /generalize /oobe /shutdown
                                         |
  +-- Boot Clonezilla Live, capture the disk
  +-- Generate self-deploying Clonezilla ISO (unattended restoredisk)
                                         |
Operator: Rufus --> USB --> boot target --> Clonezilla restores disk -->
  reboot --> Windows specialize + OOBE --> SetupComplete.cmd runs -->
  reboot --> login screen
```

### Prep time (admin Windows)

The admin workstation phase covers:

- Install/configure the reference Windows 11 install on a clean VM or
  reference hardware
- Install and validate any software that must ship in the image
- Pre-bake **drivers** for the target hardware family (chipset, NIC,
  storage). New hardware family = new image
- Stage post-deploy scripts in `C:\ProgramData\ManualClonezilla\Scripts\`
- Stage one-time inputs in `C:\ProgramData\ManualClonezilla\Config\`:
  the **CCTK** package `dell-config.cctk` and the **BitLocker** PIN
  file `bitlocker-pin.txt`
- Copy `SetupComplete.cmd` to `C:\Windows\Setup\Scripts\` (only this
  location is honored by the Windows specialize pass)
- Stage `unattend.xml` at `C:\Windows\Panther\unattend.xml`
- Run `sysprep /generalize /oobe /shutdown`
- Capture the disk with Clonezilla Live
- Generate a self-restoring Clonezilla ISO

### Run time (on the target)

When the operator boots from the USB:

1. **Clonezilla Live boots** from the USB into a minimal Linux
   environment.
2. **Unattended restoredisk** runs against the embedded captured
   image, blowing away the target disk and writing the golden image
   block-for-block.
3. **First reboot** into Windows.
4. **Windows specialize pass** runs, processing
   `C:\Windows\Panther\unattend.xml`: random ComputerName, OOBE skip,
   local account creation, time zone, etc.
5. **`C:\Windows\Setup\Scripts\SetupComplete.cmd`** runs once,
   automatically, after specialize completes. It calls in order:
   - `Apply-DellConfig.ps1` -- imports CCTK BIOS settings.
   - `Enable-BitLocker.ps1` -- TPM+PIN on C:, exports the recovery
     key to `State\BitLocker-RecoveryKey-<host>-<ts>.txt`.
   - `Finalize-Cleanup.ps1` -- removes `dell-config.cctk` and
     `bitlocker-pin.txt` from disk.
6. **Second reboot** activates any queued BIOS changes from CCTK and
   lands at the login screen.

Drivers are installed by Windows during specialize from the
driver store baked into the gold image. There is no online driver
acquisition step; if a hardware variant lacks drivers in the image,
the deploy fails to a non-functional state and the image must be
re-cut with that family's drivers added.

### File layout

| File / Directory | Role |
|---|---|
| `scripts/SetupComplete.cmd` | First-boot orchestrator. Copied to `C:\Windows\Setup\Scripts\` on the gold image |
| `scripts/Apply-DellConfig.ps1` | CCTK BIOS import. Idempotent via SHA256 marker |
| `scripts/Enable-BitLocker.ps1` | TPM+PIN enable + recovery key export |
| `scripts/Finalize-Cleanup.ps1` | Removes one-time secrets from disk |
| `configs/unattend.example.xml` | Skeleton answer file for the gold image |
| `docs/RUNBOOK.md` | End-to-end admin build process (source of truth) |
| `docs/OPERATIONS.md` | Day-2 ops, rotation, rollback, triage |
| `docs/USB_SETUP.md` | Operator SOP (Rufus + boot + recovery key collection) |
| `docs/UNATTEND.md` | unattend.xml reference for editing the skeleton |
| `docs/CCTK.md` | Dell CCTK details |
| `docs/TROUBLESHOOTING.md` | Failure modes and fixes |
| `docs/ARCHITECTURE.md` | This file |
| `CLAUDE.md` | Internal AI-coding guidance |
| `CHANGELOG.md` | Release history |
