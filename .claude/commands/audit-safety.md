Perform a focused safety audit of unified_winpe_deploy.ps1.

Read the script and trace every code path that leads to destructive operations (diskpart, DISM apply, format). For each, verify:

1. **Can diskpart run without user confirmation?**
   - Trace from Start-Deployment through Select-TargetDisk
   - Check if -Silent + -TargetDisk can bypass confirmation
   - Check if -Force + -TargetDisk bypasses "DELETE ALL DATA" (intentional, but verify)
   - Check if -Force + -TargetDisk on system disk STILL requires "DESTROY SYSTEM" (CRITICAL)
   - Verify no code path skips all confirmations without -Force

2. **Can the system disk be wiped without extra confirmation?**
   - Verify IsSystemDisk detection logic (disk 0 when not in WinPE)
   - Verify "DESTROY SYSTEM" prompt is required in ALL code paths (interactive, -TargetDisk, -TargetDisk -Force)
   - Check if system disk detection is bypassed in WinPE (expected: yes, because all disks are deployment targets)

3. **Can DISM apply to wrong partition?**
   - Verify target path is always C:\
   - Verify C: is always assigned by our diskpart script (not pre-existing)
   - Verify post-diskpart check confirms S: and C: are available
   - Verify the selected WIM index is passed correctly to DISM /index:

4. **Can the script accidentally wipe the USB drive?**
   - Verify USB exclusion in Get-SystemDisks (InterfaceType -ne 'USB')
   - Consider edge cases (USB-connected SSDs, docking stations)

5. **Can mountvol /d unmount the running OS?**
   - Verify $env:SystemDrive is checked before freeing C: or S:
   - Check what happens if the script runs outside WinPE (via CONTINUE ANYWAY)

6. **What happens on partial failure?**
   - If diskpart succeeds but DISM fails, is the disk left wiped?
   - If DISM succeeds but bcdboot fails, is the system unbootable?
   - Are there recovery guidance messages for each failure scenario?
   - Is disk size validated before any destructive operation?

7. **Is the -Force flag properly scoped?**
   - -Force should ONLY affect the "DELETE ALL DATA" confirmation
   - -Force must NOT bypass: WinPE check, memory check, system disk protection, disk size validation
   - Verify each safety gate is independent of -Force

Report each finding with severity: CRITICAL / HIGH / MEDIUM / LOW / INFO
