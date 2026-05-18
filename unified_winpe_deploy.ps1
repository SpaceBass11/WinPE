#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Universal WinPE Image Deployment Tool
.DESCRIPTION
    Generic Windows image deployment tool for WinPE environments.
    Automatically discovers WIM files and safely deploys to target disks.
    To speed up discovery, provide -ImagePath or -WimFile to skip drive scanning.
.PARAMETER ImagePath
    Path to search for image files. Limits scanning to the specified directory
    and avoids enumerating all attached drives.
.PARAMETER WimFile
    Path to a specific WIM or ESD image file. When specified, the image is used
    directly without any drive scanning.
.PARAMETER TargetDisk
    Pre-select a disk number to deploy to. Still requires typed ERASE
    confirmation unless combined with -Force. Use 'diskpart > list disk' to
    find the right number. -1 (default) means "ask interactively".
.PARAMETER WipeDisks
    Comma-separated additional disk numbers to clean (no repartitioning)
    alongside the primary target. Example: "1,2". Validated against the
    pattern '^\s*\d+(\s*,\s*\d+)*\s*$' in silent mode. Requires -Force when
    combined with -Silent.
.PARAMETER MinImageSizeMB
    Minimum image file size in MB during auto-discovery. Files smaller than
    this are skipped to avoid picking up boot/system artifacts that happen
    to share the .wim/.esd extension. Default: 100. Lower it if you're
    using small lab images.
.PARAMETER Force
    Skip the typed "ERASE" confirmation when -TargetDisk is set. Also skips
    the "WIPE ALL" confirmation when -WipeDisks is set. Does NOT bypass the
    "DESTROY SYSTEM" confirmation when targeting the running system disk —
    that always requires the typed string.
.PARAMETER Silent
    Unattended mode for automation. For deployment runs (not -ListOnly), it
    requires -WimFile, -TargetDisk, and -Force, and a single-index image.
    Fails fast if any precondition is missing.
.PARAMETER UnattendFile
    Path to an unattend.xml answer file. After the Windows image is applied,
    the file is copied to C:\Windows\Panther\unattend.xml so Windows Setup
    picks it up on first boot (standard search-order location). Use this for
    OOBE skip, computer name, autologon, domain join, or any other first-boot
    configuration. The file must exist before deployment starts.
.PARAMETER ListOnly
    Discover and display all available images, then exit. No deployment.
.VERSION
    4.6.0 - Driver injection support via prepare_wim.ps1 -DriverPath (pre-bake
            drivers offline). Unattend.xml staging via -UnattendFile (dropped
            to C:\Windows\Panther post-apply for first-boot processing: OOBE
            skip, computer name, autologon, domain join).
    4.5.0 - CCTK pre-apply BIOS configuration (Dell fleets, RAID->AHCI
            automation). Multi-disk wipe stage for secondary drives and
            vendor OEM partitions. New -WipeDisks parameter for silent
            automation.
    4.4.0 - Diskpart resilience (noerr on readonly clear), Linux/LVM partition
            detection, DISM /CheckIntegrity, exit-1 guidance, reproducible
            boot.wim builder (scripts/build_boot_wim.ps1)
#>

[CmdletBinding()]
param(
    [string]$ImagePath,
    [string]$WimFile,
    [int]$TargetDisk = -1,
    [string]$WipeDisks,
    [int]$MinImageSizeMB = 100,
    [string]$UnattendFile,
    [switch]$Force,
    [switch]$Silent,
    [switch]$ListOnly
)

# Load required assemblies
try {
    Add-Type -AssemblyName System.Windows.Forms
} catch {
    Write-Warning "Could not load Windows Forms - dialog boxes will not be available"
}

#region Configuration
$Script:Config = @{
    MinimumMemoryGB = 8
    ScriptVersion = '4.6.0'
    DiskpartScriptName = 'deploy_diskpart.txt'
    SearchPaths = @('images', 'wim', 'deploy', 'windows', 'os')
    ImageExtensions = @('*.wim', '*.esd')
    CctkPath = 'X:\cctk\cctk.exe'
    CctkConfigDir = 'cctk'
    # BitLocker: Enhanced PIN used at every boot. Change before building USB.
    # Set DataDiskNumber to -1 to skip data-disk formatting and BitLocker entirely.
    BitLockerPin   = 'ChangeMe123!'
    DataDiskNumber = 1
}

$Script:Colors = @{
    Success = 'Green'
    Warning = 'Yellow'
    Error = 'Red'
    Info = 'Cyan'
    Prompt = 'White'
    Header = 'Magenta'
}

$Script:SystemPaths = @{
    ScriptDir = $null
    TempDir = $null
    DiskpartScript = $null
    LogFile = $null
}

# Prevent repeated warning spam if file logging fails
$Script:LogWriteFailureNotified = $false
#endregion

#region Core Functions
function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Success','Warning','Error','Info','Prompt','Header')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $color = $Script:Colors[$Level]
    Write-Host "[$timestamp] $Message" -ForegroundColor $color

    # Append to log file if available
    if ($Script:SystemPaths.LogFile) {
        try {
            $logTimestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Add-Content -Path $Script:SystemPaths.LogFile -Value "[$logTimestamp] [$Level] $Message" -ErrorAction Stop
        } catch {
            if (-not $Script:LogWriteFailureNotified) {
                Write-Host "[$timestamp] WARNING: Could not write to log file ($($Script:SystemPaths.LogFile)): $($_.Exception.Message)" -ForegroundColor Yellow
                $Script:LogWriteFailureNotified = $true
            }
        }
    }
}

function Write-Banner {
    param([string]$Title)

    $line = "=" * 80
    Write-Host ""
    Write-Host $line -ForegroundColor $Script:Colors.Header
    $centeredTitle = $Title.PadLeft([Math]::Floor(($Title.Length + 80) / 2))
    Write-Host $centeredTitle -ForegroundColor $Script:Colors.Header
    Write-Host $line -ForegroundColor $Script:Colors.Header
    Write-Host ""
}

