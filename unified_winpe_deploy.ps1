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
.VERSION
    4.2 - Hardened Universal Version
#>

[CmdletBinding()]
param(
    [string]$ImagePath,
    [string]$WimFile,
    [int]$TargetDisk = -1,
    [switch]$Force,
    [switch]$Silent,
    [switch]$ListOnly
)

# Load required assemblies
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    Write-Warning "Could not load Windows Forms - dialog boxes will not be available"
}

#region Configuration
$Script:Config = @{
    MinimumMemoryGB = 8
    ScriptVersion = '4.2'
    DiskpartScriptName = 'deploy_diskpart.txt'
    SearchPaths = @('images', 'wim', 'deploy', 'windows', 'os')
    ImageExtensions = @('*.wim', '*.esd')
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
            Add-Content -Path $Script:SystemPaths.LogFile -Value "[$logTimestamp] [$Level] $Message" -ErrorAction SilentlyContinue
        } catch { }
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
        $Script:SystemPaths.ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
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
    }
    
    # Set diskpart script path
    $Script:SystemPaths.DiskpartScript = Join-Path $Script:SystemPaths.TempDir $Script:Config.DiskpartScriptName

    # Initialize log file
    $logName = "deploy_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $Script:SystemPaths.LogFile = Join-Path $Script:SystemPaths.TempDir $logName

    Write-Log "Script directory: $($Script:SystemPaths.ScriptDir)" -Level Success
    Write-Log "Temp directory: $($Script:SystemPaths.TempDir)" -Level Success
    Write-Log "Log file: $($Script:SystemPaths.LogFile)" -Level Info
}

