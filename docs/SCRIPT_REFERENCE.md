# Script Reference

Complete technical reference for `unified_winpe_deploy.ps1`.

## Parameters

### -ImagePath [string]
Directory to search for `.wim`/`.esd` files. When provided, the script searches
only this directory (up to 2 levels deep) instead of scanning all drives.

```powershell
.\unified_winpe_deploy.ps1 -ImagePath "D:\images"
```

### -WimFile [string]
Direct path to a specific image file. Bypasses all discovery logic.

```powershell
.\unified_winpe_deploy.ps1 -WimFile "D:\images\Win11_Pro.wim"
```

### -TargetDisk [int]
Disk number to deploy to. Bypasses interactive disk selection. Use `diskpart` >
`list disk` to find disk numbers.

```powershell
.\unified_winpe_deploy.ps1 -TargetDisk 0
```

### -Silent [switch]
Suppresses all interactive prompts. Warnings are logged but don't block execution.
Useful for fully automated deployments when combined with `-WimFile` and `-TargetDisk`.

### -ListOnly [switch]
Discovers and displays all available images, then exits without deploying.

## Functions

### Core Functions

| Function | Purpose |
|----------|---------|
| `Write-Log` | Timestamped, color-coded console output |
| `Write-Banner` | Large section headers (80-char wide) |
| `Test-Administrator` | Checks if running as admin |
| `Show-MessageBox` | GUI dialog with console fallback |

### System Discovery

| Function | Purpose |
|----------|---------|
| `Initialize-SystemPaths` | Sets script directory, temp directory, diskpart script path |
| `Find-ImageFiles` | Main image discovery orchestrator |
| `Search-DirectoryForImages` | Scans a directory for .wim/.esd files |
| `Show-ImageSelection` | Interactive TUI image picker |

### System Validation

| Function | Purpose |
|----------|---------|
| `Test-WinPEEnvironment` | Detects if running in WinPE (X: drive, computer name) |
| `Test-SystemMemory` | Validates 8GB+ RAM with warning dialog |

### Disk Management

| Function | Purpose |
|----------|---------|
| `Get-SystemDisks` | Enumerates fixed (non-USB) disks via WMI |
| `Show-DiskMenu` | Color-coded disk selection display |
| `Select-TargetDisk` | Interactive disk picker with safety confirmations |

### Image Deployment

| Function | Purpose |
|----------|---------|
| `New-DiskpartScript` | Generates GPT partition script |
| `Invoke-Diskpart` | Executes diskpart with generated script |
| `Apply-WindowsImage` | Runs DISM /apply-image |
| `Set-BootConfiguration` | Runs bcdboot.exe for UEFI |

### Main Orchestrator

| Function | Purpose |
|----------|---------|
| `Start-Deployment` | Orchestrates the full workflow end-to-end |

## Configuration

Located at the top of the script in `$Script:Config`:

```powershell
$Script:Config = @{
    MinimumMemoryGB    = 8          # Warn below this
    ScriptVersion      = '4.1'     # Display version
    DiskpartScriptName = 'deploy_diskpart.txt'
    SearchPaths        = @('images', 'wim', 'deploy', 'windows', 'os')
    ImageExtensions    = @('*.wim', '*.esd')
}
```

## Partition Layout Created

The diskpart script creates:

```
Disk (GPT)
├── EFI System Partition  (300 MB, FAT32, Letter: S:)
├── Microsoft Reserved    (16 MB, no format)
└── Primary               (remaining, NTFS, Letter: C:)
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Failure (any step) |

## Image Discovery Priority

1. `-WimFile` parameter (direct path, no scanning)
2. `-ImagePath` parameter (searches specified directory)
3. Auto-discovery (scans all non-system drives)
   - Checks `images/`, `wim/`, `deploy/`, `windows/`, `os/` directories
   - Checks drive root (non-recursive)
   - Filters files > 100MB
   - Sorted by size descending

## Safety Chain

```
Admin check → WinPE detection → Memory check → Disk selection
                                                    ├── System disk? → Type "DESTROY SYSTEM"
                                                    └── Final confirm → Type "DELETE ALL DATA"
```
