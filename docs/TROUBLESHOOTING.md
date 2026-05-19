# Troubleshooting Guide

For the MDT setup walkthrough, see [docs/MDT.md](MDT.md).

## MDT-Specific Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| Task sequence not found | `TaskSequenceID=` in `CustomSettings.ini` doesn't match exactly | Open MDT Workbench → Task Sequences, copy the exact ID |
| Laptop boots to existing Windows instead of USB | Boot order wrong | Press F12 at POST, select UEFI USB, or set USB first in BIOS |
| Deploy loops (reinstalls after reboot) | USB not removed before first reboot | Pull USB as soon as the LiteTouch progress bar disappears |
| `Unable to connect to the deployment share` | Wrong `DeployRoot=` or share not accessible | For standalone media verify `Bootstrap.ini` has `DeployRoot=.` (a literal dot) |
| WinPE loads then immediately reboots | Secure Boot blocking unsigned WinPE | Disable Secure Boot on the target machine |
| ISO too large for USB | Selection profile includes all OSes | Create a scoped selection profile in MDT Workbench with only the needed OS |

## DISM Errors

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

**Fix (preferred):** Rebuild LiteTouch WinPE via MDT Workbench by running
`Update-MDTDeploymentShare` (check "Completely regenerate boot image").
The ADK-built WinPE in MDT includes this reg key.

**Fix (quick test in a running WinPE session):**
```cmd
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v NtfsEnableDirCaseSensitivity /t REG_DWORD /d 1 /f
```
Then retry the apply. This is lost on reboot — bake it into the boot image
permanently per the preferred fix.

**Fallback (keep current boot image, strip the layer cache from the WIM):**
Mount the WIM, delete `\ProgramData\Microsoft\Windows\Containers\Layers`,
unmount /commit. The Containers feature stays installed; the layer cache
rebuilds on first use.

If the image has no Containers feature and you still see this error, the
WIM is probably corrupted on disk. Re-capture with `/CheckIntegrity /verify`
or re-copy the WIM from the master.

## Diskpart Errors

### Diskpart fails with exit code -2147211247 ("failed to clear disk attributes")

**Cause:** The target disk is flagged read-only (Storage Spaces leftovers,
BIOS write-protect, SED lock, HBA setting, or a physical write-protect
switch) and `attributes disk clear readonly` can't clear it.

**Fix:**
1. Physical: check for write-protect switches on the drive
2. Firmware: clear vendor security locks in BIOS/UEFI or the vendor tool
3. SED-locked drive: unlock via vendor tool or PSID-revert
4. Manual retry: `diskpart` → `select disk N` → `attributes disk clear readonly` → `clean`
5. If `clean` still fails, the protection is below the OS — resolve in firmware or swap hardware

## BCDBoot Errors

### BCDBoot fails

**Cause:** Boot configuration can't be written to the EFI partition.

**Fix:**
1. Verify the EFI partition was created and assigned correctly by the task sequence
2. Verify `C:\Windows` exists after DISM apply
3. Manually run from a WinPE command prompt:
   ```cmd
   bcdboot C:\Windows /s S: /f UEFI
   ```

## Post-Deploy Issues

### Deployment succeeds but Windows won't boot

**Possible causes:**
1. **Secure Boot:** The deployed Windows version may need Secure Boot disabled
2. **Wrong boot mode:** Ensure UEFI mode (not Legacy/CSM) in BIOS
3. **Missing drivers:** The target hardware may need storage drivers injected into the WIM
4. **BCDBoot didn't run:** Check the task sequence log (`X:\MININT\SMSOSD\OSDLOGS\BDD.log`) for BCDBoot errors

**Manual recovery:**
Boot back into WinPE and run:
```cmd
bcdboot C:\Windows /s S: /f UEFI
```

### CCTK: "CCTK returned exit code N - aborting deploy"

CCTK only runs when CCTK binaries are embedded in the LiteTouch WinPE and a config matches in the deployment share's `Applications\Dell-CCTK\configs\` folder. Common exit codes:

| Exit | Meaning | Fix |
|------|---------|-----|
| 0    | Success | — |
| 116  | HAPI driver load error | Rebuild LiteTouch WinPE with HAPI driver present (`Update-MDTDeploymentShare`). |
| 149  | Setup password mismatch | Add `--valsetuppwd=<current>` to the .ini so CCTK can authenticate with the existing BIOS password before changing it. |
| 197  | Setting not supported on this model | Check `cctk --help` against the actual hardware. Some settings are model-specific. |

If CCTK silently skips, verify the deployment share has an `Applications\Dell-CCTK\configs\` subdirectory containing at least one of `<SERVICETAG>.ini`, `<MODEL>.ini`, or `default.ini`.

See `docs/CCTK.md` for full configuration details.

## Getting Debug Info

Check task sequence logs on the target machine (or in WinPE before reboot):
```
X:\MININT\SMSOSD\OSDLOGS\BDD.log
```

Check DISM image info:
```cmd
Dism /Get-WimInfo /WimFile:D:\Deploy\Operating Systems\Win11_Pro\install.wim
```

Check disk state from a WinPE command prompt:
```cmd
diskpart
list disk
select disk 0
list partition
detail disk
```

## Known Caveats

These are intentional design choices or environmental constraints, not
bugs. For a list of what's recently changed, see
[CHANGELOG.md](../CHANGELOG.md).

### Update Media Content is slow on first run
Update Media Content (right-click MEDIA001 > Update Media Content) can take
10-30 minutes the first time. This is expected MDT behavior, not a hang.
Subsequent runs are faster if only content changed and not drivers or WinPE.

### MediaName MEDIA001 must be stable
If you rename the media object from `MEDIA001`, Workbench creates a new
orphaned media entry and leaves the old one behind. If you need a different
name, delete `MEDIA001` in Workbench first, then create the new one.

### Workbench overwrites task sequence partition settings
If you open the task sequence in MDT Workbench and save it, MDT regenerates
`ts.xml` from its internal model and may reset the partition layout. Always
re-verify the Format and Partition Disk step after any Workbench save and
re-run Update Media Content before distributing a new ISO.

### CCTK is not redistributable
Dell's EULA for Command | Configure does not allow shipping `cctk.exe`
or HAPI driver in this repo. Supply your own CCTK binaries and place them
in the deployment share. `.gitignore` blocks accidental commits.

### CCTK passwords sit in plaintext in the deployment share
Anyone with access to the deployment share (or the ISO/USB built from it)
can read setup/system passwords from `Applications\Dell-CCTK\configs\*.ini`. Mitigation is
physical USB security and rotating BIOS passwords post-deploy.
See [CCTK.md](CCTK.md).
