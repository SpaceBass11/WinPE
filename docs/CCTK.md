# BIOS Configuration with CCTK (Dell fleets)

> [!IMPORTANT]
> **CCTK binaries are not redistributable.** Dell's EULA for Command |
> Configure does not permit third-party redistribution. Do **not**
> commit `cctk.exe` or any DCC DLL to this repo or a fork. Download
> Dell Command | Configure directly from Dell's support site onto your
> admin workstation and reference it by path via `-CctkSource` when
> running `scripts/build_boot_wim.ps1`. `.gitignore` is set up to block
> `/vendor/`, `/cctk-source/`, `cctk.exe`, and `hapint*.inf/.sys` as a
> safety net.

The deploy tool can optionally apply BIOS configuration via Dell's
[Client Configuration Toolkit (CCTK)](https://www.dell.com/support/kbdoc/en-us/000178000/dell-command-configure)
**before** the Windows image is applied. This is aimed at new Dell
hardware that ships with RAID enabled in BIOS (DISM can see the disk,
but Windows won't boot post-apply without the RAID driver) — you want
AHCI, passwords, boot order, etc. set once per machine during the same
run that deploys Windows.

## Why Pre-Apply (Not Post-Apply)

CCTK changes queue in BIOS and activate on the **next POST**. The
normal end-of-deploy reboot is that POST. So we apply CCTK during the
WinPE session, finish the DISM + BCDBoot work with the current BIOS
state, reboot, and Windows first-boots with the intended BIOS already
in place — one reboot, not two.

If CCTK fails (bad config, password mismatch, BIOS access error),
the deploy aborts before any disks are touched.

## Setup

### 1. Embed CCTK in boot.wim

Download Dell Command | Configure, extract the installer (or point
at an already-installed copy — usually `C:\Program Files (x86)\Dell\Command Configure\`).
Pass the path to the builder:

```powershell
.\scripts\build_boot_wim.ps1 -Clean -UsbDrive P: -ReleaseUsbLetter `
    -CctkSource 'C:\Program Files (x86)\Dell\Command Configure\X86_64'
```

The builder validates that the DCH API DLLs (`dchapi64.dll`, `dchbas64.dll`,
`BIOSIntf.dll`) are present alongside `cctk.exe`, then copies the DCC tree
to `X:\cctk\` inside `boot.wim`. No driver injection required — DCC 4.0+
communicates with the BIOS entirely through those userspace DLLs.

CCTK binaries live **inside** boot.wim so they aren't visible on the
IMAGES data partition. CCTK is not redistributable — you provide it.

### 2. Drop Config Files on the IMAGES Partition

Create a `cctk\` folder on the IMAGES partition of your USB:

```
P:\  (WinPE boot, hidden)
I:\  (IMAGES data partition)
├── images\
│   └── Win11_Pro_24H2.wim
└── cctk\
    ├── default.ini          # catch-all: "new Dell out of box"
    ├── OptiPlex7090.ini     # per-model override
    └── 1A2B3C4.ini          # per-machine override (service tag)
```

### 3. Config Selection Precedence

The deploy script picks **one** config, in this order:

1. `<SERVICETAG>.ini` — reads `Win32_BIOS.SerialNumber`
2. `<MODEL>.ini` — reads `Win32_ComputerSystem.Model`, strips non-alnum
   (so "OptiPlex 7090" becomes `OptiPlex7090.ini`)
3. `default.ini`
4. None found → skip CCTK, continue to deploy

This means you can ship one USB across a mixed fleet: most machines
get `default.ini`, specific models or specific service tags get
overrides when needed.

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

The deploy script invokes `cctk.exe --infile=<path>` and aborts the
deploy on any non-zero exit.

### Changing Existing Passwords

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

Passwords live in plaintext on the IMAGES data partition. There is
**no cryptographic protection available** for an unattended WinPE
flow — anything CCTK reads, someone with the USB can also read. Your
mitigations are:

- **Physical security of the USB** — primary control. Treat it like a
  domain-admin credential.
- **Unique setup password per machine** (service-tag configs) — limits
  blast radius if one USB walks off.
- **Rotate after deployment** — change setup/system passwords via
  CCTK or Windows provisioning after the machine is in service.
- **CCTK's `--setuppwdencrypted`** — Dell offers a per-machine-hashed
  encrypted format. Not useful for fleet USBs (encryption is keyed to
  the host generating it), but worth knowing about for one-off
  provisioning.

If you need real runtime secrecy, the only options are typed prompts,
USB security keys, or network-fetched passwords. All of those break
the "plug in USB, boot, walk away" model.

## Operational Notes

- **No auto-reboot between CCTK and DISM.** The apply runs, then the
  existing deploy flow continues. The final end-of-deploy reboot
  activates both the BIOS change and first-boots the new Windows.
- **Idempotent re-apply.** Re-running the same config is safe for
  most settings. Password changes need `--valsetuppwd=<current>`
  once a password is set.
- **Windows auto-detects the new storage mode** at first boot (PnP
  loads stock AHCI/NVMe drivers). No driver injection needed.
- **Service-tag lookup** uses `Win32_BIOS.SerialNumber`, which is the
  same tag Dell prints on the chassis. Confirm with `wmic bios get
  serialnumber` on a reference machine.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `CCTK returned exit 116` | BIOS communication error | Verify DCC version is 4.0 or later and that `-CctkSource` points at the full `X86_64` directory (must contain `dchapi64.dll`, `dchbas64.dll`, `BIOSIntf.dll`). The builder now aborts if these DLLs are absent, so a deployed boot.wim should have them — if CCTK still fails, the DCC version or firmware may be incompatible. On pre-4.0 DCC, exit 116 indicated a missing HAPI kernel driver — see [Legacy DCC (Pre-4.0 / HAPI Era)](#legacy-dcc-pre-40--hapi-era) below. |
| `CCTK returned exit 149` | Password mismatch | Add `--valsetuppwd=<current>` to the config |
| `No CCTK config matched` | None of `<TAG>.ini`/`<MODEL>.ini`/`default.ini` exist | Drop a `default.ini` on the IMAGES partition under `cctk\` |
| `CCTK embedded but DEPLOY_IMAGE_DRIVE is unset` | Script ran outside builder's startnet.cmd | Set `$env:DEPLOY_IMAGE_DRIVE` manually before running, or rebuild boot.wim so startnet probes for the IMAGES label |
| BIOS change didn't stick after reboot | Some settings (TPM clear, SATA-to-RAID direction) take two POSTs on certain firmware | Reboot manually a second time to confirm |

## Legacy DCC (Pre-4.0 / HAPI Era)

Dell Command | Configure **4.0 and later** no longer uses HAPI. If you encounter older
documentation, forum posts, or scripts that mention loading a HAPI driver before running
`cctk.exe` in WinPE, those instructions apply to **pre-4.0 DCC only**.

**Pre-4.0 DCC is not supported.** Download Dell Command | Configure 4.0 or later
from Dell's support site.

For historical context: pre-4.0 DCC used HAPI (`hapint*.inf` / `hapint.sys`), a
kernel-mode driver that had to be injected into the WinPE boot.wim offline via
`dism /Add-Driver` before `cctk.exe` could talk to the BIOS. DCC 4.0 replaced
HAPI with a userspace DCH API stack (`dchapi64.dll`, `dchbas64.dll`, `BIOSIntf.dll`,
`ABI.dll`) — ordinary DLLs that ship alongside `cctk.exe`. No kernel driver needed.
