#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Advanced WinPE Image Deployment Tool with Interactive Disk Selection
.DESCRIPTION
    Safely deploys Windows images to target disks with comprehensive validation,
    interactive disk selection, and progress monitoring.
.AUTHOR
    Enhanced Image Deployment Script
.VERSION
    2.0
#>

Add-Type -AssemblyName PresentationCore, PresentationFramework, System.Windows.Forms

# Configuration
$Config = @{
    MinimumMemoryGB = 16
    RequiredEnvironment = 'Win10XPE'
    DiskpartScript = 'Uefi_Diskpart.txt'
    NotificationSound = 'Windows\Media\Windows Notify System Generic.wav'
}

# Color scheme for consistent output
$Colors = @{
    Success = 'Green'
    Warning = 'Yellow' 
    Error = 'Red'
    Info = 'Cyan'
    Prompt = 'White'
}

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('Success','Warning','Error','Info','Prompt')]$Type = 'Info'
    )
    Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Message" -ForegroundColor $Colors[$Type]
}

function Test-WinPEEnvironment {
    if ($env:COMPUTERNAME -ne $Config.RequiredEnvironment) {
        Write-Status "Not running in WinPE environment (Expected: $($Config.RequiredEnvironment), Found: $env:COMPUTERNAME)" -Type Error
        return $false
    }
    Write-Status "WinPE environment verified" -Type Success
    return $true
}

