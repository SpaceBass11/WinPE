# Architecture

## MDT Standalone Media Workflow

MDT wraps the WinPE deployment engine in a build-time workflow. The admin
uses Deployment Workbench to configure a deployment share and build a
self-contained ISO; the LiteTouch WinPE inside that ISO runs the task
sequence on the target machine.

```
Admin workstation (Deployment Workbench)
  |
  +-- Create deployment share
  +-- Import OS WIM
  +-- Create task sequence (UEFI GPT partitions, DISM apply, unattend)
  +-- Configure zero-touch settings (Bootstrap.ini, CustomSettings.ini)
  +-- Import driver packages
  +-- Add applications (CCTK BIOS config, etc.)
  +-- Update Deployment Share  -->  LiteTouchPE_x64.wim
  +-- Create Media object
  +-- Update Media Content  -->  LiteTouchMedia_x64.iso
                                         |
Operator: Rufus --> USB --> boot --> LiteTouch WinPE runs:
  Format and Partition Disk (GPT: EFI 500 MB + MSR 128 MB + Windows; no recovery partition)
  Apply Operating System Image (DISM apply)
  Setup Windows
  --> Reboot --> Windows OOBE / unattend
```

### Prep time (admin Windows)

The admin workstation phase covers:

- Importing WIM(s) into the deployment share via Workbench
- Configuring the task sequence: UEFI GPT partitioning, DISM apply,
  unattend staging, STIG account steps, BitLocker enable
- Setting zero-touch CustomSettings.ini (all SkipXxx=YES, no prompts)
- Importing **driver** packages into the Out-of-Box Drivers node
- Dropping **CCTK** binaries + configs into `Tools\Dell-CCTK\` and calling them from a Run Command Line task sequence step
- Building the standalone ISO via Media > Update Media Content

### Run time (inside WinPE)

When the operator boots from USB, LiteTouch WinPE:

1. Reads `Bootstrap.ini` (`DeployRoot=.` -- self-contained, no network)
2. Reads `CustomSettings.ini` (all decisions pre-made; no operator prompts)
3. Runs the task sequence: partitions the disk, applies the WIM via DISM,
   stages the **unattend** file, runs **CCTK** BIOS config steps, configures
   the UEFI boot record
4. Reboots; Windows processes the answer file (OOBE skip, domain join,
   autologon)
5. **Driver** installation happens during Windows Setup from the injected
   driver store

### File layout

| File / Directory | Role |
|---|---|
| `configs/mdt/CustomSettings.ini` | Zero-touch settings reference (all SkipXxx=YES) |
| `configs/mdt/Bootstrap.ini` | Standalone WinPE boot config (`DeployRoot=.`) |
| `configs/unattend.example.xml` | Example answer file for OOBE, accounts, autologon |
| `docs/MDT.md` | Full Workbench walkthrough -- create share, import, configure, build ISO |
| `docs/CCTK.md` | Dell CCTK BIOS pre-configuration via Run Command Line |
| `docs/UNATTEND.md` | Unattend.xml reference |
| `docs/TROUBLESHOOTING.md` | Failure modes, fixes, and known caveats |
| `docs/ARCHITECTURE.md` | This file |
| `docs/USB_SETUP.md` | USB creation and operator boot instructions |
| `CLAUDE.md` | Contributor guide: project conventions |
| `CHANGELOG.md` | Release history |
