# WinPE Image Deployment Tool - Claude Code Guide

## Project Overview

This is a **PowerShell-based WinPE image deployment tool** (v4.1) that automates
Windows installation from `.wim`/`.esd` files in a WinPE boot environment. The tool
is designed to run from a USB drive with a dual-partition layout: a small WinPE boot
partition and a larger data partition holding Windows images.

## Architecture

```
USB Drive Layout:
├── Partition 1: WinPE Boot (FAT32, ~2GB)
│   └── WinPE with startnet.cmd → launches unified_winpe_deploy.ps1
└── Partition 2: Data (NTFS, remaining space)
    └── images/
        ├── Win11_Pro.wim
        ├── Win10_LTSC.wim
        └── ...
```

**Primary script:** `unified_winpe_deploy.ps1` (708 lines)

### Deployment Flow
1. Boot from USB → WinPE loads → script auto-starts
2. Script scans for `.wim`/`.esd` files on non-system drives
3. User selects image via TUI menu
4. User selects target disk (with safety confirmations)
5. Diskpart wipes + partitions target (GPT: EFI 300MB + MSR 16MB + NTFS primary)
6. DISM applies the WIM to C:\
7. BCDBoot configures UEFI boot on S: (EFI partition)
8. Optional shutdown prompt

## Key Files

| File | Purpose |
|------|---------|
| `unified_winpe_deploy.ps1` | Main deployment script - the core deliverable |
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
- Safety check validation (admin, WinPE, memory, disk confirmations)
- Diskpart script correctness (GPT, EFI, MSR, NTFS)
- BCDBoot configuration
- Error handling coverage

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
- Color-coded TUI output via `Write-Log` function
- All destructive operations require explicit typed confirmation
- Script uses `$Script:` scope for shared configuration

## When Modifying the Script

1. **Never remove safety confirmations** - the multi-step disk destruction confirmations are critical
2. **Test syntax after every edit** - run `pwsh -c "[System.Management.Automation.PSParser]::Tokenize((Get-Content unified_winpe_deploy.ps1 -Raw), [ref]$null)"`
3. **Keep WinPE compatibility** - no modules that aren't available in WinPE (no Az, no ImportExcel, etc.)
4. **Version field** lives in `$Script:Config.ScriptVersion` (line ~39) AND in the header comment block
5. **Drive letters S: and C:** are hardcoded for EFI and Windows partitions respectively

## Known Constraints

- WinPE has limited PowerShell modules available
- `System.Windows.Forms` may not load in all WinPE builds (script handles this gracefully)
- `Get-WmiObject` is used instead of `Get-CimInstance` for broader WinPE compatibility
- No network dependency - everything runs offline from USB
- DISM runs with `-WindowStyle Hidden` so there's no progress bar (by design for TUI cleanliness)
