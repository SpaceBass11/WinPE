# Creating the Deployment USB

The deployment ISO is fully self-contained — no network share, no server.
Rufus writes it to a USB drive and produces a bootable UEFI installer.
The operator plugs it into any target laptop, boots from it, and walks away.

## Prerequisites

- **Rufus** — download from [https://rufus.ie](https://rufus.ie)
- **USB drive** — 16 GB or larger recommended
- **The ISO** — download from your internal download link

## Steps

1. **Download the ISO** from the link provided by your administrator.
2. **Plug in the USB drive.**
3. **Open Rufus.** Select the ISO under "Boot selection" and select the USB
   drive under "Device." Leave all other settings at their defaults, then
   click **START**. If Rufus asks whether to write in ISO or DD mode,
   click **Yes** (DD mode).
4. **Wait** — writing takes roughly 20 minutes depending on USB speed.
5. **Safely eject** the USB drive when Rufus reports "READY."

## Booting the Target Laptop

1. Press **F12** (or your laptop's boot-menu key) at the POST screen.
2. Select the USB entry that shows **UEFI** in the name.
3. The MDT deployment sequence starts automatically — walk away.

## Important Notes

**Secure Boot** — Some laptops will refuse to boot an unsigned WinPE and
drop to a black screen or a "Security Violation" message. If this happens,
enter the BIOS/UEFI setup (usually F2 or DEL at POST), disable Secure Boot,
save, and retry.

**Remove the USB after deploy** — The machine reboots at the end of the
deployment sequence. Pull the USB drive before the POST screen clears or
the laptop will boot back into the installer and loop.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Rufus fails or reports write errors | Try again using DD mode (Rufus will prompt, or select it manually under "Partition scheme") |
| Laptop boots into Windows instead of the USB | Re-enter the boot menu; make sure you select the **UEFI** USB entry, not the legacy one |
| Deploy finishes but machine boots the installer again | USB was not removed before reboot — unplug it and power cycle |
| WinPE splash screen appears then goes black | Disable Secure Boot in BIOS/UEFI setup and retry |
