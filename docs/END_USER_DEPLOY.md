# How to Install Windows from a USB Drive

You will need:

- The `.iso` file provided to you
- A USB drive, **8 GB or larger** (everything on it will be erased)
- [Rufus](https://rufus.ie) — a free tool that puts the ISO onto the USB

---

## Step 1 — Download Rufus

Go to **rufus.ie** and click the download link for the latest version.
Run the downloaded file — no installation needed.

---

## Step 2 — Flash the USB

1. Plug the USB drive into your computer.
2. Open Rufus.
3. Under **Device**, make sure your USB drive is selected.
4. Under **Boot selection**, click **SELECT** and choose the `.iso` file you were given.
5. Leave all other settings as-is.
6. Click **START**.
7. Rufus will warn that all data on the USB will be erased — click **OK**.
8. Wait until the status bar at the bottom says **READY**. This takes 5–15 minutes depending on USB speed.
9. Close Rufus. The USB is ready.

---

## Step 3 — Boot the Target Laptop from USB

1. Plug the USB into the laptop you want to install Windows on.
2. Power the laptop on (or restart it).
3. As soon as it starts, press the boot-menu key repeatedly:
   - **Dell:** F12
   - **HP:** F9 or Esc
   - **Lenovo:** F12
   - **Surface:** hold Volume Down while pressing the power button
4. A menu appears. Choose the USB drive (it may say "USB" or show the USB brand name).
5. Press Enter.

---

## Step 4 — Let it Run

The screen will show a progress bar and status messages. **Do not turn off or
unplug the laptop** while this is happening.

When it is finished the laptop will restart on its own. **Follow the on-screen
instructions** — your admin may have set this up so the USB must stay plugged in
for a second restart while disk encryption finishes (this is normal for BitLocker
deployments). If the on-screen instructions say it is safe to remove, take the
USB out when the screen goes black during the restart. Otherwise leave it
plugged in until the laptop restarts a second time on its own, then remove it.

The laptop will then finish setting up Windows. This can take a few minutes.

---

## Troubleshooting

**The laptop skips the USB and boots Windows normally.**
The boot menu key timing is tricky. Try again — press the key immediately and
repeatedly the moment you press the power button, before anything appears on screen.

**Nothing happens / black screen after choosing USB.**
The USB may not have flashed correctly. Redo Step 2 with a different USB drive if
possible.

**"Windows cannot be installed to this disk" or a red error on screen.**
Contact the person who gave you the ISO — do not retry on your own.

---

## For IT Staff: Producing This ISO

Use `scripts/build_iso.ps1` after running `build_boot_wim.ps1` and
`prepare_wim.ps1`. See `CLAUDE.md` and `docs/SCRIPT_REFERENCE.md` for
the full pipeline.

Quick example:

```powershell
# Prerequisites (run once each):
.\scripts\build_boot_wim.ps1 -Clean          # builds WinPE boot.wim
.\scripts\prepare_wim.ps1 `
    -SourceIso 'D:\Win11_24H2.iso' `
    -OutputWim 'C:\build\Win11_Custom.wim' `
    -DisableExtraBloat

# Produce the distributable ISO:
.\scripts\build_iso.ps1 `
    -WimFile      'C:\build\Win11_Custom.wim' `
    -OutputIso    'D:\release\Win11_Deploy.iso' `
    -UnattendFile 'I:\configs\unattend.xml' `
    -ConfirmSilentDestructiveIso
```

`-ConfirmSilentDestructiveIso` is mandatory unless you also pass
`-Interactive`. It acknowledges that the ISO will wipe whichever
physical disk Windows enumerates as `-TargetDisk` (default: `0`) on
the end-user's machine, with no operator confirmation. The builder
refuses to run silently without it.

The resulting ISO is ~4–6 GB. Send it via a file-sharing link (OneDrive,
Google Drive, etc.). Minimum USB size is 8 GB.