function Find-ImageFiles {
    Write-Log "Searching for Windows image files..." -Level Info
    
    # If specific WIM file provided, use it
    if ($WimFile) {
        if (Test-Path $WimFile) {
            Write-Log "Using specified WIM file: $WimFile" -Level Success
            $item = Get-Item $WimFile
            return @(@{
                Path = $WimFile
                Name = Split-Path -Leaf $WimFile
                Size = $item.Length
                Type = 'Specified'
                LastModified = $item.LastWriteTime
            })
        } else {
            Write-Log "Specified WIM file not found: $WimFile" -Level Error
            return @()
        }
    }
    
    # If specific image path provided, search there
    if ($ImagePath -and (Test-Path $ImagePath)) {
        return Search-DirectoryForImages -Path $ImagePath -Source "Specified path"
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
            $rootImages = Search-DirectoryForImages -Path $driveLetter -Source "Drive $driveLetter (root)" -Recurse:$false
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
                # Skip tiny files (likely not real images)
                if ($file.Length -gt 100MB) {
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
    $computerName = $env:COMPUTERNAME
    $isWinPE = ($env:SystemDrive -eq 'X:') -or (Test-Path 'X:\Windows') -or ($computerName -match 'PE$')

    if ($isWinPE) {
        Write-Log "WinPE environment detected: $computerName" -Level Success
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
        $wmiDisks = Get-WmiObject -Class Win32_DiskDrive -ErrorAction Stop | Where-Object { 
            $_.MediaType -like "*fixed*" -and $_.InterfaceType -ne 'USB' 
        }
        
        foreach ($wmiDisk in $wmiDisks) {
            $diskNumber = $wmiDisk.Index
            $sizeGB = if ($wmiDisk.Size) { [Math]::Round([double]$wmiDisk.Size / 1GB, 2) } else { 0 }
            
            # Get partitions
            $partitions = @(Get-WmiObject -Class Win32_DiskPartition -ErrorAction SilentlyContinue | Where-Object { $_.DiskIndex -eq $diskNumber })
            $hasPartitions = $partitions.Count -gt 0
            
            $partitionInfo = if ($hasPartitions) {
                ($partitions | ForEach-Object { "Part$($_.Index):$([Math]::Round([double]$_.Size/1GB,1))GB" }) -join ", "
            } else {
                "No partitions"
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
            
            # Basic system disk detection
            if ($diskNumber -eq 0 -and $env:SystemDrive -ne 'X:') {
                $disk.IsSystemDisk = $true
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
        } elseif ($Force) {
            # -Force skips DELETE ALL DATA but NEVER skips system disk protection
            if ($selectedDisk.IsSystemDisk) {
                Write-Log "DANGER: -Force cannot bypass system disk protection!" -Level Error
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
            Write-Host ""
            $finalConfirm = Read-Host "Type 'DELETE ALL DATA' to proceed with Disk $TargetDisk"
            if ($finalConfirm -eq 'DELETE ALL DATA') {
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
            $finalConfirm = Read-Host "Type 'DELETE ALL DATA' to proceed"
            
            if ($finalConfirm -eq 'DELETE ALL DATA') {
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
        Write-Log "Could not enumerate WIM indexes - defaulting to index 1" -Level Warning
        return 1
    }

    if ($Indexes.Count -eq 1) {
        Write-Log "Single image index: $($Indexes[0].Name)" -Level Success
        return $Indexes[0].Index
    }

    Write-Host ""
    Write-Host ("="*80) -ForegroundColor $Script:Colors.Header
    Write-Host "AVAILABLE WINDOWS EDITIONS".PadLeft(50) -ForegroundColor $Script:Colors.Header
    Write-Host ("="*80) -ForegroundColor $Script:Colors.Header

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
        $choice = Read-Host "Select edition (1-$($Indexes.Count)) or 'q' to quit"

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
    param([int]$DiskNumber)
    
    # Free up S: and C: drive letters if already assigned to avoid diskpart conflicts
    $lettersToFree = @('S', 'C')
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
            } catch {
                Write-Log "Could not release $($letter): - diskpart will attempt to reassign" -Level Warning
            }
        }
    }

    $commands = @"
select disk $DiskNumber
clean
convert gpt
create partition efi size=300
format quick fs=fat32 label=System
assign letter S
create partition msr size=16
create partition primary
format quick fs=ntfs label=Windows
assign letter C
exit
"@
    
    try {
        Set-Content -Path $Script:SystemPaths.DiskpartScript -Value $commands -Force
        Write-Log "Diskpart script created" -Level Success
        return $true
    } catch {
        Write-Log "Failed to create diskpart script: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Invoke-Diskpart {
    Write-Log "Partitioning disk - this may take a moment..." -Level Warning
    
    try {
        $process = Start-Process -FilePath 'diskpart.exe' -ArgumentList "/s `"$($Script:SystemPaths.DiskpartScript)`"" -Wait -PassThru -WindowStyle Hidden
        
        if ($process.ExitCode -eq 0) {
            Write-Log "Disk partitioning completed" -Level Success
            return $true
        } else {
            Write-Log "Diskpart failed with exit code $($process.ExitCode)" -Level Error
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
        $arguments = @('/apply-image', "/imagefile:`"$WimPath`"", "/index:$ImageIndex", "/applydir:`"$TargetPath`"")
        $process = Start-Process -FilePath 'dism.exe' -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -eq 0) {
            Write-Log "Windows image applied successfully" -Level Success
            return $true
        } else {
            Write-Log "DISM failed with exit code $($process.ExitCode)" -Level Error
            return $false
        }
    } catch {
        Write-Log "Image application error: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Set-BootConfiguration {
    Write-Log "Configuring UEFI boot..." -Level Info
    
    try {
        $process = Start-Process -FilePath 'bcdboot.exe' -ArgumentList 'C:\Windows', '/s', 'S:', '/f', 'UEFI' -Wait -PassThru -WindowStyle Hidden
        
        if ($process.ExitCode -eq 0) {
            Write-Log "Boot configuration completed" -Level Success
            return $true
        } else {
            Write-Log "BCDBoot failed with exit code $($process.ExitCode)" -Level Error
            return $false
        }
    } catch {
        Write-Log "Boot configuration error: $($_.Exception.Message)" -Level Error
        return $false
    }
}
#endregion

#region Main Process
function Start-Deployment {
    Write-Banner "UNIVERSAL WINDOWS IMAGE DEPLOYMENT TOOL v$($Script:Config.ScriptVersion)"
    
    # Administrator check
    if (-not (Test-Administrator)) {
        Write-Log "This script must be run as Administrator" -Level Error
        return $false
    }
    
    # Initialize system
    Initialize-SystemPaths
    
    # Find and select image
    $imageFiles = Find-ImageFiles

    # List only mode - show images and exit
    if ($ListOnly) {
        Show-ImageSelection -Images $imageFiles | Out-Null
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
    
    # Get target disk
    $disks = Get-SystemDisks
    $targetDisk = Select-TargetDisk -Disks $disks
    if (-not $targetDisk) { return $false }
    
    Write-Banner "STARTING IMAGE DEPLOYMENT"
    Write-Log "Image: $($selectedImage.Name)" -Level Info
    Write-Log "Target: Disk $($targetDisk.Number) - $($targetDisk.Model)" -Level Info

    # Validate disk size (EFI 300MB + MSR 16MB + overhead ~1GB minimum beyond image)
    $imageSizeGB = [Math]::Round($selectedImage.Size / 1GB, 2)
    $minRequiredGB = $imageSizeGB + 1.5
    if ($targetDisk.Size -lt $minRequiredGB) {
        Write-Log "Target disk too small! Disk: $($targetDisk.Size) GB, Image needs ~$minRequiredGB GB minimum" -Level Error
        return $false
    }
    Write-Log "Disk size check passed: $($targetDisk.Size) GB available, ~$imageSizeGB GB image" -Level Success

    # Partition disk
    if (-not (New-DiskpartScript -DiskNumber $targetDisk.Number)) { return $false }
    if (-not (Invoke-Diskpart)) { return $false }

    # Verify diskpart created expected drive letters
    Start-Sleep -Seconds 2  # Brief pause for PnP mount manager
    if (-not (Test-Path 'S:\')) {
        Write-Log "Diskpart completed but S: (EFI partition) is not available" -Level Error
        return $false
    }
    if (-not (Test-Path 'C:\')) {
        Write-Log "Diskpart completed but C: (Windows partition) is not available" -Level Error
        return $false
    }
    Write-Log "Partition verification passed: S: and C: available" -Level Success

    # Apply image
    if (-not (Apply-WindowsImage -WimPath $selectedImage.Path -TargetPath 'C:\' -ImageIndex $imageIndex)) {
        Write-Log "" -Level Error
        Write-Log "IMAGE APPLICATION FAILED - RECOVERY GUIDANCE:" -Level Error
        Write-Log "  The target disk has been partitioned but no image was applied." -Level Warning
        Write-Log "  Options:" -Level Info
        Write-Log "    1. Re-run this script to try again (disk will be re-partitioned)" -Level Info
        Write-Log "    2. Manually run: dism /apply-image /imagefile:`"$($selectedImage.Path)`" /index:$imageIndex /applydir:C:\" -Level Info
        Write-Log "    3. Check the image file is not corrupted" -Level Info
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

    # Configure boot
    if (-not (Set-BootConfiguration)) {
        Write-Log "" -Level Error
        Write-Log "BOOT CONFIGURATION FAILED - RECOVERY GUIDANCE:" -Level Error
        Write-Log "  Windows files are on C:\\ but boot is not configured." -Level Warning
        Write-Log "  Manually run: bcdboot C:\\Windows /s S: /f UEFI" -Level Info
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
        exit 1
    }
} catch {
    Write-Log "Critical error: $($_.Exception.Message)" -Level Error
    if (-not $Silent) {
        Read-Host "Press Enter to exit"
    }
    exit 1
}