function Test-Administrator {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-MessageBox {
    param(
        [string]$Message,
        [string]$Title = "Windows Image Deployment",
        [string]$Buttons = "OK",
        [string]$Icon = "Information"
    )

    if (-not ([System.Management.Automation.PSTypeName]'System.Windows.Forms.MessageBox').Type) {
        Write-Log $Message -Level Warning
        # Console fallback for YesNo dialogs
        if ($Buttons -eq 'YesNo') {
            $answer = Read-Host "Enter Y for Yes or N for No"
            return $(if ($answer -match '^[Yy]') { 'Yes' } else { 'No' })
        }
        return 'OK'
    }

    try {
        $buttonType = [System.Windows.Forms.MessageBoxButtons]::$Buttons
        $iconType = [System.Windows.Forms.MessageBoxIcon]::$Icon
        return [System.Windows.Forms.MessageBox]::Show($Message, $Title, $buttonType, $iconType)
    } catch {
        Write-Log $Message -Level Warning
        if ($Buttons -eq 'YesNo') {
            $answer = Read-Host "Enter Y for Yes or N for No"
            return $(if ($answer -match '^[Yy]') { 'Yes' } else { 'No' })
        }
        return 'OK'
    }
}
#endregion

#region System Discovery
function Initialize-SystemPaths {
    Write-Log "Initializing system paths..." -Level Info

    # Determine script directory
    if ($PSScriptRoot) {
        $Script:SystemPaths.ScriptDir = $PSScriptRoot
    } else {
        $Script:SystemPaths.ScriptDir = Split-Path -Parent $script:MyInvocation.MyCommand.Path
    }

    # Set temp directory with fallbacks
    $tempCandidates = @($env:TEMP, 'X:\Windows\Temp', 'X:\Temp', 'C:\Temp')
    foreach ($tempPath in $tempCandidates) {
        if ($tempPath) {
            try {
                if (-not (Test-Path $tempPath)) {
                    New-Item -Path $tempPath -ItemType Directory -Force | Out-Null
                }
                $Script:SystemPaths.TempDir = $tempPath
                break
            } catch {
                continue
            }
        }
    }

    if (-not $Script:SystemPaths.TempDir) {
        $Script:SystemPaths.TempDir = 'C:\Temp'
        try { New-Item -Path 'C:\Temp' -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        catch { Write-Warning "Could not create fallback temp directory C:\Temp - logging may not work" }
    }

    # Set diskpart script path
    $Script:SystemPaths.DiskpartScript = Join-Path $Script:SystemPaths.TempDir $Script:Config.DiskpartScriptName

    # Initialize log file
    $logName = "deploy_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $Script:SystemPaths.LogFile = Join-Path $Script:SystemPaths.TempDir $logName

    # Log file is now available - log session header
    Write-Log "=== WinPE Deploy v$($Script:Config.ScriptVersion) - Session Start ===" -Level Header
    Write-Log "Script directory: $($Script:SystemPaths.ScriptDir)" -Level Success
    Write-Log "Temp directory: $($Script:SystemPaths.TempDir)" -Level Success
    Write-Log "Log file: $($Script:SystemPaths.LogFile)" -Level Info
}

function Find-ImageFiles {
    Write-Log "Searching for Windows image files..." -Level Info

    # If specific WIM file provided, use it
    if ($WimFile) {
        if ((Test-Path $WimFile -PathType Leaf) -and ([IO.Path]::GetExtension($WimFile).ToLowerInvariant() -in @('.wim', '.esd'))) {
            Write-Log "Using specified WIM file: $WimFile" -Level Success
            $item = Get-Item $WimFile
            return @(@{
                Path = $WimFile
                Name = Split-Path -Leaf $WimFile
                Size = $item.Length
                Type = 'Specified'
                LastModified = $item.LastWriteTime
            })
        } elseif (Test-Path $WimFile -PathType Leaf) {
            Write-Log "Specified file is not a supported image type (.wim/.esd): $WimFile" -Level Error
            return @()
        } else {
            Write-Log "Specified WIM file not found: $WimFile" -Level Error
            return @()
        }
    }

    # Environment variable fallback: startnet.cmd may pre-discover the image drive
    if (-not $ImagePath -and $env:DEPLOY_IMAGE_DRIVE) {
        # Normalize: ensure drive root has trailing backslash (D: → D:\)
        $envDrive = $env:DEPLOY_IMAGE_DRIVE
        if ($envDrive -match '^[A-Za-z]:$') { $envDrive = "$envDrive\" }
        if (Test-Path $envDrive) {
            Write-Log "Using image drive from launcher: $envDrive" -Level Info
            $ImagePath = $envDrive
        }
    }

    # If specific image path provided, search there
    if ($ImagePath) {
        if (Test-Path $ImagePath) {
            return Search-DirectoryForImages -Path $ImagePath -Source "Specified path"
        }
        Write-Log "Specified image path not found: $ImagePath" -Level Error
        return @()
    }

    # Auto-discovery across all non-system drives (specify -ImagePath or -WimFile to skip scanning)
    Write-Log "Starting auto-discovery of image files..." -Level Info
    $allImages = @()

    try {
        # Enumerate all filesystem drives except the current system drive
        $drives = Get-PSDrive -PSProvider FileSystem |
                  Where-Object { "$($_.Name):" -ne $env:SystemDrive }

        foreach ($drive in $drives) {
            $driveLetter = "$($drive.Name):"
            Write-Log "Scanning drive $driveLetter..." -Level Info

            # Search common image directories
            foreach ($searchPath in $Script:Config.SearchPaths) {
                $fullPath = Join-Path $driveLetter $searchPath
                if (Test-Path $fullPath) {
                    $images = Search-DirectoryForImages -Path $fullPath -Source "Drive $driveLetter\$searchPath"
                    $allImages += $images
                }
            }

            # Search root directory (but not recursively to avoid USB drives, etc.)
            # Use "D:\" not "D:" — bare drive letter means current directory on that drive, not root
            $rootImages = Search-DirectoryForImages -Path "$driveLetter\" -Source "Drive $driveLetter (root)" -Recurse:$false
            $allImages += $rootImages
        }
    } catch {
        Write-Log "Error during drive scanning: $($_.Exception.Message)" -Level Error
    }

    # Remove duplicates and sort by size (larger files first, likely more complete)
    $uniqueImages = $allImages | Sort-Object Path -Unique | Sort-Object Size -Descending

    Write-Log "Discovery complete. Found $($uniqueImages.Count) image file(s)" -Level Success
    return $uniqueImages
}

function Search-DirectoryForImages {
    param(
        [string]$Path,
        [string]$Source,
        [bool]$Recurse = $true,
        [int]$Depth = 2
    )

    # Search for image files with limited recursion depth
    $images = @()

    try {
        foreach ($extension in $Script:Config.ImageExtensions) {
            $searchParams = @{
                Path        = $Path
                Filter      = $extension
                File        = $true
                ErrorAction = 'SilentlyContinue'
            }

            if ($Recurse) {
                $searchParams.Recurse = $true
                $searchParams.Depth   = $Depth
            }

            $files = Get-ChildItem @searchParams

            foreach ($file in $files) {
                # Skip tiny files (likely not real images) - threshold from -MinImageSizeMB
                if ($file.Length -gt ($MinImageSizeMB * 1MB)) {
                    $images += @{
                        Path = $file.FullName
                        Name = $file.Name
                        Size = $file.Length
                        Type = $Source
                        LastModified = $file.LastWriteTime
                    }
                    Write-Log "  Found: $($file.Name) ($([Math]::Round($file.Length/1GB, 2)) GB)" -Level Info
                }
            }
        }
    } catch {
        Write-Log "Error searching $Path : $($_.Exception.Message)" -Level Warning
    }

    return $images
}

function Show-ImageList {
    param([array]$Images)

    if ($Images.Count -eq 0) {
        Write-Log "No Windows image files found!" -Level Error
        Write-Log "Searched for: $($Script:Config.ImageExtensions -join ', ')" -Level Info
        Write-Log "In directories: $($Script:Config.SearchPaths -join ', ')" -Level Info
        return
    }

    Write-Host ""
    Write-Host ("="*80) -ForegroundColor $Script:Colors.Header
    Write-Host "AVAILABLE WINDOWS IMAGE FILES".PadLeft(50) -ForegroundColor $Script:Colors.Header
    Write-Host ("="*80) -ForegroundColor $Script:Colors.Header

    for ($i = 0; $i -lt $Images.Count; $i++) {
        $image = $Images[$i]
        $sizeGB = [Math]::Round($image.Size / 1GB, 2)
        $modified = $image.LastModified.ToString('yyyy-MM-dd HH:mm')

        Write-Host ""
        Write-Host "[$($i + 1)] $($image.Name)" -ForegroundColor $Script:Colors.Success
        Write-Host "     Size: $sizeGB GB" -ForegroundColor White
        Write-Host "     Modified: $modified" -ForegroundColor White
        Write-Host "     Location: $($image.Type)" -ForegroundColor $Script:Colors.Info
        Write-Host "     Path: $($image.Path)" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host ("="*80) -ForegroundColor $Script:Colors.Header
}

function Show-ImageSelection {
    param([array]$Images)

    if ($Images.Count -eq 0) {
        Write-Log "No Windows image files found!" -Level Error
        Write-Log "Searched for: $($Script:Config.ImageExtensions -join ', ')" -Level Info
        Write-Log "In directories: $($Script:Config.SearchPaths -join ', ')" -Level Info
        Write-Log "Try using -ImagePath or -WimFile parameters" -Level Info
        return $null
    }

    Write-Host ""
    Write-Host ("="*80) -ForegroundColor $Script:Colors.Header
    Write-Host "AVAILABLE WINDOWS IMAGE FILES".PadLeft(50) -ForegroundColor $Script:Colors.Header
    Write-Host ("="*80) -ForegroundColor $Script:Colors.Header

    for ($i = 0; $i -lt $Images.Count; $i++) {
        $image = $Images[$i]
        $sizeGB = [Math]::Round($image.Size / 1GB, 2)
        $modified = $image.LastModified.ToString('yyyy-MM-dd HH:mm')

        Write-Host ""
        Write-Host "[$($i + 1)] $($image.Name)" -ForegroundColor $Script:Colors.Success
        Write-Host "     Size: $sizeGB GB" -ForegroundColor White
        Write-Host "     Modified: $modified" -ForegroundColor White
        Write-Host "     Location: $($image.Type)" -ForegroundColor $Script:Colors.Info
        Write-Host "     Path: $($image.Path)" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host ("="*80) -ForegroundColor $Script:Colors.Header

    # Auto-select if only one image
    if ($Images.Count -eq 1) {
        Write-Log "Only one image found, auto-selecting: $($Images[0].Name)" -Level Success
        return $Images[0]
    }

    # Interactive selection
    do {
        Write-Host ""
        $choice = Read-Host "Select image number (1-$($Images.Count)) or 'q' to quit"

        if ($choice -eq 'q') {
            return $null
        }

        try {
            $index = [int]$choice - 1
            if ($index -ge 0 -and $index -lt $Images.Count) {
                $selectedImage = $Images[$index]
                Write-Log "Selected: $($selectedImage.Name)" -Level Success
                return $selectedImage
            } else {
                Write-Log "Please enter a number between 1 and $($Images.Count)" -Level Error
            }
        } catch {
            Write-Log "Please enter a valid number or 'q'" -Level Error
        }
    } while ($true)
}
#endregion

#region System Validation
function Test-WinPEEnvironment {
    $isWinPE = ($env:SystemDrive -eq 'X:') -or (Test-Path 'X:\Windows')

    if ($isWinPE) {
        Write-Log "WinPE environment detected" -Level Success
        return $true
    }

    Write-Log "WARNING: Not running in WinPE environment!" -Level Warning
    Write-Log "Running outside WinPE may damage your current Windows installation." -Level Warning

    if ($Silent) {
        Write-Log "Aborting - not in WinPE environment (silent mode)" -Level Error
        return $false
    }

    $confirm = Read-Host "Type 'CONTINUE ANYWAY' to proceed outside WinPE, or press Enter to abort"
    if ($confirm -ne 'CONTINUE ANYWAY') {
        Write-Log "Operation cancelled - not in WinPE environment" -Level Error
        return $false
    }

    return $true
}

function Test-SystemMemory {
    try {
        $computer = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
        $totalMemoryGB = [Math]::Round($computer.TotalPhysicalMemory / 1GB, 2)

        Write-Log "Total system memory: $totalMemoryGB GB" -Level Info

        if ($totalMemoryGB -lt $Script:Config.MinimumMemoryGB) {
            $message = "Low memory detected: $totalMemoryGB GB (Recommended: $($Script:Config.MinimumMemoryGB) GB)`n`nThis may cause DISM operations to fail. Continue anyway?"

            if ($Silent) {
                Write-Log "Continuing with low memory (silent mode)" -Level Warning
                return $true
            }

            $result = Show-MessageBox -Message $message -Title "Memory Warning" -Buttons "YesNo" -Icon "Warning"
            if ($result -eq 'No') {
                Write-Log "Operation cancelled due to memory warning" -Level Error
                return $false
            }
        }

        return $true
    } catch {
        Write-Log "Could not determine system memory - continuing anyway" -Level Warning
        return $true
    }
}
#endregion

#region Disk Management
function Get-SystemDisks {
    Write-Log "Scanning system disks..." -Level Info

    try {
        $disks = @()
        $allWmiDisks = Get-WmiObject -Class Win32_DiskDrive -ErrorAction Stop
        # Log skipped USB disks for transparency
        $usbDisks = $allWmiDisks | Where-Object { $_.InterfaceType -eq 'USB' }
        foreach ($usbDisk in $usbDisks) {
            Write-Log "Skipping USB disk $($usbDisk.Index): $($usbDisk.Model) (USB drives excluded for safety)" -Level Info
        }
        $nonTargetableMedia = $allWmiDisks | Where-Object {
            $_.InterfaceType -ne 'USB' -and (
                $_.MediaType -like "*removable*" -or
                $_.MediaType -like "*cd*" -or
                $_.Model -like "*cd*"
            )
        }
        foreach ($skippedDisk in $nonTargetableMedia) {
            Write-Log "Skipping non-targetable media disk $($skippedDisk.Index): $($skippedDisk.Model) ($($skippedDisk.MediaType))" -Level Info
        }
        $wmiDisks = $allWmiDisks | Where-Object {
            $_.InterfaceType -ne 'USB' -and
            $_.MediaType -notlike "*removable*" -and
            $_.MediaType -notlike "*cd*" -and
            $_.Model -notlike "*cd*" -and
            ([double]$_.Size -gt 0)
        }

        # Query all partitions once instead of per-disk
        $allPartitions = @(Get-WmiObject -Class Win32_DiskPartition -ErrorAction SilentlyContinue)

        foreach ($wmiDisk in $wmiDisks) {
            $diskNumber = $wmiDisk.Index
            $sizeGB = if ($wmiDisk.Size) { [Math]::Round([double]$wmiDisk.Size / 1GB, 2) } else { 0 }

            # Filter Windows-recognized partitions for this disk from the single query
            $partitions = @($allPartitions | Where-Object { $null -ne $_ -and $_.DiskIndex -eq $diskNumber })

            # Use Win32_DiskDrive.Partitions as the source of truth - it reads the partition
            # table directly and counts non-Windows partitions (Linux ext/xfs/LVM, etc.) that
            # Win32_DiskPartition silently omits. Critical for safety - prevents Linux disks
            # from being reported as empty.
            $partitionCount = if ($null -ne $wmiDisk.Partitions) { [int]$wmiDisk.Partitions } else { $partitions.Count }
            $hasPartitions = $partitionCount -gt 0

            $partitionInfo = if (-not $hasPartitions) {
                "No partitions"
            } elseif ($partitions.Count -gt 0) {
                $detail = ($partitions | ForEach-Object { "Part$($_.Index):$([Math]::Round([double]$_.Size/1GB,1))GB" }) -join ", "
                if ($partitionCount -gt $partitions.Count) {
                    "$detail (+$($partitionCount - $partitions.Count) non-Windows)"
                } else {
                    $detail
                }
            } else {
                "$partitionCount partition(s) (non-Windows - e.g. Linux/LVM)"
            }

            $disk = [PSCustomObject]@{
                Number = $diskNumber
                Size = $sizeGB
                Model = if ($wmiDisk.Model) { $wmiDisk.Model.Trim() } else { "Unknown" }
                InterfaceType = if ($wmiDisk.InterfaceType) { $wmiDisk.InterfaceType } else { "Unknown" }
                HasPartitions = $hasPartitions
                PartitionInfo = $partitionInfo
                IsSystemDisk = $false
            }

            # System disk detection: check if any partition on this disk hosts the system drive
            if ($env:SystemDrive -ne 'X:') {
                try {
                    foreach ($part in $partitions) {
                        $logicalDisks = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($part.DeviceID)'} WHERE AssocClass=Win32_LogicalDiskToPartition" -ErrorAction SilentlyContinue
                        foreach ($ld in $logicalDisks) {
                            if ("$($ld.DeviceID)" -eq $env:SystemDrive) {
                                $disk.IsSystemDisk = $true
                            }
                        }
                    }
                } catch {
                    # Fallback: assume disk 0 is system disk when not in WinPE
                    if ($diskNumber -eq 0) {
                        $disk.IsSystemDisk = $true
                    }
                }
            }

            $disks += $disk
        }

        Write-Log "Found $($disks.Count) suitable disk(s)" -Level Success
        return $disks
    } catch {
        Write-Log "Error scanning disks: $($_.Exception.Message)" -Level Error
        return @()
    }
}

function Show-DiskMenu {
    param([array]$Disks)

    Write-Host ""
    Write-Host ("="*80) -ForegroundColor $Script:Colors.Header
    Write-Host "AVAILABLE DISKS FOR IMAGING".PadLeft(50) -ForegroundColor $Script:Colors.Header
    Write-Host ("="*80) -ForegroundColor $Script:Colors.Header

    foreach ($disk in $Disks) {
        $warning = ""
        $color = $Script:Colors.Info

        if ($disk.IsSystemDisk) {
            $warning = " [SYSTEM DISK - DANGER!]"
            $color = $Script:Colors.Error
        } elseif ($disk.HasPartitions) {
            $warning = " [HAS DATA - WILL BE ERASED!]"
            $color = $Script:Colors.Warning
        } else {
            $color = $Script:Colors.Success
        }

        Write-Host ""
        Write-Host "Disk $($disk.Number):$warning" -ForegroundColor $color
        Write-Host "  Model: $($disk.Model)" -ForegroundColor White
        Write-Host "  Size: $($disk.Size) GB ($($disk.InterfaceType))" -ForegroundColor White
        Write-Host "  Status: $($disk.PartitionInfo)" -ForegroundColor White
    }

    Write-Host ""
    Write-Host ("="*80) -ForegroundColor $Script:Colors.Error
    Write-Host "WARNING: ALL DATA ON SELECTED DISK WILL BE DESTROYED!" -ForegroundColor $Script:Colors.Error
    Write-Host ("="*80) -ForegroundColor $Script:Colors.Error
}


function Test-FinalWipeConfirmation {
    param([string]$InputText)

    $normalized = if ($null -eq $InputText) { '' } else { $InputText.Trim().ToUpperInvariant() }
    return $normalized -in @('ERASE', 'DELETE ALL DATA')
}

function Select-TargetDisk {
    param([array]$Disks)

    if ($Disks.Count -eq 0) {
        Write-Log "No suitable disks found" -Level Error
        return $null
    }

    # Use provided target disk if valid
    if ($TargetDisk -ge 0) {
        $selectedDisk = $Disks | Where-Object { $_.Number -eq $TargetDisk }
        if (-not $selectedDisk) {
            Write-Log "Specified target disk $TargetDisk not found" -Level Error
            return $null
        } elseif ($Force) {
            # -Force skips final confirmation but NEVER skips system disk protection
            if ($selectedDisk.IsSystemDisk) {
                Write-Log "DANGER: -Force cannot bypass system disk protection!" -Level Error
                if ($Silent) {
                    Write-Log "Silent mode cannot continue because system disk confirmation requires typed input" -Level Error
                    return $null
                }
                $confirm = Read-Host "Type 'DESTROY SYSTEM' to confirm system disk wipe"
                if ($confirm -ne 'DESTROY SYSTEM') {
                    Write-Log "System disk wipe cancelled" -Level Warning
                    return $null
                }
            }
            Write-Log "Using specified target disk $TargetDisk with -Force (skipping confirmation)" -Level Warning
            return $selectedDisk
        } else {
            Write-Log "Pre-selected target disk: $TargetDisk (use -Force to skip confirmation)" -Level Info
            Show-DiskMenu -Disks @($selectedDisk)
            # System disk requires DESTROY SYSTEM even with -TargetDisk
            if ($selectedDisk.IsSystemDisk) {
                Write-Log "DANGER: Specified disk $TargetDisk is the system disk!" -Level Error
                $sysConfirm = Read-Host "Type 'DESTROY SYSTEM' to confirm system disk wipe"
                if ($sysConfirm -ne 'DESTROY SYSTEM') {
                    Write-Log "System disk wipe cancelled" -Level Warning
                    return $null
                }
            }
            Write-Host ""
            $finalConfirm = Read-Host "Type 'ERASE' to proceed with Disk $TargetDisk"
            if (Test-FinalWipeConfirmation -InputText $finalConfirm) {
                Write-Log "Target disk confirmed: Disk $TargetDisk" -Level Success
                return $selectedDisk
            }
            Write-Log "Disk selection cancelled" -Level Warning
            return $null
        }
    }

    # Interactive selection
    do {
        Show-DiskMenu -Disks $Disks

        Write-Host ""
        $choice = Read-Host "Select disk number (or 'q' to quit)"

        if ($choice -eq 'q') {
            Write-Log "Disk selection cancelled" -Level Warning
            return $null
        }

        try {
            $diskNum = [int]$choice
            $selectedDisk = $Disks | Where-Object { $_.Number -eq $diskNum }

            if (-not $selectedDisk) {
                Write-Log "Invalid disk number: $diskNum" -Level Error
                continue
            }

            # System disk warning
            if ($selectedDisk.IsSystemDisk) {
                Write-Log "DANGER: You selected the system disk!" -Level Error
                $confirm = Read-Host "Type 'DESTROY SYSTEM' to confirm"
                if ($confirm -ne 'DESTROY SYSTEM') {
                    continue
                }
            }

            # Final confirmation
            Write-Host ""
            Write-Host "FINAL CONFIRMATION" -ForegroundColor $Script:Colors.Error
            Write-Host "Disk $($selectedDisk.Number): $($selectedDisk.Model) ($($selectedDisk.Size) GB)" -ForegroundColor Yellow
            Write-Host "This will PERMANENTLY DELETE all data on this disk!" -ForegroundColor $Script:Colors.Error
            Write-Host ""
            $finalConfirm = Read-Host "Type 'ERASE' to proceed"

            if (Test-FinalWipeConfirmation -InputText $finalConfirm) {
                Write-Log "Target disk confirmed: Disk $diskNum" -Level Success
                return $selectedDisk
            }

        } catch {
            Write-Log "Please enter a valid disk number" -Level Error
        }
    } while ($true)
}
#endregion

#region Image Index Selection
function Get-WimImageInfo {
    param([string]$WimPath)

    Write-Log "Reading image indexes from $(Split-Path -Leaf $WimPath)..." -Level Info

    try {
        $output = & dism.exe /Get-WimInfo /WimFile:"$WimPath" /English 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "DISM /Get-WimInfo failed (exit code $LASTEXITCODE) - WIM file may be corrupted or inaccessible" -Level Warning
            return @()
        }
        $indexes = @()
        $currentIndex = $null

        foreach ($line in $output) {
            if ($line -match '^\s*Index\s*:\s*(\d+)') {
                if ($currentIndex) { $indexes += $currentIndex }
                $currentIndex = @{ Index = [int]$Matches[1]; Name = ''; Description = ''; Size = '' }
            } elseif ($currentIndex -and $line -match '^\s*Name\s*:\s*(.+)') {
                $currentIndex.Name = $Matches[1].Trim()
            } elseif ($currentIndex -and $line -match '^\s*Description\s*:\s*(.+)') {
                $currentIndex.Description = $Matches[1].Trim()
            } elseif ($currentIndex -and $line -match '^\s*Size\s*:\s*(.+)') {
                $currentIndex.Size = $Matches[1].Trim()
            }
        }
        if ($currentIndex) { $indexes += $currentIndex }

        return $indexes
    } catch {
        Write-Log "Could not read WIM info: $($_.Exception.Message)" -Level Warning
        return @()
    }
}

function Select-ImageIndex {
    param(
        [string]$WimPath,
        [array]$Indexes
    )

    if ($Indexes.Count -eq 0) {
        Write-Log "Could not enumerate WIM indexes from DISM" -Level Error
        Write-Log "Automatic fallback to index 1 is disabled to avoid deploying the wrong edition" -Level Error
        Write-Log "Run: dism /Get-WimInfo /WimFile:`"$WimPath`" /English, then re-run with a healthy image" -Level Info
        return $null
    }

    if ($Indexes.Count -eq 1) {
        Write-Log "Single image index: $($Indexes[0].Name)" -Level Success
        return $Indexes[0].Index
    }

    if ($Silent) {
        Write-Log "Silent mode cannot prompt for edition selection when multiple indexes exist" -Level Error
        Write-Log "Provide a single-index image or run without -Silent to choose an index interactively" -Level Error
        return $null
    }

    Write-Host ""
    Write-Host ("="*80) -ForegroundColor $Script:Colors.Header
    Write-Host "AVAILABLE WINDOWS EDITIONS".PadLeft(50) -ForegroundColor $Script:Colors.Header
    Write-Host ("="*80) -ForegroundColor $Script:Colors.Header

    # Warn about ESD recovery indexes
    if ($WimPath -match '\.esd$') {
        Write-Host ""
        Write-Host "  NOTE: ESD files may contain recovery indexes (typically 1-3)." -ForegroundColor $Script:Colors.Warning
        Write-Host "  Choose the Windows edition you want, not a recovery image." -ForegroundColor $Script:Colors.Warning
    }

    foreach ($idx in $Indexes) {
        Write-Host ""
        Write-Host "[$($idx.Index)] $($idx.Name)" -ForegroundColor $Script:Colors.Success
        if ($idx.Description -and $idx.Description -ne $idx.Name) {
            Write-Host "     $($idx.Description)" -ForegroundColor White
        }
        if ($idx.Size) {
            Write-Host "     Size: $($idx.Size)" -ForegroundColor $Script:Colors.Info
        }
    }

    Write-Host ""
    Write-Host ("="*80) -ForegroundColor $Script:Colors.Header

    do {
        Write-Host ""
        $validIndexes = ($Indexes | ForEach-Object { $_.Index }) -join ', '
        $choice = Read-Host "Select edition index ($validIndexes) or 'q' to quit"

        if ($choice -eq 'q') { return $null }

        try {
            $num = [int]$choice
            $match = $Indexes | Where-Object { $_.Index -eq $num }
            if ($match) {
                Write-Log "Selected edition: $($match.Name)" -Level Success
                return $match.Index
            }
            Write-Log "Invalid index. Choose from the list above." -Level Error
        } catch {
            Write-Log "Please enter a valid number or 'q'" -Level Error
        }
    } while ($true)
}
#endregion

#region Image Deployment
function New-DiskpartScript {
    param(
        [int]$DiskNumber,
        [array]$ExtraWipeDisks = @()
    )

    # Free up S:, C:, and D: (when formatting data disk) to avoid diskpart conflicts
    $lettersToFree = @('S', 'C')
    if ($Script:Config.DataDiskNumber -ge 0) { $lettersToFree += 'D' }
    foreach ($letter in $lettersToFree) {
        if (Test-Path "$($letter):\" ) {
            # NEVER unmount the current system drive
            if ("$($letter):" -eq $env:SystemDrive) {
                Write-Log "Cannot release $($letter): - it is the current system drive. Diskpart will reassign." -Level Warning
                continue
            }
            Write-Log "Drive letter $($letter): is in use - releasing before partitioning" -Level Warning
            try {
                & mountvol "$($letter):" /d 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "mountvol returned exit code $LASTEXITCODE for $($letter): - diskpart will attempt to reassign" -Level Warning
                }
            } catch {
                Write-Log "Could not release $($letter): - diskpart will attempt to reassign" -Level Warning
            }
        }
    }

    # Preamble: clean any additional disks the user requested first.
    # These get a bare 'clean' only - no GPT conversion, no partitions.
    # Windows Setup / future deploys can take them from there.
    $extraPreamble = ''
    foreach ($extra in $ExtraWipeDisks) {
        $extraPreamble += @"
select disk $($extra.Number)
online disk noerr
attributes disk clear readonly noerr
clean

"@
    }

    $dataDiskCommands = ''
    if ($Script:Config.DataDiskNumber -ge 0) {
        $dataDiskCommands = @"

select disk $($Script:Config.DataDiskNumber)
online disk noerr
attributes disk clear readonly noerr
clean
convert gpt
create partition primary
format quick fs=ntfs label=Data
assign letter D
"@
    }

$commands = @"
$extraPreamble
select disk $DiskNumber
online disk noerr
attributes disk clear readonly noerr
clean
convert gpt
create partition efi size=300
format quick fs=fat32 label=System
assign letter S
create partition msr size=16
create partition primary
format quick fs=ntfs label=Windows
assign letter C
$dataDiskCommands
exit
"@

    try {
        Set-Content -Path $Script:SystemPaths.DiskpartScript -Value $commands -Force
        Write-Log "Diskpart script created at $($Script:SystemPaths.DiskpartScript):" -Level Success
        foreach ($line in ($commands -split "`n")) {
            $trimmed = $line.Trim()
            if ($trimmed) { Write-Log "  > $trimmed" -Level Info }
        }
        return $true
    } catch {
        Write-Log "Failed to create diskpart script: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Invoke-Diskpart {
    Write-Log "Partitioning disk - this may take a moment..." -Level Warning

    try {
        $diskpartLog = Join-Path $Script:SystemPaths.TempDir 'diskpart_output.log'
        $dpOutput = ''
        $diskpartErrLog = Join-Path $Script:SystemPaths.TempDir 'diskpart_error.log'
        $process = Start-Process -FilePath 'diskpart.exe' -ArgumentList "/s `"$($Script:SystemPaths.DiskpartScript)`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput $diskpartLog -RedirectStandardError $diskpartErrLog

        # Log diskpart output for diagnostics
        if (Test-Path $diskpartLog) {
            $dpOutput = Get-Content $diskpartLog -Raw -ErrorAction SilentlyContinue
            if ($dpOutput) {
                Write-Log "Diskpart output:" -Level Info
                foreach ($line in ($dpOutput -split "`n")) {
                    $trimmed = $line.Trim()
                    if ($trimmed) { Write-Log "  $trimmed" -Level Info }
                }
            }
            Remove-Item $diskpartLog -Force -ErrorAction SilentlyContinue
        }

        if (Test-Path $diskpartErrLog) {
            $dpErrOutput = Get-Content $diskpartErrLog -Raw -ErrorAction SilentlyContinue
            if ($dpErrOutput) {
                if ($dpOutput) { $dpOutput = "$dpOutput`n$dpErrOutput" } else { $dpOutput = $dpErrOutput }
                Write-Log "Diskpart error output:" -Level Warning
                foreach ($line in ($dpErrOutput -split "`n")) {
                    $trimmed = $line.Trim()
                    if ($trimmed) { Write-Log "  $trimmed" -Level Warning }
                }
            }
            Remove-Item $diskpartErrLog -Force -ErrorAction SilentlyContinue
        }

        if ($process.ExitCode -eq 0) {
            Write-Log "Disk partitioning completed" -Level Success
            return $true
        } else {
            Write-Log "Diskpart failed with exit code $($process.ExitCode)" -Level Error

            # Common failure mode: EFI/MSR commands run on non-GPT disk context
            $gptHint = $false
            if ($dpOutput -match 'MSR and EFI partitions are only supported on GPT disks') {
                $gptHint = $true
            }
            if ($process.ExitCode -eq -2147024809) {
                $gptHint = $true
            }
            if ($gptHint) {
                Write-Log 'MSR and EFI partitions are only supported on GPT disks.' -Level Error
                Write-Log 'Ensure the selected disk can be converted to GPT, then try again.' -Level Info
                Write-Log 'If needed, manually run: diskpart -> select disk N -> attributes disk clear readonly -> clean -> convert gpt' -Level Info
                Write-Log 'If clean fails, check firmware/HBA write-protect settings and vendor security locks.' -Level Info
                Write-Log 'If disk is offline, manually run: diskpart -> select disk N -> online disk -> attributes disk clear readonly -> clean -> convert gpt' -Level Info
            }

            # Read-only / write-protected disk: clean cannot wipe the partition table
            $readOnlyHint = $false
            if ($dpOutput -match 'failed to clear disk attributes' -or
                $dpOutput -match 'media is write protected' -or
                $dpOutput -match 'current read-only state' -or
                $dpOutput -match 'disk is read.only') {
                $readOnlyHint = $true
            }
            if ($readOnlyHint) {
                Write-Log 'Target disk appears to be read-only or write-protected.' -Level Error
                Write-Log 'Possible causes:' -Level Info
                Write-Log '  - Physical write-protect switch on the drive (SD cards, some USB sticks)' -Level Info
                Write-Log '  - BIOS/UEFI firmware write protection or vendor security lock' -Level Info
                Write-Log '  - Self-encrypting drive (SED) in a locked state - unlock or PSID-revert in vendor tool' -Level Info
                Write-Log '  - HBA/RAID controller exposing the disk read-only' -Level Info
                Write-Log '  - Disk still held by another process (close File Explorer, retry)' -Level Info
                Write-Log 'Manually try: diskpart -> select disk N -> attributes disk clear readonly -> clean' -Level Info
                Write-Log 'If attributes clear fails, the protection is below the OS - resolve in firmware/hardware.' -Level Info
            }

            return $false
        }
    } catch {
        Write-Log "Diskpart execution error: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Apply-WindowsImage {
    param(
        [string]$WimPath,
        [string]$TargetPath,
        [int]$ImageIndex = 1
    )

    Write-Log "Applying Windows image to $TargetPath" -Level Info
    Write-Log "Source: $(Split-Path -Leaf $WimPath)" -Level Info
    Write-Log "Index: $ImageIndex" -Level Info
    Write-Log "This will take several minutes - please wait..." -Level Warning

    try {
        # Note: applydir is not quoted because C:\" causes DISM error 123 (backslash escapes the quote)
        # /CheckIntegrity: surfaces WIM corruption up front with a clear error instead of
        # letting apply fail mid-stream with cryptic "Incorrect function" messages on files
        # with dense hard-link/reparse metadata (e.g. Windows Containers layers).
        $arguments = "/apply-image /imagefile:""$WimPath"" /index:$ImageIndex /applydir:$TargetPath /CheckIntegrity"
        $process = Start-Process -FilePath 'dism.exe' -ArgumentList $arguments -Wait -PassThru -NoNewWindow

        if ($process.ExitCode -eq 0) {
            Write-Log "Windows image applied successfully" -Level Success
            return $true
        }

        Write-Log "DISM failed with exit code $($process.ExitCode)" -Level Error

        # Operator-facing recovery guidance for known DISM apply failures.
        # The full lookup table lives in docs/TROUBLESHOOTING.md; this block
        # surfaces the most common one-liners inline so the operator doesn't
        # have to scroll past the trace or open another doc.
        $dismLog = 'X:\Windows\Logs\DISM\dism.log'
        switch ($process.ExitCode) {
            1 {
                # ERROR_INVALID_FUNCTION. Almost always means the WIM has damaged
                # metadata (often surfacing on Windows Containers layer files, which
                # use huge hard-link storms) or the source drive is returning bad
                # reads mid-apply.
                Write-Log "Exit code 1 ('Incorrect function') usually means WIM corruption or a flaky source-drive read." -Level Warning
                Write-Log "Check $dismLog for the exact failing file/operation." -Level Info
                Write-Log "Recovery steps to try:" -Level Info
                Write-Log "  1. Verify WIM integrity:  dism /Get-WimInfo /WimFile:""$WimPath"" /Index:$ImageIndex /CheckIntegrity" -Level Info
                Write-Log "  2. Re-copy the WIM to the USB drive - the on-disk copy may have bit-rot" -Level Info
                Write-Log "  3. Try a different USB port or a USB 2.0 port (some USB 3.x controllers drop reads)" -Level Info
                Write-Log "  4. If the image includes Windows Containers/Hyper-V layers, try a different edition" -Level Info
                Write-Log "  5. Last resort: retry with /NoRpFix manually: dism /apply-image /imagefile:""$WimPath"" /index:$ImageIndex /applydir:C:\ /NoRpFix" -Level Info
            }
            2 {
                Write-Log "Exit code 2 ('File not found') means DISM lost access to the WIM mid-apply." -Level Warning
                Write-Log "Check that '$WimPath' is still readable - the USB drive may have been disconnected." -Level Info
            }
            11 {
                Write-Log "Exit code 11 ('Invalid image index') means index $ImageIndex doesn't exist in this WIM." -Level Warning
                Write-Log "List available indexes:  dism /Get-WimInfo /WimFile:""$WimPath""" -Level Info
            }
            50 {
                Write-Log "Exit code 50 ('Request not supported') usually means the target volume or WIM features aren't compatible with this WinPE/hardware combo." -Level Warning
                Write-Log "Common causes: WIM architecture mismatch (x64 vs x86 vs ARM64), target volume not NTFS, or unmet feature-pack requirements." -Level Info
                Write-Log "Check $dismLog for the specific operation that triggered the failure." -Level Info
            }
            87 {
                Write-Log "Exit code 87 ('Invalid parameter') means DISM rejected its arguments." -Level Warning
                Write-Log "Most often: WIM file is corrupted or unreadable. Try:  dism /Get-WimInfo /WimFile:""$WimPath"" /CheckIntegrity" -Level Info
                Write-Log "If the WIM checks clean, capture $dismLog and the console output for triage - this is likely a script bug." -Level Info
            }
            112 {
                Write-Log "Exit code 112 ('Disk full') means C: ran out of space mid-apply." -Level Warning
                Write-Log "The pre-deploy size check uses the WIM's on-disk size; the applied image expands larger than that." -Level Info
                Write-Log "Recovery: re-run on a larger target disk, or shrink the source by exporting only the needed index." -Level Info
            }
            1168 {
                Write-Log "Exit code 1168 ('Element not found') usually means the WIM or its selected index is corrupted/missing." -Level Warning
                Write-Log "Verify the WIM:  dism /Get-WimInfo /WimFile:""$WimPath"" /CheckIntegrity" -Level Info
            }
            1392 {
                Write-Log "Exit code 1392 ('File or directory is corrupted and unreadable') points at filesystem-level corruption on the WIM source." -Level Warning
                Write-Log "Recovery steps to try:" -Level Info
                Write-Log "  1. Re-copy the WIM to the USB drive - the on-disk copy may have bit-rot" -Level Info
                Write-Log "  2. Run chkdsk on the source partition (from a working OS, not WinPE)" -Level Info
                Write-Log "  3. If the USB itself is failing, swap to a different drive" -Level Info
            }
            default {
                Write-Log "See docs/TROUBLESHOOTING.md ('DISM fails with error code') for the meaning of exit code $($process.ExitCode)." -Level Info
                Write-Log "Check $dismLog for details." -Level Info
            }
        }

        return $false
    } catch {
        Write-Log "Image application error: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Set-BootConfiguration {
    Write-Log "Configuring UEFI boot..." -Level Info

    try {
        # -NoNewWindow (matches dism/diskpart invocations above) so bcdboot's own
        # diagnostic line ("Failure when attempting to copy boot files" or BFSVC
        # text) reaches the console instead of being swallowed by Hidden.
        $process = Start-Process -FilePath 'bcdboot.exe' -ArgumentList 'C:\Windows', '/s', 'S:', '/f', 'UEFI' -Wait -PassThru -NoNewWindow

        if ($process.ExitCode -eq 0) {
            Write-Log "Boot configuration completed" -Level Success
            return $true
        }

        Write-Log "BCDBoot failed with exit code $($process.ExitCode)" -Level Error
        Write-Log "Diagnostics:" -Level Info

        # UEFI boot-manager source presence on the applied image. C:\Windows
        # itself is already checked post-DISM-apply at $verifyPaths, so we only
        # look at the EFI bit here: bcdboot copies bootmgfw.efi from this exact
        # path onto S: - if it's missing, bcdboot fails before touching S:.
        $bootmgfwEfi = 'C:\Windows\Boot\EFI\bootmgfw.efi'
        if (Test-Path $bootmgfwEfi) {
            Write-Log "  $bootmgfwEfi present" -Level Info
        } else {
            Write-Log "  $bootmgfwEfi NOT found - applied image is missing the UEFI boot manager (non-bootable WIM or wrong arch)" -Level Warning
        }

        # S: drive state. Post-diskpart already verifies S: exists, but it can be
        # remounted/lost between then and now (rare but worth surfacing). Also
        # checks free space - the FAT32 EFI partition is 300 MB and a fresh
        # BCD/EFI tree fits in a few MB, so anything under ~30 MB free is a
        # red flag.
        $sVol = Get-PSDrive -Name 'S' -ErrorAction SilentlyContinue
        if ($sVol) {
            $sFreeMB = [math]::Round($sVol.Free / 1MB, 1)
            Write-Log "  S: mounted, free: $sFreeMB MB" -Level Info
            if ($sFreeMB -lt 30) {
                Write-Log "  S: free space looks tight for BCD/EFI files (< 30 MB)" -Level Warning
            }
        } else {
            Write-Log "  S: NOT mounted - re-assign letter S to the EFI partition via diskpart and retry" -Level Warning
        }

        Write-Log "Common causes:" -Level Info
        Write-Log "  1. EFI partition is not letter S: or was reformatted as non-FAT32" -Level Info
        Write-Log "  2. Applied image has no UEFI boot manager (bootmgfw.efi) - re-check the WIM source or arch" -Level Info
        Write-Log "  3. Firmware is in Legacy/CSM mode - this script targets pure UEFI (/f UEFI)" -Level Info
        Write-Log "  4. See bcdboot output above for the exact failure point" -Level Info
        return $false
    } catch {
        Write-Log "Boot configuration error: $($_.Exception.Message)" -Level Error
        return $false
    }
}
#endregion

#region BIOS Configuration (CCTK)
function Invoke-CctkConfig {
    # Pre-deploy BIOS configuration for Dell hardware via CCTK.
    # CCTK is embedded into boot.wim by scripts/build_boot_wim.ps1 -CctkSource.
    # Config files live on the IMAGES data partition at <IMAGES>\cctk\ so a
    # single USB can drive a multi-machine fleet without rebuilding the image.
    #
    # Selection precedence for the config file:
    #   1. <SERVICETAG>.ini (per-machine, matches Win32_BIOS.SerialNumber)
    #   2. <MODEL>.ini      (per-model, alnum-normalized Win32_ComputerSystem.Model)
    #   3. default.ini      (catch-all)
    #   4. none             -> skip CCTK entirely and continue to deploy
    #
    # Any non-zero exit from cctk.exe aborts the deploy - running DISM on a
    # half-configured BIOS is worse than failing loud.

    $cctkExe = $Script:Config.CctkPath
    if (-not (Test-Path $cctkExe)) {
        # CCTK not embedded in this build - nothing to do
        return $true
    }

    $imageDrive = $env:DEPLOY_IMAGE_DRIVE
    if (-not $imageDrive) {
        Write-Log "CCTK embedded but DEPLOY_IMAGE_DRIVE is unset - skipping BIOS config" -Level Warning
        Write-Log "  To apply BIOS config, set DEPLOY_IMAGE_DRIVE or boot via the builder's startnet.cmd" -Level Info
        return $true
    }

    $cctkDir = Join-Path $imageDrive $Script:Config.CctkConfigDir
    if (-not (Test-Path $cctkDir)) {
        Write-Log "No $cctkDir directory found on IMAGES partition - skipping BIOS config" -Level Info
        return $true
    }

    # Resolve per-machine identifiers
    $serviceTag = $null
    $model = $null
    try {
        $serviceTag = (Get-WmiObject -Class Win32_BIOS -ErrorAction Stop).SerialNumber
        if ($serviceTag) { $serviceTag = $serviceTag.Trim() }
    } catch {
        Write-Log "Could not read BIOS serial/service tag: $($_.Exception.Message)" -Level Warning
    }
    try {
        $rawModel = (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop).Model
        if ($rawModel) { $model = ($rawModel -replace '[^A-Za-z0-9]', '').Trim() }
    } catch {
        Write-Log "Could not read computer model: $($_.Exception.Message)" -Level Warning
    }

    $configPath = $null
    $matchReason = $null

    if ($serviceTag) {
        $candidate = Join-Path $cctkDir "$serviceTag.ini"
        if (Test-Path $candidate) {
            $configPath = $candidate
            $matchReason = "service tag $serviceTag"
        }
    }
    if (-not $configPath -and $model) {
        $candidate = Join-Path $cctkDir "$model.ini"
        if (Test-Path $candidate) {
            $configPath = $candidate
            $matchReason = "model $model"
        }
    }
    if (-not $configPath) {
        $candidate = Join-Path $cctkDir 'default.ini'
        if (Test-Path $candidate) {
            $configPath = $candidate
            $matchReason = 'default'
        }
    }

    if (-not $configPath) {
        Write-Log "No CCTK config matched (tag: '$serviceTag', model: '$model') - skipping BIOS config" -Level Info
        return $true
    }

    Write-Banner "APPLYING BIOS CONFIGURATION (CCTK)"
    Write-Log "Config: $configPath  ($matchReason)" -Level Info
    Write-Log "CCTK:   $cctkExe" -Level Info
    Write-Log "Note: BIOS changes activate on next POST (end of deploy reboot)" -Level Info

    try {
        & $cctkExe --infile="$configPath"
        $cctkExit = $LASTEXITCODE
    } catch {
        Write-Log "CCTK invocation failed: $($_.Exception.Message)" -Level Error
        return $false
    }

    if ($cctkExit -ne 0) {
        Write-Log "CCTK returned exit code $cctkExit - aborting deploy" -Level Error
        Write-Log "  Common causes:" -Level Info
        Write-Log "    - Invalid setting name in $configPath" -Level Info
        Write-Log "    - Setup/system password mismatch (add --valsetuppwd=<current> to the config)" -Level Info
        Write-Log "    - HAPI driver not loaded (rebuild boot.wim with -CctkSource pointing at full CCTK tree)" -Level Info
        return $false
    }

    Write-Log "BIOS configuration applied successfully" -Level Success
    return $true
}
#endregion

#region Additional-Disk Wipe
function Select-AdditionalWipeDisks {
    param(
        [Parameter(Mandatory)] [array]$AllDisks,
        [Parameter(Mandatory)] $TargetDisk
    )

    # Candidates: every enumerated disk other than the primary target.
    # Get-SystemDisks already excludes USB and removable media.
    $candidates = @($AllDisks | Where-Object { $_.Number -ne $TargetDisk.Number })
    if ($candidates.Count -eq 0) { return @() }

    # Silent path: resolve -WipeDisks without prompting
    if ($Silent) {
        if (-not $WipeDisks) { return @() }
        $nums = @($WipeDisks -split ',' | ForEach-Object { [int]($_.Trim()) })
        $picked = @($candidates | Where-Object { $_.Number -in $nums })
        $missing = $nums | Where-Object { $_ -notin ($picked | ForEach-Object Number) }
        if ($missing) {
            Write-Log "Requested extra wipe disks $($missing -join ',') are not valid non-target disks - aborting" -Level Error
            return $null
        }
        foreach ($d in $picked) {
            Write-Log "Silent mode: queuing disk $($d.Number) ($($d.Model)) for additional wipe" -Level Warning
        }
        return $picked
    }

    # Interactive path
    Write-Banner "OPTIONAL: WIPE ADDITIONAL DISKS"
    Write-Log "Target disk $($TargetDisk.Number) will be wiped and partitioned (already confirmed)." -Level Info
    Write-Log "Other disks below can optionally be CLEANED ONLY (no repartitioning) in the same run." -Level Info
    Write-Log "Useful for secondary drives, vendor OEM partitions that appear after first boot, etc." -Level Info
    Write-Host ""

    foreach ($d in $candidates) {
        $marker = if ($d.HasPartitions) { '[HAS DATA - WILL BE ERASED!]' } else { '[empty]' }
        $color = if ($d.HasPartitions) { $Script:Colors.Warning } else { $Script:Colors.Info }
        Write-Host ("  Disk {0,2}: {1,-40} {2,7:N1} GB  {3}" -f $d.Number, $d.Model, $d.Size, $marker) -ForegroundColor $color
    }
    Write-Host ""
    Write-Log "Enter comma-separated disk numbers to ALSO wipe (e.g. '1,2'), or press Enter to skip" -Level Prompt
    $response = Read-Host

    if ([string]::IsNullOrWhiteSpace($response)) {
        Write-Log "No additional disks selected - only disk $($TargetDisk.Number) will be touched" -Level Info
        return @()
    }

    $requested = @($response -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $picked = @()
    foreach ($tok in $requested) {
        if ($tok -notmatch '^\d+$') {
            Write-Log "Ignoring invalid disk number '$tok'" -Level Warning
            continue
        }
        $num = [int]$tok
        $match = $candidates | Where-Object { $_.Number -eq $num } | Select-Object -First 1
        if (-not $match) {
            Write-Log "Disk $num is not a valid additional-wipe target (either the primary target, USB, or unknown) - skipping" -Level Warning
            continue
        }
        if ($picked | Where-Object { $_.Number -eq $num }) { continue }
        $picked += $match
    }

    if ($picked.Count -eq 0) {
        Write-Log "No valid additional disks selected - continuing with primary target only" -Level Info
        return @()
    }

    # Single WIPE ALL confirmation for the whole set (streamlined, per design).
    Write-Host ""
    Write-Log "The following disks will be cleaned in addition to disk $($TargetDisk.Number):" -Level Warning
    foreach ($d in $picked) {
        Write-Log ("  Disk {0}: {1}  ({2:N1} GB)" -f $d.Number, $d.Model, $d.Size) -Level Warning
    }
    Write-Host ""

    if ($Force) {
        Write-Log "Force flag set - skipping WIPE ALL confirmation" -Level Warning
        return $picked
    }

    Write-Log "Type 'WIPE ALL' to confirm, or anything else to cancel additional wipes" -Level Prompt
    $confirm = Read-Host
    if ($confirm -ne 'WIPE ALL') {
        Write-Log "Additional wipe cancelled - only disk $($TargetDisk.Number) will be touched" -Level Info
        return @()
    }
    return $picked
}
#endregion

#region Main Process
function Initialize-BitLockerSetup {
    if ($Script:Config.DataDiskNumber -lt 0) { return $true }

    Write-Log "Staging BitLocker setup script for first boot..." -Level Info

    $scriptsDir = 'C:\Windows\Setup\Scripts'
    if (-not (Test-Path $scriptsDir)) {
        New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
    }

    # Escape the PIN for embedding in a here-string (single-quoted PS string — only ' needs doubling)
    $escapedPin = $Script:Config.BitLockerPin -replace "'", "''"

    $bitlockerScript = @"
`$ErrorActionPreference = 'Continue'
`$log = 'C:\Windows\Setup\Scripts\bitlocker-setup.log'
function Write-BL { param([string]`$m) `$ts = Get-Date -Format 'HH:mm:ss'; "`$ts  `$m" | Tee-Object -FilePath `$log -Append | Out-Null; Write-Host `$m }

Write-BL 'BitLocker setup starting'

# Enhanced PIN requires this policy key (allows non-numeric characters in startup PIN)
`$fvePath = 'HKLM:\SOFTWARE\Policies\Microsoft\FVE'
if (-not (Test-Path `$fvePath)) { New-Item -Path `$fvePath -Force | Out-Null }
Set-ItemProperty -Path `$fvePath -Name 'UseEnhancedPin' -Value 1 -Type DWord -Force

`$recoveryDir = 'D:\BitLocker'
if (-not (Test-Path `$recoveryDir)) { New-Item -ItemType Directory -Path `$recoveryDir -Force | Out-Null }

`$pin = ConvertTo-SecureString '$escapedPin' -AsPlainText -Force

# C: — TPM + Enhanced PIN primary protector
try {
    Enable-BitLocker -MountPoint 'C:' -EncryptionMethod XtsAes256 -TpmAndPinProtector -Pin `$pin -ErrorAction Stop | Out-Null
    Write-BL 'C: TPM+PIN protector set'
} catch {
    Write-BL "ERROR enabling C: BitLocker: `$(`$_.Exception.Message)"
    exit 1
}

# C: — recovery key backup protector
try {
    Add-BitLockerKeyProtector -MountPoint 'C:' -RecoveryKeyProtector -RecoveryKeyPath `$recoveryDir -ErrorAction Stop | Out-Null
    Write-BL "C: recovery key saved to `$recoveryDir"
} catch {
    Write-BL "WARNING: C: recovery key protector failed: `$(`$_.Exception.Message)"
}

# D: — recovery key protector
try {
    Enable-BitLocker -MountPoint 'D:' -EncryptionMethod XtsAes256 -RecoveryKeyProtector -RecoveryKeyPath `$recoveryDir -ErrorAction Stop | Out-Null
    Write-BL "D: recovery key saved to `$recoveryDir"
} catch {
    Write-BL "ERROR enabling D: BitLocker: `$(`$_.Exception.Message)"
}

# D: — auto-unlock tied to C:
try {
    Enable-BitLockerAutoUnlock -MountPoint 'D:' -ErrorAction Stop | Out-Null
    Write-BL 'D: auto-unlock enabled'
} catch {
    Write-BL "WARNING: D: auto-unlock failed: `$(`$_.Exception.Message)"
}

Write-BL 'BitLocker setup complete - rebooting'
shutdown.exe /r /t 15 /c 'BitLocker configured. Rebooting to finalise...'
"@

    $setupCompleteCmd = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\bitlocker-setup.ps1" >> "C:\Windows\Setup\Scripts\setupcomplete.log" 2>&1
"@

    try {
        Set-Content -Path "$scriptsDir\bitlocker-setup.ps1" -Value $bitlockerScript -Encoding UTF8 -Force
        Set-Content -Path "$scriptsDir\SetupComplete.cmd"   -Value $setupCompleteCmd -Encoding ASCII -Force
        Write-Log "BitLocker setup staged: $scriptsDir\bitlocker-setup.ps1" -Level Success
        Write-Log "SetupComplete.cmd staged: $scriptsDir\SetupComplete.cmd" -Level Success
        return $true
    } catch {
        Write-Log "Failed to stage BitLocker setup: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Start-Deployment {
    Write-Banner "UNIVERSAL WINDOWS IMAGE DEPLOYMENT TOOL v$($Script:Config.ScriptVersion)"

    # Administrator check
    if (-not (Test-Administrator)) {
        Write-Log "This script must be run as Administrator" -Level Error
        return $false
    }

    # Initialize system
    Initialize-SystemPaths

    # Silent mode is intended for unattended runs and must not trigger prompts
    if ($Silent -and -not $ListOnly) {
        if (-not $WimFile) {
            Write-Log "Silent mode requires -WimFile to avoid interactive image selection" -Level Error
            return $false
        }
        if ($TargetDisk -lt 0) {
            Write-Log "Silent mode requires -TargetDisk to avoid interactive disk selection" -Level Error
            return $false
        }
        if (-not $Force) {
            Write-Log "Silent mode requires -Force to avoid interactive final confirmation" -Level Error
            return $false
        }
        if ($WipeDisks -and $WipeDisks -notmatch '^\s*\d+(\s*,\s*\d+)*\s*$') {
            Write-Log "-WipeDisks must be comma-separated disk numbers (e.g. '1,2') - got '$WipeDisks'" -Level Error
            return $false
        }
    }

    # Validate -UnattendFile if provided (fail before anything destructive happens).
    # Well-formedness check matches the manual sanity check in docs/UNATTEND.md
    # section 6: Windows Setup silently ignores a malformed unattend.xml and
    # falls through to manual OOBE, so failing here saves the operator a wipe
    # and re-deploy when they discover OOBE prompted them on first boot.
    if ($UnattendFile) {
        if (-not (Test-Path $UnattendFile -PathType Leaf)) {
            Write-Log "UnattendFile not found: $UnattendFile" -Level Error
            return $false
        }
        try {
            [xml](Get-Content -Path $UnattendFile -Raw) | Out-Null
        } catch {
            Write-Log "UnattendFile is not well-formed XML: $UnattendFile" -Level Error
            Write-Log "  Parse error: $($_.Exception.Message)" -Level Error
            Write-Log "  Windows Setup silently ignores a malformed unattend.xml and falls through to manual OOBE." -Level Error
            Write-Log "  Sanity-check manually: [xml](Get-Content '$UnattendFile')  (see docs/UNATTEND.md section 6)" -Level Info
            return $false
        }
        Write-Log "Unattend file: $UnattendFile" -Level Info
    }

    # Find and select image
    $imageFiles = Find-ImageFiles

    # List only mode - show images and exit
    if ($ListOnly) {
        Show-ImageList -Images $imageFiles
        if ($imageFiles.Count -eq 0) {
            Write-Log "ListOnly mode found no deployable images" -Level Error
            return $false
        }
        return $true
    }

    $selectedImage = Show-ImageSelection -Images $imageFiles

    if (-not $selectedImage) {
        Write-Log "No image selected" -Level Warning
        return $false
    }

    # Select WIM index (edition)
    $wimIndexes = Get-WimImageInfo -WimPath $selectedImage.Path
    $imageIndex = Select-ImageIndex -WimPath $selectedImage.Path -Indexes $wimIndexes
    if (-not $imageIndex) {
        Write-Log "No image index selected" -Level Warning
        return $false
    }

    # Validate environment
    if (-not (Test-WinPEEnvironment)) { return $false }
    if (-not (Test-SystemMemory)) { return $false }

    # Apply BIOS configuration (Dell CCTK) before any destructive disk work.
    # A CCTK failure here aborts the deploy - half-configured BIOS is worse
    # than failing loud. No-op if CCTK isn't embedded in the image.
    if (-not (Invoke-CctkConfig)) { return $false }

    # Get target disk
    $disks = Get-SystemDisks
    $targetDisk = Select-TargetDisk -Disks $disks
    if (-not $targetDisk) { return $false }

    # Optional: additional disks to wipe (secondary drives, vendor OEM partitions)
    $extraWipeDisks = Select-AdditionalWipeDisks -AllDisks $disks -TargetDisk $targetDisk
    if ($null -eq $extraWipeDisks) { return $false }

    Write-Banner "STARTING IMAGE DEPLOYMENT"
    Write-Log "Image: $($selectedImage.Name)" -Level Info
    Write-Log "Target: Disk $($targetDisk.Number) - $($targetDisk.Model)" -Level Info

    # Validate disk size using uncompressed image size when available
    $estimatedSizeGB = [Math]::Round($selectedImage.Size / 1GB, 2)
    $sizeSource = "compressed WIM ~3x"
    # Use uncompressed size from DISM if available for the selected index
    $selectedWimInfo = $wimIndexes | Where-Object { $_.Index -eq $imageIndex } | Select-Object -First 1
    $usedUncompressed = $false
    if ($selectedWimInfo -and $selectedWimInfo.Size) {
        try {
            # Parse DISM size strings like "14,632,927,856 bytes" or "14 632 927 856"
            $sizeStr = $selectedWimInfo.Size -replace '[^\d]', ''
            if ($sizeStr) {
                $uncompressedGB = [Math]::Round([double]$sizeStr / 1GB, 2)
                if ($uncompressedGB -gt $estimatedSizeGB) {
                    $estimatedSizeGB = $uncompressedGB
                    $sizeSource = "uncompressed"
                    $usedUncompressed = $true
                }
            }
        } catch {
            Write-Log "Could not parse uncompressed size - using compressed WIM size with safety multiplier" -Level Warning
        }
    }
    # Apply 3x safety multiplier when using compressed size (WIM compression ratio is typically 2.5-4x)
    if (-not $usedUncompressed) {
        $estimatedSizeGB = [Math]::Round($estimatedSizeGB * 3, 2)
    }
    # EFI 300MB + MSR 16MB + overhead ~1.5GB
    $minRequiredGB = $estimatedSizeGB + 1.5
    if ($targetDisk.Size -lt $minRequiredGB) {
        Write-Log "Target disk too small! Disk: $($targetDisk.Size) GB, Image needs ~$minRequiredGB GB minimum ($sizeSource)" -Level Error
        return $false
    }
    Write-Log "Disk size check passed: $($targetDisk.Size) GB available, ~$estimatedSizeGB GB image ($sizeSource)" -Level Success

    # Partition disk (plus any requested additional disk cleans)
    if (-not (New-DiskpartScript -DiskNumber $targetDisk.Number -ExtraWipeDisks $extraWipeDisks)) { return $false }
    if (-not (Invoke-Diskpart)) { return $false }

    # Verify diskpart created expected drive letters (retry for slow PnP mount manager)
    # In WinPE, C:\ is not the system drive (X: is), so stale C:\ from a prior run is unlikely
    $maxRetries = 3
    $verified = $false
    for ($retry = 1; $retry -le $maxRetries; $retry++) {
        Start-Sleep -Seconds 2
        $needD = $Script:Config.DataDiskNumber -ge 0
        if ((Test-Path 'S:\') -and (Test-Path 'C:\') -and (-not $needD -or (Test-Path 'D:\'))) {
            $verified = $true
            break
        }
        Write-Log "Waiting for drive letters to appear (attempt $retry/$maxRetries)..." -Level Warning
    }
    if (-not $verified) {
        if (-not (Test-Path 'S:\')) {
            Write-Log "Diskpart completed but S: (EFI partition) is not available" -Level Error
        }
        if (-not (Test-Path 'C:\')) {
            Write-Log "Diskpart completed but C: (Windows partition) is not available" -Level Error
        }
        if ($Script:Config.DataDiskNumber -ge 0 -and -not (Test-Path 'D:\')) {
            Write-Log "Diskpart completed but D: (data disk $($Script:Config.DataDiskNumber)) is not available" -Level Error
        }
        Write-Log "Try: mountvol S: /d and mountvol C: /d to free letters, then re-run" -Level Info
        return $false
    }
    Write-Log "Partition verification passed: S: and C: available" -Level Success

    # Apply image
    if (-not (Apply-WindowsImage -WimPath $selectedImage.Path -TargetPath 'C:\' -ImageIndex $imageIndex)) {
        Write-Log "IMAGE APPLICATION FAILED - RECOVERY GUIDANCE:" -Level Error
        Write-Log "  The target disk has been partitioned but no image was applied." -Level Warning
        Write-Log "  Options:" -Level Info
        Write-Log "    1. Re-run this script to try again (disk will be re-partitioned)" -Level Info
        Write-Log "    2. Manually run: dism /apply-image /imagefile:`"$($selectedImage.Path)`" /index:$imageIndex /applydir:C:\" -Level Info
        Write-Log "    3. Check the image file is not corrupted" -Level Info
        Write-Log "    4. Verify system has 8+ GB RAM (DISM can fail with insufficient memory)" -Level Info
        return $false
    }

    # Post-deployment verification
    Write-Log "Verifying deployment..." -Level Info
    $verifyPaths = @('C:\Windows', 'C:\Windows\System32')
    foreach ($vPath in $verifyPaths) {
        if (-not (Test-Path $vPath)) {
            Write-Log "Verification FAILED: $vPath not found after image apply" -Level Error
            Write-Log "The image may be corrupted or incompatible. Try a different WIM index or image file." -Level Warning
            return $false
        }
    }
    Write-Log "Deployment verification passed" -Level Success

    # Drop unattend.xml so Windows Setup picks it up on first boot
    if ($UnattendFile) {
        $pantherDir = 'C:\Windows\Panther'
        if (-not (Test-Path $pantherDir)) {
            New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null
        }
        Copy-Item -Path $UnattendFile -Destination "$pantherDir\unattend.xml" -Force
        Write-Log "Unattend file staged: $pantherDir\unattend.xml" -Level Success
    }

    # Stage BitLocker setup script (runs on first Windows boot via SetupComplete.cmd)
    if (-not (Initialize-BitLockerSetup)) { return $false }

    # Configure boot
    if (-not (Set-BootConfiguration)) {
        Write-Log "BOOT CONFIGURATION FAILED - RECOVERY GUIDANCE:" -Level Error
        Write-Log "  Windows files are on C:\ but boot is not configured." -Level Warning
        Write-Log '  Manually run: bcdboot C:\Windows /s S: /f UEFI' -Level Info
        return $false
    }

    # Cleanup
    try {
        Remove-Item -Path $Script:SystemPaths.DiskpartScript -Force -ErrorAction SilentlyContinue
    } catch {}

    # Success
    Write-Banner "DEPLOYMENT COMPLETED SUCCESSFULLY"
    Write-Log "Windows image has been deployed and is ready for first boot" -Level Success

    if (-not $Silent) {
        $result = Show-MessageBox -Message "Deployment completed successfully!`n`nShutdown the system now?" -Title "Success" -Buttons "YesNo" -Icon "Information"
        if ($result -eq 'Yes') {
            Write-Log "Shutting down system..." -Level Info
            & shutdown.exe /s /t 5 /c "WinPE deployment complete"
        }
    }

    return $true
}
#endregion

# Execute main process
try {
    $success = Start-Deployment
    if (-not $success) {
        # Surface log path so the operator doesn't have to scroll past a long
        # DISM/diskpart trace to find it
        if ($Script:SystemPaths.LogFile) {
            Write-Log "Full log: $($Script:SystemPaths.LogFile)" -Level Info
        }
        exit 1
    }
} catch {
    Write-Log "Critical error: $($_.Exception.Message)" -Level Error
    if ($Script:SystemPaths.LogFile) {
        Write-Log "Full log: $($Script:SystemPaths.LogFile)" -Level Info
    }
    if (-not $Silent) {
        Read-Host "Press Enter to exit"
    }
    exit 1
} finally {
    # Always clean up diskpart script (even on failure)
    if ($Script:SystemPaths.DiskpartScript -and (Test-Path $Script:SystemPaths.DiskpartScript -ErrorAction SilentlyContinue)) {
        Remove-Item -Path $Script:SystemPaths.DiskpartScript -Force -ErrorAction SilentlyContinue
    }
}
