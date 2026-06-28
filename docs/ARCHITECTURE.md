# Architecture

High-level design notes for `unified_winpe_deploy.ps1`,
`scripts/build_boot_wim.ps1`, and `scripts/prepare_wim.ps1` — the
three core programs. `scripts/refresh_usb.ps1` and
`scripts/build_iso.ps1` are workflow wrappers around their outputs
(re-build the USB after a new ISO drop; package WinPE + WIM into one
ISO for end-user Rufus burns respectively). `scripts/first-login.ps1`
runs on the deployed machine, not in WinPE — see "File Layout" below
for the full inventory. For parameter / function reference, see
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
        → BitLocker param validation (if -EnableBitLocker:
             ├── -BitLockerPin required, prompts at WinPE console in non-silent mode
             ├── -BitLockerPin enforced to 6-20 chars (Windows Enhanced PIN window)
             └── -BitLockerPin without -EnableBitLocker → warn (PIN ignored))
        → Silent-mode contract check (if -Silent: -WimFile/-TargetDisk/-Force,
             -WipeDisks format, -DataDiskNumber requires -Force)
        → -UnattendFile validation (path exists AND parses as XML)
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
             └── final confirm      → type ERASE (or DELETE ALL DATA)
        → -DataDiskNumber gate (if set)
             ├── must be real, non-USB, non-system, non-target
             └── type WIPE DATA (skipped by -Force)
        → TUI: optional additional-wipe disks
             ├── overlap with -DataDiskNumber → abort
             └── single WIPE ALL    → clean-only preamble in same diskpart session
        → Disk size vs image size validation (uncompressed when DISM exposes it)
        → Free C: / S: (and D: when -DataDiskNumber set) drive letters
             └── refuses to release the WIM source drive
        → diskpart: [extra disk cleans] + clean + GPT + EFI 300MB (S:) + MSR 16MB + NTFS (C:)
             └── + clean + GPT + NTFS (D:) when -DataDiskNumber set
        → Post-diskpart: verify S: and C: (and D:) exist
        → dism /apply-image /CheckIntegrity (inline progress)
        → Post-deploy: verify C:\Windows\System32 exists
        → Unattend staging (if -UnattendFile): copy to C:\Windows\Panther\unattend.xml
        → BitLocker staging (if -EnableBitLocker):
             ├── write bitlocker-setup.ps1 + SetupComplete.cmd to C:\Windows\Setup\Scripts\
             └── first boot enables TPM+PIN on C: (and recovery-key + auto-unlock on D:)
        → bcdboot C:\Windows /s S: /f UEFI
        → Optional shutdown prompt → final reboot activates queued CCTK BIOS
             ├── Windows Setup reads unattend.xml on first boot (OOBE, domain join, etc.)
             └── SetupComplete.cmd runs bitlocker-setup.ps1 after OOBE
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

The safety chain is **typed confirmations at every destructive step**:

| Trigger | Typed string | Bypassed by `-Force`? |
|---------|--------------|-----------------------|
| Final target-disk wipe | `ERASE` (or `DELETE ALL DATA`) | Yes |
| Target disk is the system disk | `DESTROY SYSTEM` | **No, never** |
| Additional disks (`-WipeDisks` / interactive picker) | `WIPE ALL` | Yes |
| Data-disk format (`-DataDiskNumber`) | `WIPE DATA` | Yes |
| Run outside WinPE | `CONTINUE ANYWAY` | No (refused in `-Silent`) |

`-Silent` requires all inputs up front and *never* bypasses the
system-disk `DESTROY SYSTEM` prompt — that requires the exact string
typed by a human, always. The rationale: any automation that has
wandered into wiping the host it's running on is by definition broken,
and should halt. `-Silent` combined with `-DataDiskNumber` requires
`-Force` for the same reason in reverse — the `WIPE DATA` prompt
cannot run unattended, so silent + data-disk has to be explicit twice.

## Failure Mode Philosophy

Fail loud and early:

- Admin check: fail before anything
- WinPE check: block non-WinPE unless explicitly overridden, because
  running on a production host is the most common way to cause harm
- `-Silent` contract: missing inputs exit immediately, not after
  auto-discovery finds something plausible
- BitLocker param pre-flight: missing PIN, out-of-range PIN, or PIN
  without `-EnableBitLocker` surface before any disk is touched —
  catching this at first boot would mean a successfully-wiped disk
  with broken encryption
- `-UnattendFile` pre-flight: file must exist *and* parse as XML
  (Windows Setup silently ignores a malformed answer file and falls
  through to manual OOBE; catching it here saves a wipe + redeploy)
