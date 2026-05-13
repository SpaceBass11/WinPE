# Troubleshooting

Common problems and fixes for both USB-build time and deploy time.

---

## USB Doesn't Boot from UEFI Menu

**Check the boot mode in BIOS.** The USB must be selected in **UEFI**
mode, not Legacy/CSM. The boot-menu entry should be prefixed
`UEFI:` or `UEFI USB`. If only a plain `USB:` entry shows up, enable
UEFI booting in BIOS setup (and disable Legacy/CSM if both are on).

**Check the boot partition is FAT32.** UEFI firmware only boots from
FAT32. If you accidentally formatted the boot partition NTFS, redo
[USB_SETUP.md step 2](USB_SETUP.md#step-2--partition-the-usb).

**Check the EFI boot loader exists:**

```
dir P:\EFI\Boot\bootx64.efi
```

If missing, re-run [USB_SETUP step 5](USB_SETUP.md#step-5--copy-winpe-to-the-usb).

**Try a different USB port.** Some machines only boot from rear or
specific ports. USB 3 typically works fine; USB-C may not on older
hardware.

**If Secure Boot is on**, the WinPE image needs to be signed. The
Microsoft-signed stock boot.wim that comes out of `copype` is fine for
Secure Boot. If you ever swap to a custom unsigned boot.wim, disable
Secure Boot in BIOS or sign the image.

---

## WinPE Boots but Doesn't Land at a Prompt

If WinPE hangs at "Press any key to boot from CD" or sits on a black
screen, the auto-launch via `startnet.cmd` may have failed.

Press **Shift+F10** (works in some WinPE builds) or wait for the
default startnet to time out — you should get a command prompt. From
there you can run the deploy procedure manually.

If `startnet.cmd` has a `timeout /t N` and you see
`'timeout' is not recognized`, you skipped `WinPE-WMI` or
`WinPE-Scripting` when building the image. Either rebuild the USB with
those components added (see USB_SETUP.md step 4b) or replace the
`timeout` line in `startnet.cmd` with:

```cmd
ping -n 4 127.0.0.1 >nul
```

---

## "wmic" or "diskpart" Not Recognized

You missed required ADK components when building boot.wim. Rebuild the
USB with all the packages from
[USB_SETUP.md step 4b](USB_SETUP.md#4b-add-the-required-optional-components),
particularly `WinPE-WMI` and `WinPE-StorageWMI`.

---

## "No drive letter for IMAGES partition"

`wmic logicaldisk get caption,volumename` doesn't show an `IMAGES`
volume.

**Most likely cause:** the data partition didn't auto-mount. Manually
assign a letter:

```
diskpart
list volume
```

Find the volume labeled `IMAGES`. Note its `Volume ###`, then:

```
select volume <number>
assign letter=I
exit
```

`I:` should now exist. Continue with [README step 3](../README.md#3-dell-only-apply-bios-config).

**Less likely:** the USB only had one partition created. Reformat the
USB per [USB_SETUP.md step 2](USB_SETUP.md#step-2--partition-the-usb).

---

## DISM Apply Fails

### Exit code 1 "Incorrect function" at ~19%

The image contains Windows Containers / Hyper-V layer files with
NTFS `CASE_SENSITIVE_DIR` flags. WinPE can't write those without the
registry tweak from [USB_SETUP step 4c](USB_SETUP.md#4c-apply-the-ntfs-case-sensitivity-fix).

**Quick test in the current WinPE session** (lost on reboot):

```
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v NtfsEnableDirCaseSensitivity /t REG_DWORD /d 1 /f
```

Then retry the `dism /Apply-Image` command. If it succeeds, **rebuild
boot.wim with the reg tweak baked in** so you don't have to do this
every time.

**Alternative:** strip the layer cache from the WIM. Mount the WIM on
your admin workstation, delete `\ProgramData\Microsoft\Windows\Containers\Layers`,
unmount with `/Commit`. The Containers feature stays installed; the
layer cache rebuilds on first use.

### Other DISM exit codes

| Code | Meaning             | Fix                                                  |
|------|---------------------|------------------------------------------------------|
| 2    | File not found      | Check the WIM path; `dir I:\images` first.           |
| 11   | Invalid image index | Run `dism /Get-WimInfo /WimFile:...` and pick a valid Index. |
| 87   | Invalid parameter   | Re-check syntax; copy-paste from README.md.          |
| 112  | Disk full           | Target disk is too small for the image.              |
| 1168 | Element not found   | WIM is missing the requested index, or corrupted.    |
| 1392 | Corrupted WIM       | Re-copy the WIM from the source ISO.                 |

If a WIM was captured with `/CheckIntegrity`, verify it:

```
dism /Get-WimInfo /WimFile:I:\images\Win11.wim /CheckIntegrity
```

A clean exit means the embedded hashes match. A failure means the file
was corrupted in transit — re-copy it.

---

## Diskpart Fails

### "Failed to clear disk attributes" (-2147211247)

The target disk is flagged read-only. Causes: Storage Spaces leftovers,
a hardware write-protect switch, an SED lock, or a vendor RAID setting.

**Try clearing it manually:**

```
diskpart
select disk <N>
attributes disk clear readonly
clean
```

If `attributes disk clear readonly` errors, append `noerr` and try
`clean` anyway:

```
attributes disk clear readonly noerr
clean
```

If `clean` still fails:

1. Check for a physical write-protect switch on the drive.
2. Clear vendor security locks in BIOS/UEFI or the drive vendor's
   tool.
3. SED-locked drive: unlock via vendor tool or PSID-revert.
4. If nothing works, the protection is below the OS. Swap hardware or
   resolve in firmware.

### "Disk 0 is not initialized" after `clean`

Normal after `clean`. The next line in your partition script should be
`convert gpt`, which initializes the disk. If you skipped that line,
add it.

---

## BCDBoot Fails

**"Failure when attempting to copy boot files"**: the EFI partition
isn't assigned letter `S:`. Verify:

```
diskpart
list volume
exit
```

Look for the FAT32 volume labeled `System` (300 MB). If it has a
different letter (or no letter), assign `S:` and re-run bcdboot:

```
diskpart
select volume <number>
assign letter=S
exit

bcdboot C:\Windows /s S: /f UEFI
```

**"Failure when initializing library system volume"**: usually means
`C:\Windows` doesn't actually exist (DISM apply failed silently).
Verify:

```
dir C:\Windows\System32
```

If empty, your DISM step didn't actually succeed — re-read the DISM
output for errors and retry.

---

## Drive Letter Conflicts

If `C:` or `S:` is already in use when you run the partition script
(rare, but happens if you re-run the procedure without rebooting WinPE),
the `assign letter=` command fails.

Clear it first:

```
diskpart
list volume
select volume <number-currently-using-C>
remove letter=C
exit
```

Then re-run your partition script.

---

## Deployment Succeeds but Windows Won't Boot

1. **Boot mode:** make sure the target BIOS is set to UEFI mode, not
   Legacy. The procedure creates a GPT/UEFI layout; Legacy boot can't
   read it.
2. **Secure Boot:** some Windows versions / WIMs require Secure Boot to
   be enabled for the bootloader to load.
3. **Missing storage drivers:** if the machine has an exotic NVMe
   controller or RAID, Windows may not have drivers for it. Either
   inject drivers into the WIM ahead of time (DISM
   `/Add-Driver` to a mounted WIM on your admin workstation) or change
   to AHCI in BIOS (Dell: see [CCTK.md](CCTK.md) for automating this).
4. **BCDBoot wasn't actually run:** boot back into WinPE, repeat step
   9 from README.md.

If you suspect BCDBoot is the problem, recovery is a one-liner from
WinPE:

```
bcdboot C:\Windows /s S: /f UEFI
```

(After re-assigning `S:` to the EFI partition first if needed.)

---

## "No additional disks were wiped" (When You Have Multiple Drives)

The procedure only wipes the disk you select. If a machine has a
second drive with leftover data you also want wiped, do it manually
**before** the main partition script:

```
diskpart
select disk <other-disk-number>
clean
exit
```

Then proceed with the normal partition script targeting your primary
disk.

> [!CAUTION]
> Don't `clean` the USB. Confirm size and `list disk` output before
> every `select` + `clean` pair.

---

## CCTK Fails (Dell)

See [CCTK.md → Troubleshooting](CCTK.md#troubleshooting) for the full
exit-code table. Most common:

- **Exit 116**: HAPI driver missing. Rebuild boot.wim per CCTK.md.
- **Exit 149**: Setup password mismatch. Add
  `--valsetuppwd=<current>` to the ini.

---

## Getting Debug Info

**What disks does WinPE see?**

```
diskpart
list disk
list volume
select disk <N>
list partition
detail disk
exit
```

**What's in this WIM?**

```
dism /Get-WimInfo /WimFile:I:\images\Win11.wim
```

**DISM detailed log** (after a failed apply):

```
type X:\Windows\Logs\DISM\dism.log
```

(Use `more` instead of `type` for a paged view.)

**Network in WinPE** (if you need to grab a tool):

```
ipconfig
ping 8.8.8.8
```

If networking isn't working, `WinPE-WMI` and a NIC driver may be
missing. Some onboard NICs need driver injection at boot.wim build
time — outside the scope of this procedure.

---

## When in Doubt

The procedure in [README.md](../README.md) is the source of truth.
If something doesn't match what's documented there, re-read the step
slowly. The most common mistake is typing the wrong disk number in
`select disk N`.
