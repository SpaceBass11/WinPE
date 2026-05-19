# BIOS Configuration with CCTK (Dell fleets)

> [!IMPORTANT]
> **CCTK binaries are not redistributable.** Dell's EULA for Command |
> Configure does not permit third-party redistribution. Do **not**
> commit `cctk.exe`, the HAPI driver, or any CCTK DLL to this repo or
> a fork. Download Dell Command | Configure directly from Dell's
> support site onto your admin workstation and copy the binaries into
> the deployment share locally.
> `.gitignore` blocks `/vendor/`, `/cctk-source/`, `cctk.exe`, and
> `hapint*.inf/.sys` as a safety net.

CCTK is a one-shot CLI tool, not installed software. The right pattern in MDT
is to drop the binaries in the deployment share's `Tools\` folder and call
them from a **Run Command Line** task sequence step. **Do not** import CCTK
as an MDT Application -- Applications are for software that gets installed
and tracked on the client. CCTK just runs once to flip BIOS settings.

CCTK runs in **State Restore** -- inside the newly deployed Windows
environment, after OS apply. BIOS changes queue in firmware and take effect
on the reboot at the end of deployment.

## Timing

CCTK changes activate on the **next POST**, not immediately. The flow is:

1. Windows is deployed normally
2. State Restore runs in the new Windows environment
3. CCTK runs, writes BIOS settings -- they queue, not applied yet
4. Task sequence finishes, machine reboots
5. BIOS settings take effect on that POST -- one reboot, done

**RAID → AHCI:** If the target machine ships with RAID mode enabled, DISM
will apply the image but Windows won't boot without the RAID driver. This
must be fixed **manually in BIOS before starting deployment** -- flip to
AHCI, then run the USB. CCTK cannot fix this in-band because the disk mode
needs to change before the OS is applied.

## Setup

### 1. Get the CCTK binaries