- CCTK pre-apply: non-zero exit aborts before partitioning, because a
  half-configured BIOS is worse than failing loud
- Diskpart: verify S:, C:, and D: (when staged) exist after "success",
  because exit 0 lies
- DISM: `/CheckIntegrity` catches WIM corruption up front instead of
  mid-apply as "Incorrect function"; recovery guidance is per-known
  exit code (1, 2, 11, 50, 87, 112, 1168, 1392)
- Post-apply: verify `C:\Windows\System32` exists before bcdboot, so
  BCDBoot failure vs. no-Windows-on-disk are distinguishable
- BCDBoot: on non-zero exit, surface `bcdboot`'s own stderr plus a
  diagnostics block (`bootmgfw.efi` presence, `S:` mount state, free
  space) instead of just the numeric exit code

## File Layout

| File / Directory | Role |
|---|---|
| `unified_winpe_deploy.ps1` | The deploy script. Runs inside WinPE. |
| `scripts/prepare_wim.ps1` | WIM prep tool. ISO → debloated/customized install.wim (admin Windows workstation). |
| `scripts/build_boot_wim.ps1` | Build-time WinPE builder. Runs on Windows with ADK. |
| `scripts/build_iso.ps1` | Packages WinPE media + WIM into one bootable ISO for end-user Rufus burns. |
| `scripts/refresh_usb.ps1` | Workflow wrapper: new ISO → prep + (optional) boot rebuild. |
| `scripts/first-login.ps1` | Per-user HKCU debloat + UX tweaks staged into the image by `prepare_wim.ps1 -DisableExtraBloat`; runs on the deployed machine, not in WinPE. |
| `tests/test_parse.ps1` | PowerShell syntax validation for every shipped pipeline script. Runs in CI. |
| `tests/test_wim_parser.ps1` | Fixture test for the DISM `/Get-WimInfo` regex parser used by `Get-WimImageInfo`. Runs in CI. |
| `tests/test_disk_enumeration.ps1` | Fixture test for `Get-SystemDisks` disk-filter + partition rendering (Linux/LVM-as-empty regression guard). Runs in CI. |
| `tests/validation-gates.Tests.ps1` | Pester v5 suite covering BitLocker/data-disk defaults, escrow precedence, `New-DiskpartScript` source-drive protection, and `Start-Deployment` validation gates. CI-only (PSGallery network access required to install Pester). |
| `PSScriptAnalyzerSettings.psd1` | Shared PSSA rule config. Used locally and in CI. |
| `configs/deploy.args.example` | Template for the per-USB `deploy.args` file consumed by `startnet.cmd`. |
| `docs/USB_SETUP.md` | User-facing: how to prepare the boot USB. |
| `docs/END_USER_DEPLOY.md` | User-facing: Rufus-based single-ISO workflow for non-IT recipients. |
| `docs/SCRIPT_REFERENCE.md` | User-facing: parameters and functions. |
| `docs/TROUBLESHOOTING.md` | User-facing: failure modes, fixes, and known caveats. |
| `docs/ARCHITECTURE.md` | This file. Design rationale. |
| `docs/CCTK.md` | User-facing: Dell CCTK pre-apply BIOS configuration. |
| `docs/BITLOCKER.md` | User-facing: opt-in BitLocker + data-disk staging. |
| `docs/DEPLOY_ARGS.md` | User-facing: per-USB `deploy.args` file format and `startnet.cmd` integration. |
| `docs/UNATTEND.md` | User-facing: `-UnattendFile` integration and answer-file authoring tips. |
| `docs/RELEASE_VALIDATION.md` | Manual hardware-validation checklist run before tagging. |
| `docs/SIGNING.md` | User-facing: enterprise code-signing of the deploy script. |
| `docs/claude-routine-log.md` | Maintenance log written by the autonomous routine agent. |
| `.claude/MASTERIZE.md` | Internal: release-audit playbook (per-release, not per-session). |
| `CLAUDE.md` | Contributor-facing: project conventions and safety rules. |
| `AGENTS.md` | Portable pointer to `CLAUDE.md` for agents that don't read it by name. |
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
- BitLocker / data-disk staging — opt-in via `-EnableBitLocker` and
  `-DataDiskNumber` (off by default; see [`BITLOCKER.md`](BITLOCKER.md))
- Dell BIOS pre-apply — embed `cctk.exe` via the builder and ship
  per-machine `.ini` configs on the IMAGES partition (see
  [`CCTK.md`](CCTK.md))

If you want network deployment or full MDT orchestration, you want a different tool.
