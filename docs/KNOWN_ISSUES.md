# Known Issues & Audit Findings

Script audit of `unified_winpe_deploy.ps1` v4.1 - findings from code review.

## Bugs

### 1. Version mismatch between Config and header (FIXED)
- **Location:** Line 39 (`$Script:Config.ScriptVersion = '4.0'`) vs header (`.VERSION 4.1`)
- **Impact:** Banner displays wrong version
- **Status:** Fixed - Config updated to `'4.1'`

## Warnings

### 2. -Silent + -TargetDisk bypasses disk confirmation
- **Location:** `Select-TargetDisk` (line ~469)
- **Impact:** When `-TargetDisk` is specified, the function returns immediately without requiring "ERASE" confirmation. Combined with `-Silent`, this enables fully unattended disk wipe.
- **Assessment:** This is **by design** for automated/scripted deployments. The `-TargetDisk` parameter implies the caller has already made the decision. However, operators should be aware.
- **Recommendation:** Document this clearly. Consider adding a `-Force` switch for explicit unattended confirmation.

### 3. Drive letter conflicts possible
- **Location:** `New-DiskpartScript` (line ~533)
- **Impact:** If C: or S: are already assigned to other volumes in WinPE, diskpart's `assign letter` may fail or assign to wrong volume.
- **Assessment:** Low risk in WinPE (C: is typically not assigned). Documented in troubleshooting guide.
- **Recommendation:** Consider using `remove letter=C` / `remove letter=S` before diskpart, or use `assign letter` with fallback.

### 4. No WIM index selection
- **Location:** `Apply-WindowsImage` (line ~577, hardcoded `$ImageIndex = 1`)
- **Impact:** Multi-edition WIMs (e.g., Home/Pro/Enterprise in one file) always deploy index 1.
- **Assessment:** For custom single-index WIMs (the expected use case), this is fine. For stock Microsoft ISOs with multiple editions, the user can't choose.
- **Recommendation:** Add a `Get-WindowsImage` / `DISM /Get-ImageInfo` step to list indexes and let the user pick.

### 5. No progress indication during DISM
- **Location:** `Apply-WindowsImage` (line ~590, `-WindowStyle Hidden`)
- **Impact:** User sees "This will take several minutes - please wait..." with no progress updates. Large WIMs can take 10-20 minutes.
- **Assessment:** Cosmetic issue. The TUI just looks frozen.
- **Recommendation:** Consider running DISM with visible output or parsing its progress.

### 6. Test-WinPEEnvironment always returns $true
- **Location:** Line 342
- **Impact:** The function warns when not in WinPE but never blocks. The check is informational only.
- **Assessment:** This is acceptable - allows testing outside WinPE. But the return value is misleading since it's used in a conditional check in `Start-Deployment`.

### 7. Uses deprecated Get-WmiObject
- **Location:** Lines 381, 390, 347
- **Impact:** `Get-WmiObject` is deprecated in PowerShell 7+ in favor of `Get-CimInstance`.
- **Assessment:** **Keep as-is.** WinPE environments typically run PowerShell 5.1 where `Get-WmiObject` is the reliable option. `Get-CimInstance` may not work in all WinPE builds.

### 8. No file logging
- **Location:** `Write-Log` function (line ~62)
- **Impact:** All output goes to console only. If deployment fails, there's no log file to review.
- **Recommendation:** Add optional file logging to `$env:TEMP\deploy_log.txt`.

## Informational

### 9. 100MB file size filter may miss small test WIMs
- **Location:** `Search-DirectoryForImages` (line ~245)
- **Impact:** Test/lab WIMs under 100MB won't be discovered.
- **Assessment:** Intentional to avoid picking up boot.wim and other small system files.

### 10. No post-deployment verification
- **Location:** After `Apply-WindowsImage` and `Set-BootConfiguration`
- **Impact:** No check that C:\Windows actually exists after DISM, or that BCD is valid.
- **Recommendation:** Add a quick `Test-Path C:\Windows\System32\ntoskrnl.exe` check.
