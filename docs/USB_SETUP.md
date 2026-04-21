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

## Step 2: Build a Customized boot.wim

Open **Deployment and Imaging Tools Environment** as Administrator, then run
the builder from this repo:

```powershell
.\scripts\build_boot_wim.ps1
```

This runs `copype`, mounts the template `boot.wim`, adds all required
optional components (PowerShell, WMI, DISM cmdlets, StorageWMI,
EnhancedStorage, FMAPI), applies the `NtfsEnableDirCaseSensitivity`
registry tweak (critical for Windows Containers layer images — without
it, DISM apply fails at ~19% with "Incorrect function"), embeds
`unified_winpe_deploy.ps1` at `X:\scripts\`, and writes a `startnet.cmd`
that auto-launches it.

Output: `C:\WinPE_Build\media\` (or wherever `-WorkDir` points).

See `docs/SCRIPT_REFERENCE.md` for all parameters, including `-UsbDrive`
and `-ReleaseUsbLetter` which combine Steps 2 and 5 below.

### Why not `MakeWinPEMedia /UFD`?

The script's build output is the `media\` tree, not an ISO. We xcopy it onto
an already-partitioned USB (Step 4/5) because `MakeWinPEMedia /UFD` wipes
the whole USB and destroys the dual-partition layout this tool relies on.

### Manual alternative (if you can't run the builder)

If you must build manually, the `startnet.cmd` should match this pattern
(the volume-label lookup lets the deploy script skip a full scan):

```cmd
@echo off
wpeinit
setlocal enabledelayedexpansion
ping -n 4 127.0.0.1 >nul
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\scripts\unified_winpe_deploy.ps1
```

And the offline registry tweak (inside the mounted `boot.wim`):

```cmd
reg load HKLM\WinPE_OFFLINE C:\WinPE_amd64\mount\Windows\System32\config\SYSTEM
reg add "HKLM\WinPE_OFFLINE\ControlSet001\Control\FileSystem" /v NtfsEnableDirCaseSensitivity /t REG_DWORD /d 1 /f
reg unload HKLM\WinPE_OFFLINE
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

Copy the built WinPE media to the boot partition:

```cmd
xcopy /s /e /y C:\WinPE_Build\media\*.* P:\
```

> **Note:** Do NOT use `MakeWinPEMedia /UFD` here — it reformats the entire USB
> and destroys the dual-partition layout created in Step 4.

### Release the P: drive letter (optional but recommended)

Once the media is copied, you don't need the FAT32 boot partition mounted
in your working Windows anymore — the machine you're deploying to will see
it as part of USB boot. Free the letter to keep Explorer tidy:

```cmd
mountvol P: /d
```

The partition stays bootable; only the drive letter assignment in your
current Windows session is removed. Plug the USB in elsewhere and it'll
still boot.

> **Tip:** `build_boot_wim.ps1 -UsbDrive P: -ReleaseUsbLetter` does Steps 2,
> 5, and this release in one shot.

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
