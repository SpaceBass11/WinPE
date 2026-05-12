# Architecture

High-level design notes for `unified_winpe_deploy.ps1`,
`scripts/build_boot_wim.ps1`, and `scripts/prepare_wim.ps1`. For
parameter / function reference, see
[SCRIPT_REFERENCE.md](SCRIPT_REFERENCE.md).

## Three Programs, One Product

```
┌───────────────────────────┐  ┌───────────────────────────┐  ┌───────────────────────────┐
│ scripts/prepare_wim.ps1   │  │ scripts/build_boot_wim.ps1│  │ unified_winpe_deploy.ps1  │
│                           │  │                           │  │                           │
│ Prep time (admin Windows) │  │ Build time (admin)        │  │ Run time (inside WinPE)   │
│  - mount ISO              │  │  - copype                 │  │  - discover .wim / .esd   │
│  - pick edition           │  │  - install components     │  │  - CCTK pre-apply (Dell)  │
│  - debloat (whitelist)    │  │  - reg tweak              │  │  - pick image + disk      │
│  - optional reg tweaks    │→ │  - embed deploy script    │→ │  - optional extra wipe    │
│  - export Compress:max    │  │  - optional CCTK embed    │  │  - diskpart GPT           │
│  - WIM ready for IMAGES   │  │  - write startnet.cmd     │  │  - dism /apply-image      │
│  - optional drivers       │  │  - commit boot.wim        │  │  - unattend staging       │
│                           │  │                           │  │  - bcdboot (UEFI)         │
└───────────────────────────┘  └───────────────────────────┘  └───────────────────────────┘
        outputs                      outputs                       runs
   custom .wim file              boot.wim + media         from USB boot partition
```

`prepare_wim.ps1` runs once per WIM you want to ship. `build_boot_wim.ps1`
runs once per WinPE version change (or whenever you re-bake CCTK in).
`unified_winpe_deploy.ps1` runs every time you deploy. All three are
optional in the sense that `prepare_wim` can be skipped if you have a
WIM from elsewhere, and `build_boot_wim` can be skipped if you already
have a compatible boot.wim.

## Runtime Data Flow

```
[USB Boot]  FAT32 partition → WinPE loads → startnet.cmd
                                           → wpeinit
                                           → probe D:-Z: for "IMAGES" label
                                           → export %DEPLOY_IMAGE_DRIVE%
                                           → powershell -File X:\scripts\...ps1

[Deploy]  Administrator check
        → Silent-mode contract check (if -Silent: -WimFile/-TargetDisk/-Force/-WipeDisks format)
        → Image discovery
             ├── -WimFile?          → direct path
             ├── -ImagePath?        → search directory
             ├── $DEPLOY_IMAGE_DRIVE → search drive
             └── fall back          → scan all non-system drives
        → TUI: select image
        → DISM /Get-WimInfo → TUI: select edition (index)
        → WinPE environment check (blocks unless CONTINUE ANYWAY)
        → Memory check (8GB warn)
        → CCTK pre-apply (if X:\cctk\cctk.exe present)
             ├── pick config: <SERVICETAG>.ini → <MODEL>.ini → default.ini
             ├── apply: cctk --infile=<picked>
             └── non-zero exit       → abort deploy (no disks touched yet)
        → TUI: select target disk
             ├── system disk?       → type DESTROY SYSTEM
             ├── -TargetDisk only?  → type ERASE
             └── final confirm      → type ERASE
        → TUI: optional additional-wipe disks
             └── single WIPE ALL    → clean-only preamble in same diskpart session
        → Disk size vs image size validation
        → Free C: / S: drive letters (never system drive)
        → diskpart: [extra disk cleans] + clean + GPT + EFI 300MB (S:) + MSR 16MB + NTFS (C:)
        → Post-diskpart: verify S: and C: exist
        → dism /apply-image /CheckIntegrity (inline progress)
        → Post-deploy: verify C:\Windows\System32 exists
        → Unattend staging (if -UnattendFile): copy to C:\Windows\Panther\unattend.xml
        → bcdboot C:\Windows /s S: /f UEFI
        → Optional shutdown prompt → final reboot activates queued CCTK BIOS
             └── Windows Setup reads unattend.xml on first boot (OOBE, domain join, etc.)
```

## Why These Choices

### Diskpart for partitioning, not Storage cmdlets
`Initialize-Disk` / `New-Partition` / `Format-Volume` have inconsistent
behavior across WinPE builds. Diskpart is a 30-year-old tool that works
the same way everywhere. The script emits a text script and pipes it
in, then verifies the result out-of-band (checks S: and C: exist)
because `diskpart.exe` exit code 0 does not mean every command succeeded.

### Hard-coded C: and S:
The EFI partition and Windows partition letters are constants
everywhere in the script. Parameterizing them would mean threading two
more variables through every function for zero operational value — no
real deployment scenario benefits from a different letter scheme.

