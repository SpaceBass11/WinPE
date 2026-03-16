# USB Drive Setup Guide

Complete guide for preparing a bootable WinPE USB drive with the image deployment tool.

## Prerequisites

- USB drive (32GB+ recommended, 8GB minimum)
- Windows ADK with WinPE add-on installed
- Windows 10/11 machine with admin access
- `.wim` or `.esd` image files to deploy

## Step 1: Install Windows ADK + WinPE Add-on

Download and install from Microsoft:
1. [Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
2. Windows PE add-on for the ADK

Only the **Deployment Tools** feature is required from the ADK.

## Step 2: Create WinPE Media

Open **Deployment and Imaging Tools Environment** as Administrator:

```cmd
:: Copy WinPE files to a working directory
copype amd64 C:\WinPE_amd64
```

## Step 3: Customize WinPE (Add the Deploy Script)

Mount the WinPE image:

```cmd
Dism /Mount-Image /ImageFile:C:\WinPE_amd64\media\sources\boot.wim /Index:1 /MountDir:C:\WinPE_amd64\mount
```

### Add PowerShell Support (if not included)

Most modern WinPE builds include PowerShell. If yours doesn't:

```cmd
:: Add WinPE-PowerShell
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-WMI.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-NetFx.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-Scripting.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-PowerShell.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-DismCmdlets.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-StorageWMI.cab"
```

### Copy the Deploy Script

```cmd
mkdir C:\WinPE_amd64\mount\Windows\System32\scripts
copy unified_winpe_deploy.ps1 C:\WinPE_amd64\mount\Windows\System32\scripts\
```

### Configure Auto-Start

Edit `C:\WinPE_amd64\mount\Windows\System32\startnet.cmd` to find the image
drive by volume label and launch the deploy script:

```cmd
wpeinit
@echo off
setlocal enabledelayedexpansion
timeout /t 3 /nobreak >nul
set DEPLOY_IMAGE_DRIVE=
for %%d in (D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    vol %%d: 2>nul | find /i "IMAGES" >nul 2>&1
    if !ERRORLEVEL! equ 0 (
        set "DEPLOY_IMAGE_DRIVE=%%d:"
        goto :found
    )
)
echo No drive with label "IMAGES" found - script will scan all drives.
goto :launch
:found
echo Found image drive: %DEPLOY_IMAGE_DRIVE%
:launch
if defined DEPLOY_IMAGE_DRIVE (
    powershell.exe -ExecutionPolicy Bypass -File X:\Windows\System32\scripts\unified_winpe_deploy.ps1 -ImagePath "%DEPLOY_IMAGE_DRIVE%\images"
) else (
    powershell.exe -ExecutionPolicy Bypass -File X:\Windows\System32\scripts\unified_winpe_deploy.ps1
)
pause
```

The label `IMAGES` matches the NTFS data partition created in Step 4. If you
use a different label, change the `find /i "IMAGES"` string to match.

### Unmount

```cmd
Dism /Unmount-Image /MountDir:C:\WinPE_amd64\mount /Commit
```

## Step 4: Partition the USB Drive

Open **diskpart** as Administrator:

```
diskpart
list disk
select disk <USB_DISK_NUMBER>
clean
create partition primary size=2048
format quick fs=fat32 label="WinPE"
assign letter=P
create partition primary
format quick fs=ntfs label="Images"
assign letter=I
exit
```

> **WARNING:** Double-check the disk number! This erases the entire USB drive.

## Step 5: Make USB Bootable with WinPE

```cmd
:: Copy WinPE files to the boot partition
xcopy /s /e C:\WinPE_amd64\media\*.* P:\

:: Or use MakeWinPEMedia
MakeWinPEMedia /UFD C:\WinPE_amd64 P:
```

## Step 6: Add Windows Images to Data Partition

Copy your `.wim` or `.esd` files to the data partition:

```cmd
mkdir I:\images
copy D:\sources\install.wim I:\images\Win11_Pro.wim
```

### Getting WIM Files

**From a Windows ISO:**
```cmd
:: Mount the ISO, then copy install.wim from sources/
copy E:\sources\install.esd I:\images\
```

**From a running Windows installation (capture):**
```cmd
:: Boot into WinPE, then capture
Dism /Capture-Image /ImageFile:I:\images\MyCapture.wim /CaptureDir:C:\ /Name:"My Windows Build"
```

**Export a specific edition from a multi-index WIM:**
```cmd
Dism /Get-WimInfo /WimFile:E:\sources\install.esd
Dism /Export-Image /SourceImageFile:E:\sources\install.esd /SourceIndex:7 /DestinationImageFile:I:\images\Win11_Pro.wim /Compress:max
```

## Step 7: Test

1. Plug USB into target machine
2. Enter UEFI/BIOS boot menu (usually F12, F2, or Del at POST)
3. Select the USB drive (UEFI mode)
4. WinPE boots → script auto-launches
5. Select your image from the TUI menu
6. Select target disk and confirm
7. Wait for deployment to complete
8. Remove USB and reboot

## Directory Structure When Complete

```
USB Drive:
├── [Partition 1: FAT32 "WinPE" ~2GB]
│   ├── Boot/
│   ├── EFI/
│   └── sources/
│       └── boot.wim  (contains unified_winpe_deploy.ps1)
│
└── [Partition 2: NTFS "Images" remaining space]
    └── images/
        ├── Win11_Pro_24H2.wim
        ├── Win10_Enterprise_LTSC.wim
        └── (more .wim/.esd files)
```

## Tips

- **Use NTFS for the data partition** - FAT32 has a 4GB file limit, and WIM files are often larger
- **Label your WIM files clearly** - the script shows filenames in the selection menu
- **Keep WIM files in an `images/` directory** - it's searched first and avoids slow full-drive scans
- **32GB+ USB recommended** - a single Windows WIM is typically 4-6GB
- **USB 3.0+ strongly recommended** - image deployment is I/O heavy
