# WinPE Image Deployment Tool - Claude Code Guide

## Project Overview

This is a **PowerShell-based WinPE image deployment tool** (v4.3.0) that automates
Windows installation from `.wim`/`.esd` files in a WinPE boot environment. The tool
is designed to run from a USB drive with a dual-partition layout: a small WinPE boot
partition and a larger data partition holding Windows images.

## Architecture

```
USB Drive Layout:
├── Partition 1: WinPE Boot (FAT32, ~2GB)
│   └── WinPE with startnet.cmd → smart_launcher.cmd → unified_winpe_deploy.ps1
└── Partition 2: Data (NTFS, remaining space)
    └── images/
        ├── Win11_Pro.wim
        ├── Win10_LTSC.wim
        └── ...
```

**Primary script:** `unified_winpe_deploy.ps1`

### Deployment Flow
1. Boot from USB → WinPE loads → script auto-starts
2. Script scans for `.wim`/`.esd` files on non-system drives
3. User selects image via TUI menu
4. User selects Windows edition (WIM index) via DISM enumeration
5. User selects target disk (with safety confirmations)
6. Disk size validated against image size
7. Drive letters C:/S: freed if in use (never the system drive)
8. Diskpart wipes + partitions target (GPT: EFI 300MB + MSR 16MB + NTFS primary)
9. Post-diskpart verification (S: and C: available)
10. DISM applies the WIM to C:\ (progress shown inline)
11. Post-deploy verification (C:\Windows\System32 exists)
12. BCDBoot configures UEFI boot on S: (EFI partition)
13. Optional shutdown prompt (uses shutdown.exe for WinPE reliability)

## Key Files

| File | Purpose |
|------|---------|
| `unified_winpe_deploy.ps1` | Main deployment script - the core deliverable |
| `smart_launcher.cmd` | Batch launcher - finds image drive by volume label, launches script |
| `scripts/validate_script.ps1` | Static analysis checks for the deploy script |
| `tests/test_parse.ps1` | PowerShell syntax validation |
| `docs/USB_SETUP.md` | USB drive preparation guide |
| `docs/SCRIPT_REFERENCE.md` | Full parameter and function reference |
| `docs/TROUBLESHOOTING.md` | Common issues and fixes |

## Review & Validation Workflows

### Quick Review Loop
Use `/review` to run a comprehensive check of the deployment script covering:
- PowerShell syntax parsing
- Version consistency
- Safety check validation (admin, WinPE blocking, memory, disk confirmations, -Force behavior)
- Diskpart script correctness (GPT, EFI, MSR, NTFS, drive letter cleanup)
- Post-diskpart and post-deploy verification
- WIM index enumeration and edition selection
- BCDBoot configuration
- Error handling coverage (recovery guidance, log file)
- Disk size validation

### Running Checks
```bash
# Syntax validation only
pwsh -NoProfile -Command "& ./tests/test_parse.ps1"

# Full static analysis
pwsh -NoProfile -Command "& ./scripts/validate_script.ps1"
```

## Code Conventions

- **PowerShell 5.1+ compatible** (WinPE environment)
- Uses `#region`/`#endregion` blocks for organization
- Color-coded TUI output via `Write-Log` function (also writes to log file)
- All destructive operations require explicit typed confirmation
- `-Force` skips "DELETE ALL DATA" but NEVER skips system disk "DESTROY SYSTEM" prompt
- Script uses `$Script:` scope for shared configuration
- DISM `/Get-WimInfo` uses `/English` flag for locale-safe parsing

## When Modifying the Script

1. **Never remove safety confirmations** - the multi-step disk destruction confirmations are critical
2. **Never let -Force bypass system disk protection** - DESTROY SYSTEM must always be typed
3. **Test syntax after every edit** - run `pwsh -c "[System.Management.Automation.PSParser]::Tokenize((Get-Content unified_winpe_deploy.ps1 -Raw), [ref]$null)"`
4. **Keep WinPE compatibility** - no modules that aren't available in WinPE (no Az, no ImportExcel, etc.)
5. **Version field** lives in `$Script:Config.ScriptVersion` (line ~39) AND in the header comment block
6. **Drive letters S: and C:** are hardcoded for EFI and Windows partitions respectively
7. **Never unmount the system drive** - mountvol /d must check $env:SystemDrive first
8. **Use shutdown.exe, not Stop-Computer** - Stop-Computer is unreliable in WinPE

## Known Constraints

- WinPE has limited PowerShell modules available
- `System.Windows.Forms` may not load in all WinPE builds (script handles this gracefully with console Read-Host fallback for YesNo dialogs)
- `Get-WmiObject` is used instead of `Get-CimInstance` for broader WinPE compatibility
- No network dependency - everything runs offline from USB
- DISM runs with `-NoNewWindow` so progress is shown inline in the console
- Diskpart exit code 0 does not guarantee all commands succeeded - script verifies S: and C: exist after partitioning
- Log file lives in temp dir (typically X:\Windows\Temp in WinPE) - survives diskpart since X: is RAM disk