Install Dell Command | Configure on your admin workstation (not on target
machines -- you only need the binaries locally). Download from
[Dell support](https://www.dell.com/support/kbdoc/en-us/000178000/dell-command-configure)
and run the installer.

After install, the binaries live at:

```
C:\Program Files (x86)\Dell\Command Configure\X86_64\
```

This folder contains `cctk.exe` and the HAPI driver subdirectory.

### 2. Copy CCTK into the deployment share

Copy the entire `X86_64\` contents into the deployment share under `Tools\`:

```
C:\MDTDeploymentShare\Tools\Dell-CCTK\
├── cctk.exe
├── HAPI\
│   ├── ...
├── configs\
│   ├── default.ini
│   ├── OptiPlex7090.ini    (optional, per-model override)
│   └── 1A2B3C4.ini         (optional, per-service-tag override)
└── (other files from X86_64)
```

`Tools\` is part of every MDT deployment share by default and gets baked
into the media automatically -- no Application import needed. Files in
`Tools\` are accessible at deploy time via `%DEPLOYROOT%\Tools\...`.

### 3. Add config files

Place your CCTK config files under `Tools\Dell-CCTK\configs\` (see structure
above). Config selection precedence:

1. `%SerialNumber%.ini` — the machine's BIOS serial number (service tag)
2. `%Model%.ini` — MDT's `%Model%` variable, non-alphanumerics stripped
   (e.g. "OptiPlex 7090" → `OptiPlex7090`)
3. `default.ini`
4. None found → CCTK step is skipped, deploy continues

This is implemented by a `cmd.exe` if/else step in the task sequence (next
section). One ISO can serve a mixed fleet -- most machines get
`default.ini`, specific models or service tags get overrides when needed.

### 4. Add Run Command Line steps to the task sequence

In Deployment Workbench, open the task sequence editor:
**Task Sequences** > right-click your task sequence > **Properties** >
**Task Sequence** tab.

In **State Restore** > **Custom Tasks** (or any position after Tattoo),
add two Run Command Line steps:

**Step 1 -- Select CCTK config**

| Field | Value |
|-------|-------|
| Name | Select CCTK Config |
| Command line | `cmd.exe /c if exist "%DEPLOYROOT%\Tools\Dell-CCTK\configs\%SerialNumber%.ini" (set CCTKConfig=%SerialNumber%.ini) else if exist "%DEPLOYROOT%\Tools\Dell-CCTK\configs\%Model%.ini" (set CCTKConfig=%Model%.ini) else (set CCTKConfig=default.ini)` |

**Step 2 -- Run CCTK**

| Field | Value |
|-------|-------|
| Name | Apply CCTK BIOS config |
| Command line | `"%DEPLOYROOT%\Tools\Dell-CCTK\cctk.exe" --infile="%DEPLOYROOT%\Tools\Dell-CCTK\configs\%CCTKConfig%"` |
| Start in | `%DEPLOYROOT%\Tools\Dell-CCTK` |

If CCTK exits non-zero, MDT treats the step as a failure and halts the
task sequence -- desired behavior so a misconfigured BIOS attempt does
not silently continue.

### 5. Rebuild the media

After adding the binaries and steps, right-click your deployment share >
**Update Deployment Share**, then right-click **MEDIA001** > **Update Media
Content** to bake everything into a fresh ISO.

## Exporting a Config from a Reference Machine

To capture a known-good BIOS state from a reference Dell:

```
cctk.exe --export=C:\temp\MB18250.ini
```

That produces a complete dump of current BIOS settings. **Trim the file
before using it as a deployment config** -- a full export includes
machine-specific values (asset tag, service tag, etc.) you don't want
to enforce across the fleet.

## Config File Format

Plain CCTK INI. Example `default.ini` for a fresh Dell workstation:

```ini
; Secure Boot on, UEFI only
--secureboot=enabled
--bootlist=uefi

; TPM on
--tpm=on
--tpmactivation=activate

; Passwords (see security section below)
--setuppwd=Setup123!
--syspwd=System123!

; Power / boot behavior
--numlock=on
--wakeonlan=lanonly
```

The task sequence invokes `cctk.exe --infile=<path>` and the step fails
on any non-zero exit.

## Changing / Clearing Passwords

If the BIOS already has a setup or system password set, CCTK needs
the current one to authenticate:

```ini
--setuppwd=NewSetup123!
--valsetuppwd=OldSetup123!
```

For **clearing** a password:

```ini
--setuppwd=
--valsetuppwd=CurrentSetup123!
```

## Security: Honest Accounting

Passwords live in plaintext inside the ISO and on the USB. There is
**no cryptographic protection available** for an unattended deployment
flow -- anything CCTK reads, someone with the USB or ISO can also read.
Your mitigations are:

- **Physical security of the USB and ISO** -- primary control. Treat them
  like domain-admin credentials.
- **Unique setup password per machine** (service-tag configs) -- limits
  blast radius if one USB walks off.
- **Rotate after deployment** -- change setup/system passwords via
  CCTK or Windows provisioning after the machine is in service.
- **CCTK's `--setuppwdencrypted`** -- Dell offers a per-machine-hashed
  encrypted format. Not useful for fleet ISOs (encryption is keyed to
  the host generating it), but worth knowing about for one-off
  provisioning.

If you need real runtime secrecy, the only options are typed prompts,
USB security keys, or network-fetched passwords. All of those break
the "boot, walk away" model.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `CCTK returned exit 116` | HAPI driver not loaded | Verify the `HAPI\` subfolder was copied into `Tools\Dell-CCTK\` alongside `cctk.exe` |
| `CCTK returned exit 149` | Password mismatch | Add `--valsetuppwd=<current>` to the config |
| `No CCTK config matched` | None of `<TAG>.ini`/`<MODEL>.ini`/`default.ini` exist | Add a `default.ini` to `Tools\Dell-CCTK\configs\` and rebuild media |
| BIOS change didn't stick after reboot | Some settings (TPM clear, SATA-to-RAID direction) take two POSTs on certain firmware | Reboot manually a second time to confirm |
| `%DEPLOYROOT%` not resolving | Step running outside MDT environment | Confirm step is inside State Restore, not before Gather |
| CCTK step silently skipped | Config selection step set `%CCTKConfig%` to empty | Check the cmd.exe if/else step output in BDD.log; verify config files exist at expected paths |
