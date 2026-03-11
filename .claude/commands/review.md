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
- Verify WinPE environment detection logic
- Verify memory check with warning/prompt
- Verify disk selection requires typed confirmation ("DELETE ALL DATA")
- Verify system disk requires extra confirmation ("DESTROY SYSTEM")
- Check that USB drives are excluded from target disk list
- Look for any code paths that could bypass safety checks

## Deployment Logic
- Verify diskpart script creates correct GPT layout (EFI 300MB FAT32, MSR 16MB, Primary NTFS)
- Verify DISM command uses correct arguments for /apply-image
- Verify bcdboot.exe arguments are correct for UEFI (C:\Windows /s S: /f UEFI)
- Check that drive letters S: and C: are used consistently between diskpart, DISM, and bcdboot
- Verify cleanup of temp files after deployment

## Error Handling
- Check that all critical operations (diskpart, DISM, bcdboot) check exit codes
- Verify try/catch blocks around all external process calls
- Check that failures return $false and propagate up to halt deployment
- Verify the main entry point catches errors and exits with code 1

## Image Discovery
- Verify search priority: -WimFile > -ImagePath > auto-discovery
- Check that file size filter (>100MB) is appropriate
- Verify recursion depth limit works
- Check that system drive is excluded from scanning

## TUI & User Experience
- Verify color coding is consistent and appropriate
- Check that all menus have quit/cancel options
- Verify auto-select behavior when only one image is found
- Check -ListOnly and -Silent modes work correctly

Report findings as: PASS, WARN, or FAIL for each category with details.
