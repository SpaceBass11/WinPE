Run a comprehensive review of unified_winpe_deploy.ps1. Check ALL of the following:

## Syntax & Structure
- Parse the script for PowerShell syntax errors
- Verify all function definitions are complete and properly closed
- Check that all #region/#endregion blocks are balanced
- Verify CmdletBinding and parameter block are correct

## Version Consistency
- Check that $Script:Config.ScriptVersion matches the version in the header comment block (.VERSION)
- Flag any version mismatches

## Safety & Security Audit
- Verify administrator check exists and blocks non-admin execution
- Verify WinPE environment detection blocks non-WinPE unless user types "CONTINUE ANYWAY"
- Verify -Silent mode aborts (not bypasses) when not in WinPE
- Verify memory check with warning/prompt
- Verify target-disk selection requires typed "ERASE" (Test-FinalWipeConfirmation also accepts "DELETE ALL DATA" as a case-insensitive/trimmed alternate — grep for both strings)
- Verify system disk requires extra confirmation ("DESTROY SYSTEM")
- Verify additional-wipe disks (-WipeDisks / interactive extra-wipe menu) require a single typed "WIPE ALL" for the whole set
- Verify data-disk format requires typed "WIPE DATA" when -DataDiskNumber is set, and that -Silent -DataDiskNumber without -Force fails fast (WIPE DATA cannot prompt silently)
- Verify -Force skips "ERASE", "WIPE ALL", and "WIPE DATA" but NEVER skips "DESTROY SYSTEM" for system disks
- Verify -TargetDisk without -Force still requires typed "ERASE"
- Check that USB drives are excluded from target disk list
- Verify mountvol /d never unmounts $env:SystemDrive
- Verify New-DiskpartScript refuses to release the WIM source drive (ProtectedSourceDrive guard)
- Verify disk size validation blocks undersized disks
- Look for any code paths that could bypass safety checks

## Deployment Logic
- Verify diskpart script creates correct GPT layout (EFI 300MB FAT32, MSR 16MB, Primary NTFS)
- Verify drive letters C: and S: are freed before diskpart (but never the system drive)
- Verify post-diskpart verification checks S: and C: exist
- Verify WIM index enumeration uses DISM /Get-WimInfo /English for locale safety
- Verify edition selection flow (single index auto-selects, multi-index prompts)
- Verify DISM command uses correct arguments for /apply-image with selected index
- Verify DISM runs with -NoNewWindow for inline progress
- Verify post-deployment verification checks C:\Windows and C:\Windows\System32
- Verify bcdboot.exe arguments are correct for UEFI (C:\Windows /s S: /f UEFI)
- Check that drive letters S: and C: are used consistently between diskpart, DISM, and bcdboot
- Verify cleanup of temp files after deployment

## Error Handling
- Check that all critical operations (diskpart, DISM, bcdboot) check exit codes
- Verify try/catch blocks around all external process calls
- Verify recovery guidance is shown when DISM or BCDBoot fails mid-deployment
- Check that failures return $false and propagate up to halt deployment
- Verify the main entry point catches errors and exits with code 1
- Verify log file is initialized and written to throughout deployment

## Image Discovery
- Verify search priority: -WimFile > -ImagePath > auto-discovery
- Verify -WimFile path includes LastModified in the image hashtable
- Check that file size filter (>100MB) is appropriate
- Verify recursion depth limit works
- Check that system drive is excluded from scanning

## TUI & User Experience
- Verify color coding is consistent and appropriate
- Verify all TUI widths are consistent (80 columns)
- Check that all menus have quit/cancel options
- Verify auto-select behavior when only one image is found
- Check -ListOnly mode shows images and exits without prompting for selection
- Verify Show-MessageBox has console Read-Host fallback for YesNo dialogs
- Verify shutdown uses shutdown.exe (not Stop-Computer) for WinPE reliability

Report findings as: PASS, WARN, or FAIL for each category with details.
