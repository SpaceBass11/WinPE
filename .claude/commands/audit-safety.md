Perform a focused safety audit of unified_winpe_deploy.ps1.

Read the script and trace every code path that leads to destructive operations (diskpart, DISM apply, format). For each, verify:

1. **Can diskpart run without user confirmation?**
   - Trace from Start-Deployment through Select-TargetDisk
   - Check if -Silent + -TargetDisk can bypass confirmation
   - Check if any code path skips the "DELETE ALL DATA" prompt

2. **Can the system disk be wiped without extra confirmation?**
   - Verify IsSystemDisk detection logic
   - Verify "DESTROY SYSTEM" prompt is required

3. **Can DISM apply to wrong partition?**
   - Verify target path is always C:\
   - Verify C: is always assigned by our diskpart script (not pre-existing)

4. **Can the script accidentally wipe the USB drive?**
   - Verify USB exclusion in Get-SystemDisks (InterfaceType -ne 'USB')
   - Consider edge cases (USB-connected SSDs, docking stations)

5. **What happens on partial failure?**
   - If diskpart succeeds but DISM fails, is the disk left wiped?
   - If DISM succeeds but bcdboot fails, is the system unbootable?
   - Are there any recovery options presented?

Report each finding with severity: CRITICAL / HIGH / MEDIUM / LOW / INFO
