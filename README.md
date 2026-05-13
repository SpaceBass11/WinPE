# WinPE Windows Deployment USB

Bootable USB for reinstalling Windows on bare-metal machines from a
`.wim`/`.esd` image. No scripts, no automation framework — just
Microsoft's stock tools (`diskpart`, `DISM`, `bcdboot`) run by hand from
a WinPE command prompt.

> [!WARNING]
> **This procedure wipes entire disks.** `diskpart clean` is
> irreversible. Always confirm the disk number with `list disk` before
> typing `clean`. There is no undo.

---

## What's in the Box

| File / Folder              | Purpose                                              |
|----------------------------|------------------------------------------------------|
| `docs/USB_SETUP.md`        | Build the USB from scratch (one-time, yearly)        |
| `docs/UNATTEND.md`         | Optional: skip OOBE, create accounts, set hostname   |
| `docs/CCTK.md`             | Optional (Dell only): apply BIOS config before Windows |
| `docs/TROUBLESHOOTING.md`  | Common errors and fixes                              |
| `configs/unattend.example.xml` | Template answer file for first-boot setup        |

---

## Hardware You Need

- A target machine (UEFI mode, 4 GB RAM minimum, 8 GB+ recommended)
- A bootable WinPE USB built per [docs/USB_SETUP.md](docs/USB_SETUP.md),
  with at least one `.wim`/`.esd` in `I:\images\` on the USB's data
  partition

---

## Daily Deploy — Step by Step

Every deploy follows the same recipe. Read once, then it's mechanical.

### 1. Boot the target from USB (UEFI mode)

Plug the USB in. Power on. At POST press **F12** (Dell), **F9** (HP), or
your vendor's boot-menu key. Pick the entry that starts with **UEFI:**
followed by your USB stick's name. WinPE loads to a command prompt:

```
X:\Windows\System32>
```

### 2. Find the IMAGES partition

The USB's data partition holds your `.wim` files. It usually mounts as
`I:` (sometimes `D:` or `E:` depending on hardware). Run:

```
wmic logicaldisk get caption,volumename
```

Look for the row with VolumeName `IMAGES`. Note its drive letter (used
as `I:` below — substitute yours).

```
dir I:\images
```

You should see your `.wim` files listed.

### 3. (Dell only) Apply BIOS config

Skip this step on non-Dell hardware. See [docs/CCTK.md](docs/CCTK.md)
for details. Quick version:

```
X:\cctk\cctk.exe --infile=I:\cctk\default.ini
```

If exit code is **0**, continue. Anything else, stop and read CCTK.md.

### 4. Pick which Windows edition to deploy

A multi-edition install.wim has several indexes (Home, Pro, Enterprise…).
List them:

```
dism /Get-WimInfo /WimFile:I:\images\Win11.wim
```

Note the **Index:** number of the edition you want. If your WIM has only
one image, the index is **1**.

### 5. Find the target disk number

```
diskpart
list disk
exit
```

Note the **Disk ###** for the internal drive you're wiping. The USB
itself will also appear here — make sure you do **not** pick the USB.
Confirm by comparing sizes: the USB is usually 16-128 GB, the internal
drive is usually 256 GB or larger.

### 6. Wipe and partition the target

Save a file `X:\partition.txt` with these contents. Replace `0` on the
first line with **your** target disk number from step 5:

```
select disk 0
clean
convert gpt
create partition efi size=300
format quick fs=fat32 label="System"
assign letter=S
create partition msr size=16
create partition primary
format quick fs=ntfs label="Windows"
assign letter=C
exit
```

> [!CAUTION]
> **`clean` erases everything on that disk.** Re-read `select disk N`
> before saving. Once you run the script there is no undo.

Run it:

```
diskpart /s X:\partition.txt
```

Verify both partitions came up:

```
dir S:\
dir C:\
```

Both should return empty directories (no "file not found" error).

### 7. Apply the Windows image

Replace `Win11.wim` and `Index:1` with what step 4 told you:

```
dism /Apply-Image /ImageFile:I:\images\Win11.wim /Index:1 /ApplyDir:C:\
```

This takes 5-20 minutes depending on hardware and image size. Progress
shows in the console. When it finishes, verify:

```
dir C:\Windows\System32
```

You should see a long list of files.

### 8. (Optional) Stage an unattend.xml

Skip this if you're OK clicking through the Windows first-boot screens
manually. To auto-configure (accounts, hostname, OOBE skip), see
[docs/UNATTEND.md](docs/UNATTEND.md) for how to prepare the file. Then:

```
mkdir C:\Windows\Panther
copy I:\configs\unattend.xml C:\Windows\Panther\unattend.xml
```

Windows Setup picks this up automatically on first boot.

### 9. Configure UEFI boot

```
bcdboot C:\Windows /s S: /f UEFI
```

You should see **"Boot files successfully created."**

### 10. Reboot

```
wpeutil reboot
```

Pull the USB while the machine reboots. Windows OOBE (or your unattended
setup, if you staged one in step 8) starts.

---

## USB Drive Layout

```
USB Drive (32 GB+ recommended)
+-- Partition 1: WinPE Boot (FAT32, ~2 GB, label "WinPE")
|   `-- Contains WinPE + auto-launch command prompt
`-- Partition 2: Data (NTFS, remaining, label "IMAGES")
    +-- images/
    |   +-- Win11_Pro_24H2.wim
    |   +-- Win10_Enterprise_LTSC.wim
    |   `-- (any .wim or .esd files)
    +-- configs/                  (optional, unattend.xml)
    |   `-- unattend.xml
    `-- cctk/                     (optional, Dell BIOS configs)
        `-- default.ini
```

Two partitions, by design. FAT32 boot partition because UEFI firmware
can only boot from FAT32. NTFS data partition because WIM files are
typically larger than FAT32's 4 GB file-size limit.

---

## Disk Layout the Procedure Creates (on Target)

| Partition  | Size      | Format | Letter (in WinPE) | Purpose             |
|------------|-----------|--------|-------------------|---------------------|
| EFI System | 300 MB    | FAT32  | S:                | UEFI boot files     |
| MSR        | 16 MB     | -      | -                 | Microsoft Reserved  |
| Primary    | Remaining | NTFS   | C:                | Windows installation |

The drive letters `S:` and `C:` are temporary — they only exist during
the WinPE session. Once you reboot into the installed Windows, `C:` is
Windows, the EFI partition is hidden, and there is no `S:`.

---

## Safety Checklist

Before typing `clean`:

- [ ] You can see your target disk in `diskpart > list disk`
- [ ] You confirmed the **size** matches what's in the target machine
- [ ] The USB you booted from is also in the list and you know which
      number it is — and it's **not** the one you're about to wipe
- [ ] No other USB drives are plugged in (pull them now)
- [ ] You actually want to destroy everything on the target — `clean`
      removes partition tables, signatures, and existing data with no
      possibility of recovery short of forensic tools

---

## License

[MIT](LICENSE). Use this at your own risk; see the license for the full
disclaimer of warranty.