function Test-SystemMemory {
    $totalMemoryGB = [Math]::Round(((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB), 2)
    $chassisTypes = (Get-CimInstance -ClassName Win32_SystemEnclosure).ChassisTypes
    $isLaptop = $chassisTypes -contains 9 -or $chassisTypes -contains 10
    
    Write-Status "Total Physical Memory: $totalMemoryGB GB" -Type Info
    Write-Status "Chassis Type: $(if($isLaptop){'Laptop/Notebook'}else{'Desktop/Server'})" -Type Info
    
    if ($isLaptop -and $totalMemoryGB -lt $Config.MinimumMemoryGB) {
        $warningMsg = @"
⚠️  MEMORY WARNING ⚠️

System has $totalMemoryGB GB RAM (Minimum: $($Config.MinimumMemoryGB) GB)

Low memory may cause:
• DISM /Apply-Image to fail or hang
• No error messages during failure
• Incomplete image deployment

Continue anyway?
"@
        
        $result = [System.Windows.MessageBox]::Show(
            $warningMsg,
            'Memory Check - Warning',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        
        if ($result -eq [System.Windows.MessageBoxResult]::No) {
            Write-Status "Operation cancelled by user due to memory warning" -Type Warning
            return $false
        }
        Write-Status "User chose to continue despite memory warning" -Type Warning
    } else {
        Write-Status "Memory check passed" -Type Success
    }
    return $true
}

function Get-AvailableDisks {
    Write-Status "Scanning for available disks..." -Type Info
    
    $disks = Get-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_PhysicalDisk | 
        Where-Object { $_.BusType -ne 7 } |  # Exclude USB (BusType 7)
        ForEach-Object {
            $disk = $_
            $diskNumber = $disk.DeviceId
            $partitions = Get-CimInstance -ClassName Win32_DiskPartition | Where-Object { $_.DiskIndex -eq $diskNumber }
            
            [PSCustomObject]@{
                Number = $diskNumber
                Size = [Math]::Round($disk.Size / 1GB, 2)
                Model = $disk.Model
                MediaType = $disk.MediaType
                BusType = switch($disk.BusType) {
                    0 { "SCSI" }
                    1 { "ATAPI" }
                    2 { "ATA" }
                    3 { "IEEE 1394" }
                    4 { "SSA" }
                    5 { "Fibre Channel" }
                    6 { "USB" }
                    7 { "RAID" }
                    8 { "iSCSI" }
                    9 { "SAS" }
                    10 { "SATA" }
                    11 { "SD" }
                    12 { "MMC" }
                    13 { "Virtual" }
                    14 { "File Backed Virtual" }
                    15 { "Storage Spaces" }
                    16 { "NVMe" }
                    17 { "Microsoft Reserved" }
                    default { "Unknown" }
                }
                HasPartitions = ($partitions | Measure-Object).Count -gt 0
                PartitionInfo = if ($partitions) { 
                    ($partitions | ForEach-Object { "Partition $($_.Index): $([Math]::Round($_.Size/1GB,1))GB" }) -join ", "
                } else { 
                    "No partitions" 
                }
                IsSystemDisk = $false  # We'll determine this later
            }
        }
    
    # Try to identify system disk (where WinPE is running from)
    $systemDrive = $env:SystemDrive.Replace(':', '')
    foreach ($disk in $disks) {
        try {
            $volumes = Get-CimInstance -ClassName Win32_Volume | Where-Object { $_.DriveLetter -eq "$systemDrive`:" }
            if ($volumes) {
                $partition = Get-CimInstance -ClassName Win32_DiskPartition | Where-Object { $_.DeviceID -eq $volumes[0].DeviceID.Split('\')[3] }
                if ($partition -and $partition.DiskIndex -eq $disk.Number) {
                    $disk.IsSystemDisk = $true
                }
            }
        } catch {
            # Ignore errors in system disk detection
        }
    }
    
    return $disks
}

function Show-DiskSelectionMenu {
    param([array]$Disks)
    
    Write-Host "`n" + "="*80 -ForegroundColor $Colors.Info
    Write-Host "                    DISK SELECTION MENU" -ForegroundColor $Colors.Prompt
    Write-Host "="*80 -ForegroundColor $Colors.Info
    
    foreach ($disk in $Disks) {
        $warningText = ""
        $color = $Colors.Info
        
        if ($disk.IsSystemDisk) {
            $warningText = " ⚠️  [SYSTEM DISK - AVOID!]"
            $color = $Colors.Error
        } elseif ($disk.HasPartitions) {
            $warningText = " ⚠️  [HAS DATA - WILL BE WIPED!]"
            $color = $Colors.Warning
        } else {
            $color = $Colors.Success
        }
        
        Write-Host "`nDisk $($disk.Number):$warningText" -ForegroundColor $color
        Write-Host "  Model: $($disk.Model)" -ForegroundColor White
        Write-Host "  Size: $($disk.Size) GB" -ForegroundColor White
        Write-Host "  Type: $($disk.MediaType) ($($disk.BusType))" -ForegroundColor White
        Write-Host "  Partitions: $($disk.PartitionInfo)" -ForegroundColor White
    }
    
    Write-Host "`n" + "="*80 -ForegroundColor $Colors.Info
    Write-Host "⚠️  WARNING: Selected disk will be COMPLETELY WIPED!" -ForegroundColor $Colors.Error
    Write-Host "="*80 -ForegroundColor $Colors.Info
}

function Select-TargetDisk {
    param([array]$Disks)
    
    if ($Disks.Count -eq 0) {
        Write-Status "No suitable disks found for imaging" -Type Error
        return $null
    }
    
    do {
        Show-DiskSelectionMenu -Disks $Disks
        
        $prompt = "`nEnter disk number to image (or 'q' to quit): "
        $selection = Read-Host -Prompt $prompt
        
        if ($selection -eq 'q') {
            Write-Status "Operation cancelled by user" -Type Warning
            return $null
        }
        
        try {
            $diskNumber = [int]$selection
            $selectedDisk = $Disks | Where-Object { $_.Number -eq $diskNumber }
            
            if (-not $selectedDisk) {
                Write-Status "Invalid disk number: $diskNumber" -Type Error
                continue
            }
            
            # Double confirmation for system disk
            if ($selectedDisk.IsSystemDisk) {
                Write-Status "⚠️  You selected the SYSTEM DISK! This will destroy WinPE!" -Type Error
                $confirm = Read-Host "Type 'DESTROY SYSTEM' to confirm (or anything else to cancel)"
                if ($confirm -ne "DESTROY SYSTEM") {
                    Write-Status "System disk selection cancelled" -Type Info
                    continue
                }
            }
            
            # Confirmation for any disk
            $confirmMsg = @"

⚠️  FINAL CONFIRMATION ⚠️

You selected: Disk $($selectedDisk.Number)
Model: $($selectedDisk.Model)
Size: $($selectedDisk.Size) GB
Partitions: $($selectedDisk.PartitionInfo)

This disk will be COMPLETELY WIPED and repartitioned!
All data will be PERMANENTLY LOST!

Type 'WIPE DISK' to confirm:
"@
            
            Write-Host $confirmMsg -ForegroundColor $Colors.Error
            $finalConfirm = Read-Host
            
            if ($finalConfirm -eq "WIPE DISK") {
                Write-Status "Disk $diskNumber confirmed for imaging" -Type Success
                return $selectedDisk
            } else {
                Write-Status "Disk selection cancelled" -Type Info
                continue
            }
            
        } catch {
            Write-Status "Please enter a valid disk number" -Type Error
        }
    } while ($true)
}

function Get-DynamicPaths {
    Write-Status "Discovering system paths..." -Type Info
    
    $paths = @{
        ImagePath = $null
        ScriptPath = $null
        Fat32Drive = $null
        ImageDrive = $null
    }
    
    # Try to use launcher-provided paths first
    if ($env:SAMS_IMAGE_DRIVE) {
        $paths.ImagePath = Join-Path $env:SAMS_IMAGE_DRIVE "images"
        Write-Status "Using launcher-discovered image path: $($paths.ImagePath)" -Type Success
    }
    
    if ($env:SAMS_LAUNCHER_DIR) {
        $paths.ScriptPath = $env:SAMS_LAUNCHER_DIR
        Write-Status "Using launcher directory for scripts: $($paths.ScriptPath)" -Type Success
    }
    
    # Discover FAT32 boot drive
    $fat32Drive = Get-PSDrive | Where-Object { 
        $_.Description -eq 'FAT32BOOT' -or
        ($_.FileSystem -eq 'FAT32' -and (Test-Path (Join-Path $_.Root 'boot')))
    } | Select-Object -First 1
    
    if ($fat32Drive) {
        $paths.Fat32Drive = $fat32Drive.Root.TrimEnd('\')
        $paths.ScriptPath = $paths.ScriptPath ?? (Join-Path $paths.Fat32Drive "scripts")
        Write-Status "Found FAT32 boot drive: $($paths.Fat32Drive)" -Type Success
    }
    
    # Discover image drive if not provided by launcher
    if (-not $paths.ImagePath) {
        # Try SAMS_IMAGES label first
        $imageDrive = Get-PSDrive | Where-Object { $_.Description -eq 'SAMS_IMAGES' } | Select-Object -First 1
        
        if (-not $imageDrive) {
            # Search for drives with SAMS WIM files
            $imageDrive = Get-PSDrive | Where-Object {
                $_.FileSystem -eq 'NTFS' -and 
                (Get-ChildItem -Path $_.Root -Filter 'SAMS*.wim' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
            } | Select-Object -First 1
        }
        
        if ($imageDrive) {
            $paths.ImageDrive = $imageDrive.Root.TrimEnd('\')
            $paths.ImagePath = Join-Path $paths.ImageDrive "images"
            Write-Status "Found image drive: $($paths.ImageDrive)" -Type Success
        }
    }
    
    return $paths
}
    param([string]$BasePath)
    
    Write-Status "Searching for image files in $BasePath..." -Type Info
    
    if (-not (Test-Path -Path $BasePath)) {
        Write-Status "Image path does not exist: $BasePath" -Type Error
        return $null
    }
    
    $efiWim = Get-ChildItem -Path $BasePath -Filter 'SAMS*EFI*.wim' -Recurse | 
              Sort-Object LastWriteTime -Descending | 
              Select-Object -First 1
    
    $osWim = Get-ChildItem -Path $BasePath -Filter 'SAMS*OS*.wim' -Recurse | 
             Sort-Object LastWriteTime -Descending | 
             Select-Object -First 1
    
    if (-not $osWim) {
        Write-Status "No OS WIM file found matching pattern 'SAMS*OS*.wim'" -Type Error
        return $null
    }
    
    $imageFiles = @{
        OSWim = $osWim.FullName
        EFIWim = if ($efiWim) { $efiWim.FullName } else { $null }
    }
    
    Write-Status "Found OS WIM: $($osWim.Name)" -Type Success
    if ($efiWim) {
        Write-Status "Found EFI WIM: $($efiWim.Name)" -Type Success
    } else {
        Write-Status "No EFI WIM found - will use standard boot setup" -Type Warning
    }
    
    return $imageFiles
}

function New-DiskpartScript {
    param(
        [int]$DiskNumber,
        [string]$ScriptPath
    )
    
    $diskpartCommands = @"
select disk $DiskNumber
clean
convert gpt
create partition efi size=100
format quick fs=fat32 label=System
assign letter S
create partition primary
format quick fs=ntfs label=Windows
assign letter C
"@
    
    try {
        $scriptDir = Split-Path -Path $ScriptPath -Parent
        if (-not (Test-Path -Path $scriptDir)) {
            New-Item -Path $scriptDir -ItemType Directory -Force | Out-Null
        }
        
        Set-Content -Path $ScriptPath -Value $diskpartCommands -Force
        Write-Status "Created diskpart script: $ScriptPath" -Type Success
        return $true
    } catch {
        Write-Status "Failed to create diskpart script: $($_.Exception.Message)" -Type Error
        return $false
    }
}

function Invoke-DiskpartScript {
    param([string]$ScriptPath)
    
    Write-Status "Executing diskpart script..." -Type Info
    Write-Status "⚠️  Partitioning disk - this will take a moment..." -Type Warning
    
    try {
        $result = & diskpart.exe /s $ScriptPath 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Status "Disk partitioning completed successfully" -Type Success
            return $true
        } else {
            Write-Status "Diskpart failed with exit code: $LASTEXITCODE" -Type Error
            Write-Status "Diskpart output: $($result -join "`n")" -Type Error
            return $false
        }
    } catch {
        Write-Status "Error running diskpart: $($_.Exception.Message)" -Type Error
        return $false
    }
}

function Apply-WindowsImage {
    param(
        [string]$ImagePath,
        [string]$TargetPath,
        [string]$ImageType = "OS Image"
    )
    
    Write-Status "Applying $ImageType..." -Type Info
    Write-Status "Source: $(Split-Path -Leaf $ImagePath)" -Type Info
    Write-Status "Target: $TargetPath" -Type Info
    Write-Status "⏳ This may take several minutes - please wait..." -Type Warning
    
    try {
        $dismArgs = @('/apply-image', "/imagefile:$ImagePath", '/index:1', "/applydir:$TargetPath")
        $result = & dism.exe $dismArgs 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Status "$ImageType applied successfully" -Type Success
            return $true
        } else {
            Write-Status "DISM failed with exit code: $LASTEXITCODE" -Type Error
            Write-Status "DISM output: $($result -join "`n")" -Type Error
            return $false
        }
    } catch {
        Write-Status "Error applying image: $($_.Exception.Message)" -Type Error
        return $false
    }
}

function Set-UEFIBoot {
    Write-Status "Configuring UEFI boot files..." -Type Info
    
    try {
        $result = & bcdboot.exe C:\Windows /s S: /f UEFI 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Status "UEFI boot configuration completed" -Type Success
            return $true
        } else {
            Write-Status "BCDBoot failed with exit code: $LASTEXITCODE" -Type Error
            Write-Status "BCDBoot output: $($result -join "`n")" -Type Error
            return $false
        }
    } catch {
        Write-Status "Error configuring boot: $($_.Exception.Message)" -Type Error
        return $false
    }
}

function Show-CompletionDialog {
    try {
        # Play notification sound
        $soundLocations = @(
            (Join-Path $systemPaths.Fat32Drive $Config.NotificationSound),
            "C:\$($Config.NotificationSound)",
            (Get-PSDrive | Where-Object { $_.Description -ceq 'Boot' } | ForEach-Object { Join-Path $_.Root $Config.NotificationSound })
        )
        
        $soundPath = $soundLocations | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
        if ($soundPath) {
            $sound = New-Object System.Media.SoundPlayer $soundPath
            $sound.Play()
            $sound.Dispose()
        }
        
        # Minimize all windows
        $shell = New-Object -ComObject Shell.Application
        $shell.MinimizeAll()
        
        $message = @"
✅ IMAGE DEPLOYMENT COMPLETED SUCCESSFULLY! ✅

The Windows image has been applied to the target disk.
The system is ready for first boot.

Would you like to shutdown the system now?
"@
        
        $result = [System.Windows.MessageBox]::Show(
            $message,
            'Imaging Complete',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Information
        )
        
        if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
            Write-Status "Shutting down system..." -Type Info
            & wpeutil.exe shutdown
        } else {
            Write-Status "Imaging complete - system ready for manual restart" -Type Success
        }
    } catch {
        Write-Status "Error in completion dialog: $($_.Exception.Message)" -Type Warning
        Write-Status "Imaging completed successfully" -Type Success
    }
}

function Start-ImageDeployment {
    Write-Host "`n" + "="*80 -ForegroundColor $Colors.Info
    Write-Host "           WINDOWS IMAGE DEPLOYMENT TOOL v2.0" -ForegroundColor $Colors.Prompt
    Write-Host "="*80 -ForegroundColor $Colors.Info
    
    # Environment checks
    if (-not (Test-WinPEEnvironment)) { return }
    if (-not (Test-SystemMemory)) { return }
    
    # Discover system paths dynamically
    $systemPaths = Get-DynamicPaths
    
    if (-not $systemPaths.ImagePath -or -not (Test-Path $systemPaths.ImagePath)) {
        Write-Status "Could not locate images directory. Please ensure:" -Type Error
        Write-Status "- Drive is labeled 'SAMS_IMAGES', OR" -Type Error  
        Write-Status "- Images directory exists with SAMS*.wim files" -Type Error
        return
    }
    
    if (-not $systemPaths.ScriptPath) {
        Write-Status "Could not determine script working directory" -Type Error
        return
    }
    
    $diskpartScriptPath = Join-Path $systemPaths.ScriptPath $Config.DiskpartScript
    
    # Find image files
    $imageFiles = Find-ImageFiles -BasePath $systemPaths.ImagePath
    if (-not $imageFiles) { return }
    
    # Get and select target disk
    $availableDisks = Get-AvailableDisks
    $targetDisk = Select-TargetDisk -Disks $availableDisks
    if (-not $targetDisk) { return }
    
    Write-Status "`n🚀 Starting image deployment process..." -Type Info
    
    # Create and execute diskpart script
    if (-not (New-DiskpartScript -DiskNumber $targetDisk.Number -ScriptPath $diskpartScriptPath)) { return }
    if (-not (Invoke-DiskpartScript -ScriptPath $diskpartScriptPath)) { return }
    
    # Apply EFI image if available
    $efiApplied = $false
    if ($imageFiles.EFIWim) {
        if (-not (Apply-WindowsImage -ImagePath $imageFiles.EFIWim -TargetPath 'S:\' -ImageType "EFI Image")) { return }
        $efiApplied = $true
        Write-Status "EFI partition populated from WIM file" -Type Success
    }
    
    # Apply OS image
    if (-not (Apply-WindowsImage -ImagePath $imageFiles.OSWim -TargetPath 'C:\' -ImageType "OS Image")) { return }
    
    # Configure UEFI boot only if EFI WIM wasn't applied
    if ($efiApplied) {
        Write-Status "EFI WIM applied - skipping bcdboot to avoid duplicate entries" -Type Info
        Write-Status "Assuming EFI WIM contains proper BCD configuration" -Type Info
    } else {
        Write-Status "Creating EFI boot files from Windows installation..." -Type Info
        if (-not (Set-UEFIBoot)) { return }
    }
    
    # Cleanup
    try {
        Remove-Item -Path $diskpartScriptPath -Force -ErrorAction SilentlyContinue
        Write-Status "Cleaned up temporary files" -Type Success
    } catch {
        Write-Status "Warning: Could not clean up temporary files" -Type Warning
    }
    
    # Show completion dialog
    Show-CompletionDialog
}

# Execute main function
try {
    Start-ImageDeployment
} catch {
    Write-Status "Critical error: $($_.Exception.Message)" -Type Error
    Write-Status "Stack trace: $($_.ScriptStackTrace)" -Type Error
    Read-Host "Press Enter to exit"
}