### GPT + UEFI only, no MBR / BIOS path
Supporting MBR doubles the testing matrix and every supported Windows
since 10 works better on UEFI. Drawing the line here keeps the safety
logic tractable. MBR support is a non-goal.

### `Write-Host` everywhere
The deploy script is a TUI, not a pipeline producer. Output needs to
land in the console in a specific color in a specific order for the
confirmation prompts to be readable. `Write-Output` would be captured
/ redirected / reordered by the pipeline in ways that break the user
experience.

### `Get-WmiObject`, not `Get-CimInstance`
CIM depends on WinRM plumbing that is not guaranteed in all WinPE
builds. WMI works in every ADK-built WinPE going back to Windows 7.
This intentionally trades a deprecation warning for compatibility.

### `shutdown.exe`, not `Stop-Computer`
`Stop-Computer` is unreliable in WinPE — it sometimes hangs on the
shutdown privilege check. `shutdown.exe /s /t 0` always works.

### DISM, not Apply-WindowsImage / Expand-WindowsImage
The PowerShell cmdlets wrap DISM but mask its progress output. We want
the user to see the apply progress inline. We shell out to
`dism.exe /apply-image` with `-NoNewWindow` so the progress indicator
renders in the calling console.

### Registry tweak at build time, not apply time
`NtfsEnableDirCaseSensitivity = 1` in the offline SYSTEM hive of
`boot.wim` applies once, permanently, and survives every deploy. Setting
it at apply time would require re-applying every boot and would lose
the fix on WinPE restart. Bake it in once; forget about it.

## Safety Model

The safety chain is **typed confirmations at every destructive step**.
`-Force` bypasses the final "ERASE" prompt. `-Silent` requires all
inputs up front. *Neither* ever bypasses the system-disk "DESTROY
SYSTEM" prompt — that requires the exact string typed by a human,
always. The rationale: any automation that has wandered into wiping
the host it's running on is by definition broken, and should halt.

## Failure Mode Philosophy

Fail loud and early:

- Admin check: fail before anything
- WinPE check: block non-WinPE unless explicitly overridden, because
  running on a production host is the most common way to cause harm
- `-Silent` contract: missing inputs exit immediately, not after
  auto-discovery finds something plausible
- Diskpart: verify S: and C: exist after "success", because exit 0
  lies
- DISM: `/CheckIntegrity` catches WIM corruption up front instead of
  mid-apply as "Incorrect function"
- Post-apply: verify `C:\Windows\System32` exists before bcdboot, so
  BCDBoot failure vs. no-Windows-on-disk are distinguishable

## File Layout

| File / Directory | Role |
|---|---|
| `unified_winpe_deploy.ps1` | The deploy script. Runs inside WinPE. |
| `scripts/prepare_wim.ps1` | WIM prep tool. ISO → debloated/customized install.wim (admin Windows workstation). |
| `scripts/build_boot_wim.ps1` | Build-time WinPE builder. Runs on Windows with ADK. |
| `scripts/validate_script.ps1` | Static analysis of deploy script. Runs in CI. |
| `tests/test_parse.ps1` | PowerShell syntax validation. Runs in CI. |
| `PSScriptAnalyzerSettings.psd1` | Shared PSSA rule config. Used locally and in CI. |
| `docs/USB_SETUP.md` | User-facing: how to prepare the boot USB. |
| `docs/SCRIPT_REFERENCE.md` | User-facing: parameters and functions. |
| `docs/TROUBLESHOOTING.md` | User-facing: failure modes, fixes, and known caveats. |
| `docs/ARCHITECTURE.md` | This file. Design rationale. |
| `docs/CCTK.md` | User-facing: Dell CCTK pre-apply BIOS configuration. |
| `docs/SIGNING.md` | User-facing: enterprise code-signing of the deploy script. |
| `.claude/MASTERIZE.md` | Internal: release-audit playbook (per-release, not per-session). |
| `CLAUDE.md` | Contributor-facing: project conventions and safety rules. |
| `CHANGELOG.md` | Release history (keepachangelog). |

## Non-Goals

Explicit non-goals, so future contributors don't waste time proposing
them:

- Network deployment (PXE, WDS, MDT, SCCM) — wrong tool
- BIOS / MBR boot — GPT / UEFI only
- GUI — TUI by design, runs on serial / remote consoles
- Multi-disk RAID / Storage Spaces setup — single target disk
- Secure-erase / DoD wipe — standard `diskpart clean` only

**Formerly listed as non-goals, now supported:**
- Driver injection — pre-bake into WIM via `prepare_wim.ps1 -DriverPath`
- Unattend.xml / first-boot orchestration — via `-UnattendFile`
- Domain join — via an answer file with `JoinDomain` in the `specialize` pass

If you want network deployment or full MDT orchestration, you want a different tool.
