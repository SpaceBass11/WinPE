# BIOS Configuration with CCTK (Dell fleets)

> [!IMPORTANT]
> **CCTK binaries are not redistributable.** Dell's EULA for Command |
> Configure does not permit third-party redistribution. Do **not**
> commit `cctk.exe`, the HAPI driver, or any CCTK DLL to this repo or
> a fork. Download Dell Command | Configure directly from Dell's
> support site and install it into the **gold image** during the
> admin build phase. The deployed machine inherits the install through
> the Clonezilla capture.

CCTK is a one-shot CLI tool that flips BIOS settings via WMI-ACPI (or
HAPI on legacy versions). In this workflow it runs once per deployed
machine inside `SetupComplete.cmd`, post-OOBE, via
[`ManualClonezilla/Scripts/Apply-DellConfig.ps1`](../ManualClonezilla/Scripts/Apply-DellConfig.ps1).

## Timing

The flow on the deployed machine is:

1. Clonezilla restores the golden image to the disk.
2. Windows reboots into specialize + OOBE (which is silent because of
   `unattend.xml`).
3. `C:\Windows\Setup\Scripts\SetupComplete.cmd` runs at end of OOBE.
4. `Apply-DellConfig.ps1` runs `cctk.exe --import=<dell-config.cctk>`.
5. CCTK writes BIOS settings to NVRAM.
6. SetupComplete finishes, machine reboots.
7. Most settings take effect on that POST -- one reboot.

**Two-POST settings:** Some changes (TPM clear, SATA mode flips,
virtualization toggles) require **two POSTs** on certain firmware to
fully apply. If a setting doesn't stick after the first reboot, reboot
once more to confirm before troubleshooting further.

**RAID -> AHCI:** If the target machine ships with RAID mode enabled,
**Clonezilla won't see the disk** -- restore fails before any of this
runs. Operator SOP must include "if Clonezilla reports no disk, switch
BIOS SATA mode to AHCI and retry." See
[`docs/USB_SETUP.md`](USB_SETUP.md). CCTK cannot fix this in-band; the
disk mode must change before Clonezilla restores.

## Setup (admin, on the gold reference machine)

### 1. Install Dell Command | Configure into the gold image

On the reference machine (before sysprep), install Dell Command |
Configure. Download from
[Dell support](https://www.dell.com/support/kbdoc/en-us/000178000/dell-command-configure)
and run the installer. After install, `cctk.exe` lives at:

```
C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe
```

`Apply-DellConfig.ps1` hard-codes this path and hard-fails if missing.

> **HAPI is legacy.** DCC 4.0 and later (your DCC 5.x install) no
> longer uses HAPI -- it talks to BIOS via WMI-ACPI. The HAPI
> subdirectory may or may not be present depending on version.
> Inconsequential.

### 2. Generate a BIOS config package

On a reference Dell, set BIOS to your desired state by hand (or with
CCTK), then export:

```cmd
cctk.exe --export="C:\temp\dell-config.cctk"
```

`--export` produces an opaque binary `.cctk` file (a packaged config
suitable for `--import`). The plaintext `.ini` form from older docs
still works for `--import` but `.cctk` is the recommended exchange
format.

**Trim the export before using as a deployment config.** A full
`--export` includes machine-specific values (asset tag, service tag,
ownership tag) you don't want forced across the fleet. Re-export after
manually clearing those fields on the reference, or open the file via
DCC's GUI and re-save to drop the per-machine bits.

### 3. Stage the config

Copy the trimmed config to the gold image at:

```
C:\ProgramData\ManualClonezilla\Config\dell-config.cctk
```

`Apply-DellConfig.ps1` hard-codes this path. If the file is missing on
a deployed machine, the script throws and `SetupComplete` halts (this
is intentional -- silent BIOS misconfig is worse than a loud failure).

## Cross-model compatibility

A single `.cctk` package may not apply cleanly across Dell families
(Latitude vs OptiPlex vs Precision) because available BIOS tokens
differ by platform and generation. Options:

- **Single homogeneous fleet:** one image, one config, one ISO.
  (This is the workflow's primary use case.)
- **Multiple families:** cut separate images per family. Each image
  carries the matching `dell-config.cctk` for that hardware.
- **Mixed-family single image (advanced):** modify
  `Apply-DellConfig.ps1` to detect model via `wmic computersystem get
  model` and pick a model-scoped `.cctk` file. Out of scope for the
  shipped script.

## Idempotency

`Apply-DellConfig.ps1` hashes `dell-config.cctk` and stores the SHA256
at `C:\ProgramData\ManualClonezilla\State\dell-config.applied.sha256`
after a successful import. Re-runs (e.g. operator manually re-runs
`SetupComplete.cmd`) compare the current file's hash against the
marker and skip if unchanged. Replacing the `.cctk` file with a new
version on an already-deployed machine and re-running picks up the
change.

## Cleanup

After successful import, `Finalize-Cleanup.ps1` deletes
`dell-config.cctk` from the deployed machine. The SHA256 marker stays
in `State\` for forensic purposes. The deployed endpoint therefore
does not carry the BIOS config package post-OOBE.

## Security: honest accounting

BIOS passwords (`--setuppwd`, `--syspwd`) embedded in the `.cctk` file
are accessible to anyone with read access to the ISO. This workflow's
trust model is "the ISO is sensitive media; the deployed machine is
not." See the [BitLocker PIN trust model](../README.md#bitlocker-pin-trust-model)
in the README for the same accepted-risk framing.

Mitigations:
- **Physical security of the USB and ISO.** Primary control.
- **Rotate setup/system passwords post-deployment** if your environment
  requires unique passwords per machine.
- **Don't push the ISO to public storage.** Internal SMB share with
  ACL, password-protected file drop, or hand-delivery only.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Apply-DellConfig.log` shows exit 116 | New password supplied without the current one | Re-export with `--valsetuppwd=<current>` in the source config |
| `Apply-DellConfig.log` shows exit 149 | TPM clear requires setup password | Pre-set setup password in BIOS, or add `--valsetuppwd=<current>` |
| `Apply-DellConfig.log` shows exit 117 | HAPI driver load failure (legacy DCC) | Reinstall DCC 5.x into the gold image; recapture |
| `Missing config package: ...dell-config.cctk` | Config not staged before sysprep | Re-stage at `C:\ProgramData\ManualClonezilla\Config\dell-config.cctk`, recapture, regenerate ISO |
| `Missing Dell Command Configure executable: ...cctk.exe` | DCC not installed in the gold image | Install DCC on the reference machine before sysprep, recapture |
| BIOS change didn't stick after reboot | Two-POST setting (TPM clear, SATA flip) | Manual second reboot to confirm |
| `Apply-DellConfig` silently re-skipped on re-run | SHA256 marker present and matches | Delete `State\dell-config.applied.sha256` to force re-import |
