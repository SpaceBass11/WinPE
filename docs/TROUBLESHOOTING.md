# Troubleshooting Guide

## Common Issues

### Script doesn't auto-start when WinPE boots

**Cause:** `startnet.cmd` not configured or PowerShell not available in WinPE.

**Fix:**
1. Mount the WinPE `boot.wim`
2. Verify `startnet.cmd` contains:
   ```cmd
   wpeinit
   powershell.exe -ExecutionPolicy Bypass -File X:\scripts\unified_winpe_deploy.ps1
   ```
3. Verify the script exists at `X:\scripts\unified_winpe_deploy.ps1`
4. Ensure WinPE-PowerShell package is included in the image


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

### DISM fails with error code

**Common DISM errors:**

| Error | Meaning | Fix |
|-------|---------|-----|
| 2 | File not found | Verify WIM path exists and is accessible |
| 11 | Invalid image index | Check available indexes with `Dism /Get-WimInfo /WimFile:path.wim` |
| 87 | Invalid parameter | Check WIM file integrity |
| 1392 | Corrupted WIM | Re-download or re-capture the image |
| 112 | Disk full | Target disk too small for the image |
| 1168 | Element not found | WIM may be corrupted or index doesn't exist |

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

## Getting Debug Info

Run the script manually to see full output:
```powershell
powershell.exe -ExecutionPolicy Bypass -File X:\scripts\unified_winpe_deploy.ps1
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
