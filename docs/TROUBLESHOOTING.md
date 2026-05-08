# Troubleshooting Guide

## Common Issues

### Script doesn't auto-start when WinPE boots

**Cause:** `startnet.cmd` not configured or PowerShell not available in WinPE.

**Fix:** Use `scripts/build_boot_wim.ps1` (configures everything correctly
in one shot). If you must fix an existing boot.wim manually, verify
`startnet.cmd` ends with:
```cmd
wpeinit
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\scripts\unified_winpe_deploy.ps1
```
The script must exist at `X:\scripts\unified_winpe_deploy.ps1` and the
`WinPE-PowerShell` package must be installed in the image.


### "'timeout' is not recognized" at boot

**Cause:** Some WinPE images do not include `timeout.exe`, but `startnet.cmd`
contains `timeout /t ...`.

**Fix:** Replace the timeout call with a ping-based delay:
```cmd
ping -n 4 127.0.0.1 >nul
```

Also remove any trailing `pause` in `startnet.cmd` for fully unattended boots.

### "No Windows image files found!"

**Cause:** Script can't find any `.wim`/`.esd` files on attached drives.

**Fix:**
- Ensure images are on the USB data partition (not the WinPE boot partition)
- Place images in an `images/` subdirectory for fastest discovery
- Verify files are > 100MB (smaller files are filtered out)
- Use `-ImagePath` or `-WimFile` to point directly:
  ```powershell
  .\unified_winpe_deploy.ps1 -ImagePath "D:\images"
  ```
- Check if the NTFS data partition is mounting. In WinPE command prompt:
  ```cmd
  diskpart
  list volume
  ```

### "No suitable disks found"

**Cause:** Script filters for fixed (non-USB) disks. If the target disk is
seen as USB or removable, it won't appear.

**Fix:**
- Some NVMe/SSD drives may not report as "fixed" in WinPE. Check:
  ```powershell
  Get-WmiObject Win32_DiskDrive | Select Model, MediaType, InterfaceType
  ```
- If needed, the `Get-SystemDisks` function filter can be adjusted to include
  the target interface type

### Disk menu shows "No partitions" on a disk that clearly has data (e.g. Linux/RHEL)

**Cause:** Prior to v4.4.0, `Win32_DiskPartition` was used as the source of
truth for partition detection — but it only enumerates partitions Windows
recognizes, so Linux (ext4/xfs/LVM) partitions were silently reported as
"No partitions". A disk with data could appear as a safe empty target.

**Fix:** v4.4.0+ uses `Win32_DiskDrive.Partitions` (the raw partition-table
count) as the source of truth. Disks with Linux partitions now display
as `N partition(s) (non-Windows - e.g. Linux/LVM)` and correctly trigger
the `[HAS DATA - WILL BE ERASED!]` warning. Update to v4.4.0+ if you're
still seeing the old behavior.

### DISM fails with error code

**Common DISM errors:**

| Error | Meaning | Fix |
|-------|---------|-----|
| 1 | Incorrect function | See next section — usually Containers/Layers metadata or WIM corruption |
| 2 | File not found | Verify WIM path exists and is accessible |
| 11 | Invalid image index | Check available indexes with `Dism /Get-WimInfo /WimFile:path.wim` |
| 87 | Invalid parameter | Check WIM file integrity |
| 1392 | Corrupted WIM | Re-download or re-capture the image |
| 112 | Disk full | Target disk too small for the image |
| 1168 | Element not found | WIM may be corrupted or index doesn't exist |

### DISM apply fails at ~19% with "Incorrect function" (exit 1)

