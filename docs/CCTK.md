# Dell BIOS Configuration with CCTK

> [!IMPORTANT]
> **CCTK is Dell-only.** Skip this entire document if your fleet isn't
> Dell hardware.
>
> **CCTK binaries are not redistributable.** Dell's EULA for Command |
> Configure does not allow third-party distribution. Do **not** commit
> `cctk.exe`, the HAPI driver, or any CCTK DLL to this repo or a fork.
> Download Dell Command | Configure directly from Dell's support site.
> `.gitignore` blocks `cctk.exe` and `hapint*` as a safety net.

This procedure applies BIOS settings (RAID→AHCI, Secure Boot, passwords,
boot order, etc.) to a Dell machine **before** Windows is deployed onto
it. Useful for fleets where new hardware ships with RAID enabled in BIOS
— Windows can be installed but won't boot afterward without the RAID
driver, so you want AHCI set during the same WinPE session that installs
Windows.

---

## Why Pre-Apply Instead of Post-Install

CCTK queues BIOS changes; they take effect on the **next POST**. The
end-of-deploy reboot in [README.md step 10](../README.md#10-reboot) is
that POST. So we apply CCTK at the start of the WinPE session, do the
DISM + bcdboot work with the current BIOS state, reboot, and Windows
first-boots with the intended BIOS already in place. One reboot, not
two.

If CCTK fails (bad config, password mismatch, HAPI driver missing),
stop and fix it before touching disks.

---

## One-Time Setup: Embed CCTK in boot.wim

You'll do this once when building the USB (or re-do it after a CCTK
version bump). All steps run on your **admin workstation**, not in WinPE.

### 1. Get Dell Command | Configure

Download from Dell:
[https://www.dell.com/support/kbdoc/en-us/000178000](https://www.dell.com/support/kbdoc/en-us/000178000)

Install it on your admin workstation. The files you need end up at:

```
C:\Program Files (x86)\Dell\Command Configure\X86_64\
```

That folder contains `cctk.exe` and a `HAPI\` subfolder with the HAPI
driver `.inf`/`.sys` files.

### 2. Mount boot.wim

Open **Deployment and Imaging Tools Environment** as Administrator.
Assuming you followed [USB_SETUP.md](USB_SETUP.md), boot.wim is at
`C:\WinPE_Build\media\sources\boot.wim`.

```
dism /Mount-Image /ImageFile:C:\WinPE_Build\media\sources\boot.wim /Index:1 /MountDir:C:\WinPE_Build\mount
```

### 3. Copy CCTK files into the mounted image

```
mkdir C:\WinPE_Build\mount\cctk
xcopy /s /e /y "C:\Program Files (x86)\Dell\Command Configure\X86_64\*" C:\WinPE_Build\mount\cctk\
```

After this, `X:\cctk\cctk.exe` will exist when the USB boots.

### 4. Install the HAPI driver into the offline image

Find the right HAPI inf (the 64-bit one is usually
`HAPI\hapint64.inf` — check what your CCTK ships):

```
dir C:\WinPE_Build\mount\cctk\HAPI\*.inf
```

Add it as a driver to the offline image:

```
dism /Image:C:\WinPE_Build\mount /Add-Driver /Driver:C:\WinPE_Build\mount\cctk\HAPI\hapint64.inf
```

Without this step, `cctk.exe` will return exit code **116** ("HAPI
driver load error") at runtime.

### 5. Unmount and commit

```
dism /Unmount-Image /MountDir:C:\WinPE_Build\mount /Commit
```

### 6. Re-xcopy media to the USB

The boot.wim on the USB still has the old content. Re-do
[USB_SETUP step 5](USB_SETUP.md#step-5--copy-winpe-to-the-usb):

```
xcopy /s /e /y C:\WinPE_Build\media\*.* P:\
```

CCTK is now embedded **inside** `boot.wim`. It isn't visible from the
IMAGES partition — that's intentional, since CCTK isn't redistributable
and shouldn't sit on a partition that someone could clone.

---

## Per-Machine Setup: Drop Configs on IMAGES

Create a `cctk\` folder on the IMAGES partition of the USB:

```
mkdir I:\cctk
```

Put your `.ini` config files there. The simplest case is one file:

```
I:\cctk\default.ini      <- applied to every machine that hits this USB
```

You can also add machine-specific overrides:

```
I:\cctk\
+-- default.ini          (catch-all)
+-- OptiPlex7090.ini     (per-model override)
`-- 1A2B3C4.ini          (per-service-tag override)
```

### Picking the right config at deploy time

At [README.md step 3](../README.md#3-dell-only-apply-bios-config),
you choose which config to apply. The simplest workflow is: always
use `default.ini`. If you have overrides, look up the machine first:

```
wmic bios get serialnumber          (the service tag printed on the chassis)
wmic computersystem get model       (the model name)
```

Then run CCTK with whichever config matches, in this order of preference:

1. `<SERVICETAG>.ini` if it exists
2. `<MODEL>.ini` if it exists (strip spaces from model name —
   "OptiPlex 7090" becomes `OptiPlex7090.ini`)
3. `default.ini`

Example:

```
X:\cctk\cctk.exe --infile=I:\cctk\OptiPlex7090.ini
```

If exit code is **0**, you're good. Anything else, see
[Troubleshooting](#troubleshooting) below.

---

## Config File Format

Plain CCTK INI — one option per line. Each line is an argument that
would otherwise be passed on the cctk command line.

Example `default.ini` for a fresh Dell workstation that ships with
RAID enabled:

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

### Changing an existing password

If the BIOS already has a setup or system password, CCTK needs the
current one to authenticate:

```ini
--setuppwd=NewSetup123!
--valsetuppwd=OldSetup123!

--syspwd=NewSystem123!
--valsetuppwd=OldSetup123!
```

### Clearing a password

```ini
--setuppwd=
--valsetuppwd=CurrentSetup123!
```

---

## Security: Honest Accounting

Passwords live in plaintext on the IMAGES partition. There is **no
cryptographic protection available** for an unattended WinPE flow —
anything CCTK can read, anyone with the USB can also read.

Mitigations:

- **Physical security of the USB.** Treat it like a domain-admin
  credential. Lock it in a drawer, don't leave it on a desk.
- **Unique setup password per machine** using service-tag-named configs
  — limits the blast radius if one USB walks off.
- **Rotate after deployment.** Change setup/system passwords via CCTK
  (or Group Policy / a Windows tool) once the machine is in service.

There is no path to runtime secrecy without breaking the "plug in,
walk away" model. If you need real secrecy, you need typed prompts or
network-fetched passwords — both out of scope for this tool.

---

## Troubleshooting

| Exit code | Meaning                         | Fix                                                                                  |
|-----------|---------------------------------|--------------------------------------------------------------------------------------|
| 0         | Success                         | —                                                                                    |
| 116       | HAPI driver not loaded          | Re-do setup step 4 (install the HAPI inf into the offline image), re-xcopy to USB.   |
| 149       | Setup password mismatch         | Add `--valsetuppwd=<current>` to the .ini.                                          |
| 197       | Setting not supported on model  | Run `X:\cctk\cctk.exe --help` against the actual hardware. Some settings are model-specific. |

**BIOS change didn't stick after reboot:** Some settings (TPM clear,
SATA-to-RAID direction) take two POSTs on certain firmware. Reboot the
machine a second time to confirm.

**Service tag / model lookup returns the wrong thing:** `wmic bios get
serialnumber` returns the same tag Dell prints on the chassis. If you
see a placeholder string like `To Be Filled By O.E.M.`, the
motherboard hasn't been programmed yet — contact Dell.
