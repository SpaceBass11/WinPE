# Known Issues & Audit Findings

Current status for `unified_winpe_deploy.ps1` (v4.3.0).

## Active Warnings

### 1. PowerShell runtime availability in CI/dev containers
- **Impact:** Repo validation scripts (`tests/test_parse.ps1`, `scripts/validate_script.ps1`) require `pwsh` and cannot run in environments where PowerShell is absent.
- **Workaround:** Run validation from WinPE/Windows or any runner with PowerShell installed.

### 2. USB disks are intentionally excluded from target list
- **Impact:** External USB SSD/HDD targets cannot be selected by default.
- **Assessment:** Safety-first behavior to avoid wiping the deployment USB itself.

### 3. 100MB discovery filter hides tiny lab images
- **Impact:** Very small test WIM/ESD files (<100MB) are skipped during auto-discovery.
- **Assessment:** Intentional to avoid accidental selection of boot/system artifacts.

## Recently Fixed

### A. Silent unattended safety contract tightened
- **Change:** `-Silent` deployment runs now require `-WimFile`, `-TargetDisk`, and `-Force` (unless using `-ListOnly`).
- **Benefit:** Prevents unexpected interactive prompts during automation.

### B. Direct image path validation improved
- **Change:** `-WimFile` now validates that the file exists and has a supported extension (`.wim`/`.esd`).
- **Benefit:** Fails fast on invalid inputs instead of attempting downstream operations.

## Notes

- `Get-WmiObject` remains in use intentionally for WinPE/PowerShell 5.1 compatibility.
- File logging is implemented and enabled (deployment logs are written to the active temp path).