**Cause:** The captured image contains Windows Containers / Hyper-V layer
files under `C:\ProgramData\Microsoft\Windows\Containers\Layers\...`. These
set the NTFS `CASE_SENSITIVE_DIR` flag, which the WinPE kernel rejects
unless `NtfsEnableDirCaseSensitivity` is set in the WinPE registry.
`dism.log` typically shows `RestoreFileNodeList`, `RestoreFilesCallback`,
or `EnumImageDataEntries` returning "Incorrect function" on files inside
`Containers\Layers\`.

**Fix (preferred):** Rebuild your WinPE boot.wim with the provided builder,
which sets the reg tweak automatically:

```powershell
.\scripts\build_boot_wim.ps1 -Clean -UsbDrive P: -ReleaseUsbLetter
```

**Fix (quick test in a running WinPE session):**
```cmd
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v NtfsEnableDirCaseSensitivity /t REG_DWORD /d 1 /f
```
Then retry the apply. This is lost on reboot — bake it into the boot.wim
permanently per the preferred fix.

**Fallback (keep current boot.wim, strip the layer cache from the WIM):**
Mount the WIM, delete `\ProgramData\Microsoft\Windows\Containers\Layers`,
unmount /commit. The Containers feature stays installed; the layer cache
rebuilds on first use.

If the image has no Containers feature and you still see this error, the
WIM is probably corrupted on disk. Re-capture with `/CheckIntegrity /verify`
or re-copy the WIM from the master.

### Diskpart fails with exit code -2147211247 ("failed to clear disk attributes")

**Cause:** The target disk is flagged read-only (Storage Spaces leftovers,
BIOS write-protect, SED lock, HBA setting, or a physical write-protect
switch) and `attributes disk clear readonly` can't clear it.

The deploy script runs this command with `noerr` since v4.4.0, so diskpart
now proceeds to `clean` even if the clear fails — which often succeeds on
its own. If you still see this exit code, `clean` itself is failing.

**Fix:**
1. Physical: check for write-protect switches on the drive
2. Firmware: clear vendor security locks in BIOS/UEFI or the vendor tool
3. SED-locked drive: unlock via vendor tool or PSID-revert
4. Manual retry: `diskpart` → `select disk N` → `attributes disk clear readonly` → `clean`
5. If `clean` still fails, the protection is below the OS — resolve in firmware or swap hardware

### BCDBoot fails

**Cause:** Boot configuration can't be written to the EFI partition.

**Fix:**
1. Verify the EFI partition was created and assigned letter S:
   ```cmd
   diskpart
   list volume
   ```
2. Verify `C:\Windows` exists after DISM apply
3. Manually run: `bcdboot C:\Windows /s S: /f UEFI`

### Drive letter conflicts (C: or S: already in use)

**Cause:** In WinPE, drive letters may already be assigned to existing partitions.

**Fix:**
- Before running the script, clear letter assignments in diskpart:
  ```
  diskpart
  list volume
  select volume <number>
  remove letter=C
  ```
- Or modify the diskpart template in the script to use different letters

### Low memory warning

**Cause:** System has less than 8GB RAM. DISM can struggle with large images
on low-memory systems.

**Fix:**
- 4GB RAM is the practical minimum; 8GB+ recommended
- Use compressed WIMs (smaller memory footprint)
- If DISM fails with out-of-memory, try running it manually with `/ScratchDir:`
  pointing to a directory on a drive with free space:
  `dism /apply-image /imagefile:D:\images\install.wim /index:1 /applydir:C:\ /ScratchDir:D:\scratch`

### Script errors: "Cannot load System.Windows.Forms"

**Cause:** Normal in WinPE - the Windows Forms assembly isn't always available.

**Impact:** Minimal. The script falls back to console output for all dialogs.
The warning at startup can be ignored.

### USB drive not showing in UEFI boot menu

**Fix:**
1. Ensure the WinPE partition is FAT32 (required for UEFI boot)
2. Disable Secure Boot temporarily if the WinPE image isn't signed
3. Check USB is plugged into a USB port that supports boot (some rear ports only)
4. Verify the USB has a valid EFI boot structure:
   ```
   P:\EFI\Boot\bootx64.efi  (must exist)
   ```

### Deployment succeeds but Windows won't boot

**Possible causes:**
1. **Secure Boot:** The deployed Windows version may need Secure Boot disabled
2. **Wrong boot mode:** Ensure UEFI mode (not Legacy/CSM) in BIOS
3. **Missing drivers:** The target hardware may need storage drivers injected into the WIM
4. **BCDBoot didn't run:** Check the script output for BCDBoot errors

**Manual recovery:**
Boot back into WinPE and run:
```cmd
bcdboot C:\Windows /s S: /f UEFI
```

### startnet.cmd can't find image drive

**Cause:** USB data partition volume label doesn't match the label in `startnet.cmd`.

**Fix:** Either label the data partition `IMAGES` (matches USB_SETUP.md Step 4)
or edit the `find /i "IMAGES"` string in `startnet.cmd` to match your label.
If no label match is found, the script falls back to scanning all drives.

### CCTK: "CCTK returned exit code N - aborting deploy"

CCTK only runs when `X:\cctk\cctk.exe` is embedded in `boot.wim` (via the
builder's `-CctkSource` parameter) AND a config matches in
`%DEPLOY_IMAGE_DRIVE%\cctk\`. Common exit codes:

| Exit | Meaning | Fix |
|------|---------|-----|
| 0    | Success | — |
| 116  | HAPI driver load error | Rebuild boot.wim with `-CctkSource` pointing at a tree that contains `HAPI\hapint64.inf` (or similar). The builder logs a warning if it can't find a HAPI inf during the build. |
| 149  | Setup password mismatch | Add `--valsetuppwd=<current>` to the .ini so CCTK can authenticate with the existing BIOS password before changing it. |
| 197  | Setting not supported on this model | Check `cctk --help` against the actual hardware. Some settings are model-specific. |

If CCTK silently skips (`No CCTK config matched`), check that:
- The IMAGES partition has a `cctk\` subdirectory
- The directory contains at least one of `<SERVICETAG>.ini`,
  `<MODEL>.ini`, or `default.ini`
- `Win32_BIOS.SerialNumber` (your service tag) and `Win32_ComputerSystem.Model`
  match what you expect — run `wmic bios get serialnumber` and
  `wmic computersystem get model` from a WinPE shell to verify.

See `docs/CCTK.md` for full configuration details.

### "No additional disks selected" but I expected to see disk N

The additional-wipe menu only shows disks that:
- Are not the primary target (you already confirmed wiping that)
- Are not USB / removable / optical (filtered by `Get-SystemDisks`)

If you need to wipe a USB-attached drive, the deploy script intentionally
won't let you — pull it from the menu via `diskpart` manually:

```cmd
diskpart
list disk
select disk N
clean
```

## Getting Debug Info

Run the script manually to see full output:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\scripts\unified_winpe_deploy.ps1
```

Check available images:
```powershell
.\unified_winpe_deploy.ps1 -ListOnly
```

Check DISM image info:
```cmd
Dism /Get-WimInfo /WimFile:D:\images\install.wim
```

Check disk state:
```cmd
diskpart
list disk
select disk 0
list partition
detail disk
```
