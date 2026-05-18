# BIOS Configuration with CCTK (Dell fleets)

> [!IMPORTANT]
> **CCTK binaries are not redistributable.** Dell's EULA for Command |
> Configure does not permit third-party redistribution. Do **not**
> commit `cctk.exe`, the HAPI driver, or any CCTK DLL to this repo or
> a fork. Download Dell Command | Configure directly from Dell's
> support site onto your admin workstation and reference it by path
> when adding the MDT Application.
> `.gitignore` is set up to block `/vendor/`, `/cctk-source/`,
> `cctk.exe`, and `hapint*.inf/.sys` as a safety net.

The MDT deployment can optionally apply BIOS configuration via Dell's
[Client Configuration Toolkit (CCTK)](https://www.dell.com/support/kbdoc/en-us/000178000/dell-command-configure)
**before** the Windows image is applied. This targets new Dell hardware
that ships with RAID enabled in BIOS — DISM can see the disk, but
Windows won't boot post-apply without the RAID driver, so you want
AHCI, passwords, and boot order set once per machine during the same
run that deploys Windows.

## Why Pre-Apply (Not Post-Apply)

CCTK changes queue in BIOS and activate on the **next POST**. The
normal end-of-deploy reboot is that POST. So CCTK runs during the WinPE
session, the rest of the task sequence finishes with the current BIOS
state, the machine reboots, and Windows first-boots with the intended
BIOS already in place — one reboot, not two.

If CCTK fails (bad config, password mismatch, HAPI driver missing),
the task sequence aborts. When the step runs before "Format and Partition
Disk", no disks have been touched yet — safe to abort and retry.

## MDT Method (primary)

### 1. Create the CCTK Application in MDT

**Using MDT Workbench (GUI):**

1. Open Deployment Workbench and expand your deployment share.
2. Right-click **Applications** → **New Application**.
3. Choose **Application with source files**.
4. Set the source directory to your local Dell Command | Configure
   `X86_64` folder (contains `cctk.exe` and the HAPI subdirectory).
5. Set the command line to:
   ```
   cctk.exe --infile="%DEPLOYROOT%\Applications\Dell-CCTK\configs\default.ini"
   ```
6. Set the working directory to `.\Applications\Dell-CCTK\bin`.
7. Complete the wizard. MDT copies the source tree into the deployment share.

**Using PowerShell (scriptable):**

```powershell
Import-Module 'C:\Program Files\Microsoft Deployment Toolkit\bin\MicrosoftDeploymentToolkit.psd1'
New-PSDrive -Name 'DS001' -PSProvider MDTProvider -Root 'C:\MDTDeploymentShare' -Verbose:$false

Import-MDTApplication -Path 'DS001:\Applications' `
    -Name 'Dell CCTK - BIOS Configuration' `
    -ShortName 'Dell-CCTK' `
    -CommandLine 'cctk.exe --infile="%DEPLOYROOT%\Applications\Dell-CCTK\configs\default.ini"' `
    -WorkingDirectory '.\Applications\Dell-CCTK\bin' `
    -ApplicationSourcePath 'C:\Program Files (x86)\Dell\Command Configure\X86_64' `
    -DestinationFolder 'Dell-CCTK'
```

Adjust `-ApplicationSourcePath` if Command | Configure is installed elsewhere.

### 2. Add Config Files to the Deployment Share

Place your CCTK config files under the application's `configs\` folder
in the deployment share:

```
C:\MDTDeploymentShare\Applications\Dell-CCTK\configs\
├── default.ini       ← catch-all: all new Dell machines
├── OptiPlex7090.ini  ← per-model override
└── 1A2B3C4.ini       ← per-service-tag override
```

**Config selection precedence** (MDT task sequence picks the first match):

1. `%SerialNumber%.ini` — the machine's BIOS serial number (service tag)
2. `%Model%.ini` — MDT's `%Model%` variable, non-alphanumerics stripped
   (e.g. "OptiPlex 7090" → `OptiPlex7090`)
3. `default.ini`
4. None found → CCTK step is skipped, deploy continues

This lets one ISO serve a mixed fleet: most machines get `default.ini`,
specific models or specific service tags get overrides when needed.

**Using MDT variables for per-machine config selection:**

Add a "Run Command Line" step immediately before the CCTK application
step to select the right config file:

```
Name:    Set CCTK Config Path
Command: cmd.exe /c if exist "%DEPLOYROOT%\Applications\Dell-CCTK\configs\%SerialNumber%.ini" (set CCTKConfig=%SerialNumber%.ini) else if exist "%DEPLOYROOT%\Applications\Dell-CCTK\configs\%Model%.ini" (set CCTKConfig=%Model%.ini) else (set CCTKConfig=default.ini)
```

Then adjust the application command line to reference `%CCTKConfig%`:

```
cctk.exe --infile="%DEPLOYROOT%\Applications\Dell-CCTK\configs\%CCTKConfig%"
```

### 3. Order in the Task Sequence

In MDT Workbench task sequence editor, arrange the steps so the CCTK
application runs **before** "Format and Partition Disk":

```
State Restore
├── [Set CCTK Config Path]         ← Run Command Line (optional variable step)
├── Install Application: Dell-CCTK ← BIOS changes queued here
├── Format and Partition Disk      ← disk untouched if CCTK fails above
├── Apply Operating System Image
└── ...
```

If CCTK exits non-zero, MDT treats the application step as a failure and
the task sequence halts before touching any disk.

**Rebuild the media after adding the application** so the CCTK binaries
and configs are baked into the ISO:

```powershell
.\scripts\mdt\New-MDTMedia.ps1
```

## Config File Format

Plain CCTK INI. Example `default.ini` for a fresh Dell workstation:

```ini
; Switch from RAID to AHCI so Windows boots with stock drivers post-apply
--embsataraid=ahci

; Secure Boot on, UEFI only
--secureboot=enabled
--bootlist=uefi

; Passwords (see security section below)
--setuppwd=Setup123!
--syspwd=System123!

; Power / boot behavior
--numlock=on
--wakeonlan=lanonly
```

The task sequence invokes `cctk.exe --infile=<path>` and the application
step fails on any non-zero exit.

## Changing / Clearing Passwords

If the BIOS already has a setup or system password set, CCTK needs
the current one to authenticate:

```ini
--setuppwd=NewSetup123!
--valsetuppwd=OldSetup123!
--syspwd=NewSystem123!
--valsetuppwd=OldSetup123!
```

For **clearing** a password:

```ini
--setuppwd=
--valsetuppwd=CurrentSetup123!
```

## Security: Honest Accounting

Passwords live in plaintext inside the ISO and on the USB. There is
**no cryptographic protection available** for an unattended WinPE
flow — anything CCTK reads, someone with the USB or ISO can also read.
Your mitigations are:

- **Physical security of the USB and ISO** — primary control. Treat them
  like domain-admin credentials.
- **Unique setup password per machine** (service-tag configs) — limits
  blast radius if one USB walks off.
- **Rotate after deployment** — change setup/system passwords via
  CCTK or Windows provisioning after the machine is in service.
- **CCTK's `--setuppwdencrypted`** — Dell offers a per-machine-hashed
  encrypted format. Not useful for fleet ISOs (encryption is keyed to
  the host generating it), but worth knowing about for one-off
  provisioning.

If you need real runtime secrecy, the only options are typed prompts,
USB security keys, or network-fetched passwords. All of those break
the "boot, walk away" model.

## WinPE Tool Method (alternative)

For users of the direct WinPE USB tool (`unified_winpe_deploy.ps1`)
rather than the MDT ISO workflow, CCTK is embedded differently:

**Embed CCTK in boot.wim** — pass `-CctkSource` to
`scripts/build_boot_wim.ps1`. The builder copies `cctk.exe` and HAPI
into `X:\cctk\` inside `boot.wim` and installs the HAPI driver offline.

**Drop config files on the IMAGES partition** — create a `cctk\`
folder on the IMAGES data partition of the USB. The deploy script picks
configs in the same service-tag → model → default precedence described
above.

The config file format, password handling, and security trade-offs are
identical to the MDT method. See the git history or the pre-v4.6 docs
for a full walkthrough of the WinPE-only setup.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `CCTK returned exit 116` | HAPI driver not loaded | Ensure the `X86_64` source folder you imported includes the HAPI subdirectory; re-import the application if HAPI was missing |
| `CCTK returned exit 149` | Password mismatch | Add `--valsetuppwd=<current>` to the config |
| `No CCTK config matched` | None of `<TAG>.ini`/`<MODEL>.ini`/`default.ini` exist | Add a `default.ini` to `C:\MDTDeploymentShare\Applications\Dell-CCTK\configs\` and rebuild media |
| BIOS change didn't stick after reboot | Some settings (TPM clear, SATA-to-RAID direction) take two POSTs on certain firmware | Reboot manually a second time to confirm |
| `%DEPLOYROOT%` not resolving in command line | MDT variable not set at application step | Ensure the application step runs after MDT environment initialization — this is always true in a Standard Client task sequence |
| Application step skipped silently | Application not selected in task sequence | In Workbench, open the task sequence, find the "Install Application" step, and confirm Dell-CCTK is listed |
