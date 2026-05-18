# Architecture

## MDT Standalone Media Layer

MDT wraps the WinPE deployment engine in a build-time workflow. The admin uses three scripts to produce a self-contained ISO; the LiteTouch WinPE inside that ISO runs the task sequence on the target machine.

```
Admin workstation
  scripts/mdt/Initialize-MDTDeploymentShare.ps1  → deployment share + task sequences
  scripts/mdt/Import-WimImages.ps1               → OS library
  scripts/mdt/New-MDTMedia.ps1                   → LiteTouchMedia_x64.iso
                    ↓
  Operator: Rufus → USB → boot → LiteTouch WinPE runs:
    Format and Partition Disk (GPT: EFI 300 MB + MSR 16 MB + Windows)
    Apply Operating System Image (DISM apply)
    Setup Windows
    → Reboot → Windows OOBE/unattend
```

### Prep time (admin Windows)

The admin workstation phase covers:
- Importing WIM(s) into the deployment share
- Configuring task sequences (UEFI GPT partitioning, DISM apply, unattend staging)
- Setting zero-touch CustomSettings.ini (all SkipXxx=YES, no prompts)
- Optionally importing driver packages and CCTK config into the share
- Building the operator ISO with `New-MDTMedia.ps1`

Key items baked in at prep time include **driver** packages (imported via MDT Workbench or `Import-MDTDriver`), **unattend** answer files (staged via the task sequence's `Apply Windows PE` / `Setup Windows` steps), and **CCTK** BIOS config files (placed under `scripts\cctk\` in the deployment share for pre-apply).

### Run time (inside WinPE)

When the operator boots from the USB, LiteTouch WinPE:
1. Reads `Bootstrap.ini` (`DeployRoot=.` — self-contained, no network)
2. Reads `CustomSettings.ini` (all decisions pre-made; no operator prompts)
3. Runs the task sequence: partitions the disk, applies the WIM via DISM, stages the **unattend** file, runs any **CCTK** pre-apply steps, and configures the UEFI boot record
4. Reboots; Windows processes the answer file (OOBE skip, domain join, autologon)
5. **Driver** installation happens during Windows Setup from the injected driver store

### File Layout

| File / Directory | Role |
|---|---|
| `scripts/mdt/Initialize-MDTDeploymentShare.ps1` | One-time setup: deployment share, WIM import, task sequences, zero-touch config |
| `scripts/mdt/Import-WimImages.ps1` | Add/replace WIMs in an existing share |
| `scripts/mdt/New-MDTMedia.ps1` | Build the operator payload ISO (`LiteTouchMedia_x64.iso`) |
| `configs/mdt/CustomSettings.ini` | Zero-touch settings (all SkipXxx=YES, DeployRoot=.) |
| `configs/mdt/Bootstrap.ini` | Standalone WinPE boot config |
| `tests/test_parse.ps1` | PowerShell syntax validation. Runs in CI. |
| `PSScriptAnalyzerSettings.psd1` | Shared PSSA rule config. Used locally and in CI. |
| `docs/MDT.md` | Full MDT setup guide, operator instructions, CCTK, drivers, troubleshooting |
| `docs/SCRIPT_REFERENCE.md` | Parameter reference for MDT scripts |
| `docs/TROUBLESHOOTING.md` | Failure modes, fixes, and known caveats |
| `docs/ARCHITECTURE.md` | This file. |
| `docs/CCTK.md` | Dell CCTK pre-apply BIOS configuration |
| `docs/UNATTEND.md` | Unattend.xml answer file reference |
| `.claude/MASTERIZE.md` | Internal: release-audit playbook (per-release, not per-session) |
| `CLAUDE.md` | Contributor-facing: project conventions and safety rules |
| `CHANGELOG.md` | Release history (keepachangelog) |

## WinPE Tool Layer (main branch)

The WinPE tool layer (`unified_winpe_deploy.ps1`, `build_boot_wim.ps1`, `prepare_wim.ps1`) lives on the main branch of this repo. This MDT branch replaces those scripts with an MDT standalone media workflow — see `docs/MDT.md` for the full reference.
