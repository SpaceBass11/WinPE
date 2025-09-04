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
    4.0 - Generic Universal Version
#>

[CmdletBinding()]
param(
    [string]$ImagePath,
    [string]$WimFile,
    [int]$TargetDisk = -1,
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
    ScriptVersion = '4.0'
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
        return 'OK'
    }
    
    try {
        $buttonType = [System.Windows.Forms.MessageBoxButtons]::$Buttons
        $iconType = [System.Windows.Forms.MessageBoxIcon]::$Icon
        return [System.Windows.Forms.MessageBox]::Show($Message, $Title, $buttonType, $iconType)
    } catch {
        Write-Log $Message -Level Warning
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
    $tempCandidates = @($env:TEMP, 'X:\Windows\Temp', 'C:\Temp', 'X:\Temp')
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
    
    Write-Log "Script directory: $($Script:SystemPaths.ScriptDir)" -Level Success
    Write-Log "Temp directory: $($Script:SystemPaths.TempDir)" -Level Success
}

function Find-ImageFiles {
    Write-Log "Searching for Windows image files..." -Level Info
    
    # If specific WIM file provided, use it
    if ($WimFile) {
        if (Test-Path $WimFile) {
            Write-Log "Using specified WIM file: $WimFile" -Level Success
            return @(@{
                Path = $WimFile
                Name = Split-Path -Leaf $WimFile
                Size = (Get-Item $WimFile).Length
                Type = 'Specified'
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
    Write-Host ("="*100) -ForegroundColor $Script:Colors.Header
    Write-Host "AVAILABLE WINDOWS IMAGE FILES".PadLeft(60) -ForegroundColor $Script:Colors.Header
    Write-Host ("="*100) -ForegroundColor $Script:Colors.Header
    
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
    Write-Host ("="*100) -ForegroundColor $Script:Colors.Header
    
    if ($ListOnly) {
        return $null
    }
    
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
    } else {
        Write-Log "Warning: May not be running in WinPE environment" -Level Warning
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
        if ($selectedDisk) {
            Write-Log "Using specified target disk: $TargetDisk" -Level Success
            return $selectedDisk
        } else {
            Write-Log "Specified target disk $TargetDisk not found" -Level Error
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

#region Image Deployment
function New-DiskpartScript {
    param([int]$DiskNumber)
    
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
        $process = Start-Process -FilePath 'dism.exe' -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
        
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
    $selectedImage = Show-ImageSelection -Images $imageFiles
    
    if (-not $selectedImage) {
        Write-Log "No image selected" -Level Warning
        return $false
    }
    
    # List only mode
    if ($ListOnly) {
        return $true
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
    
    # Partition disk
    if (-not (New-DiskpartScript -DiskNumber $targetDisk.Number)) { return $false }
    if (-not (Invoke-Diskpart)) { return $false }
    
    # Apply image
    if (-not (Apply-WindowsImage -WimPath $selectedImage.Path -TargetPath 'C:\')) { return $false }
    
    # Configure boot
    if (-not (Set-BootConfiguration)) { return $false }
    
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
            Stop-Computer -Force
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
