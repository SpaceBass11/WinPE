# Creating the Deployment USB (Operator SOP)

The deployment ISO is fully self-contained. Rufus writes it to a USB
drive and produces a bootable UEFI installer. The operator plugs it
into any target laptop, boots from it, and walks away.

## Prerequisites

- **Rufus** -- download from [https://rufus.ie](https://rufus.ie)
- **USB drive** -- 32 GB or larger recommended (captured Clonezilla
  images are typically 15-25 GB)
- **The ISO** -- download from the link provided by your administrator

## Writing the USB

1. **Download the ISO** from the link provided by your administrator.
2. **Plug in the USB drive.**
3. **Open Rufus.** Select the ISO under "Boot selection" and select
   the USB drive under "Device." Leave all other settings at their
   defaults, then click **START**. If Rufus asks whether to write in
   ISO or DD mode, click **Yes** (DD mode).
4. **Wait** -- writing takes roughly 20 minutes depending on USB speed.
5. **Safely eject** the USB drive when Rufus reports "READY."

## Booting the target laptop

1. **Confirm BIOS is in AHCI mode, not RAID.** Clonezilla cannot see
   RAID-mode disks. If the laptop boots into Clonezilla and reports
   "no disk found", reboot, enter BIOS setup (usually F2 or DEL at
   POST), switch SATA mode to AHCI, save, and retry. Document this
   step in your operator handout.
2. **Press F12** (or the laptop's boot-menu key) at the POST screen.
3. **Select the USB entry that shows UEFI** in the name.
4. **Clonezilla Live boots** and automatically restores the captured
   image to the internal disk. The progress bar is on screen; do not
   interrupt.
5. **The laptop reboots** when restore finishes.
6. **Windows finishes specialize + OOBE** (no operator interaction
   required if the image was sysprepped correctly).
7. **`SetupComplete.cmd` runs** in the background: applies Dell BIOS
   config, enables BitLocker (TPM+PIN), removes one-time secrets,
   reboots once more.
8. Machine arrives at the **Windows login screen** with BitLocker
   protected and BIOS configured. Hand off to user.

## Collect the BitLocker recovery key before handoff

This workflow does not escrow recovery keys to AD or MDM. The folder is
ACL-locked to administrators, so on each deployed machine log in once as
`IT_Admin` (the built-in Administrator is disabled by the hardening step)
and copy this file off the machine:

```
C:\ProgramData\BitLockers\BitLocker-RecoveryKey-<hostname>-<timestamp>.txt
```

Store it per your team's SOP (encrypted USB key, password vault,
printed slip in a sealed envelope). If the file is missing, check
`C:\ProgramData\ManualClonezilla\Logs\Enable-BitLocker.log` for the
failure reason and report it -- do not hand off an encrypted machine
without a recoverable key.

## Important notes

**Secure Boot** -- Some laptops refuse to boot the Clonezilla Live
kernel under Secure Boot. If the USB POSTs to a black screen or
"Security Violation" message, enter BIOS/UEFI setup (usually F2 or
DEL), disable Secure Boot, save, and retry.

**Remove the USB after the restore phase completes** -- The first
reboot after Clonezilla finishes is when Windows takes over. If the
USB is still inserted and listed first in the boot order, the laptop
re-enters Clonezilla and loops. Pull the USB during the POST after the
restore phase.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Rufus fails or reports write errors | Try again using DD mode (Rufus will prompt, or select it manually under "Partition scheme"). Try a different USB drive. |
| Laptop boots into Windows instead of the USB | Re-enter the boot menu; make sure you select the **UEFI** USB entry, not the legacy one. |
| Clonezilla says "no disk found" | BIOS is in RAID mode -- switch to AHCI in BIOS setup and retry. |
| Restore finishes but laptop loops back into Clonezilla | USB was not removed -- unplug it during the next POST. |
| Clonezilla boot splash appears then goes black | Disable Secure Boot in BIOS/UEFI setup and retry. |
| Windows logs in but recovery key file is missing | Check `C:\ProgramData\ManualClonezilla\Logs\Enable-BitLocker.log`. Report to admin and **do not hand off**. |
