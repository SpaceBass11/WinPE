# USB Drive Setup Guide

Complete guide for preparing a bootable WinPE USB drive with the image deployment tool.

## Prerequisites

- USB drive (32GB+ recommended, 8GB minimum)
- Windows ADK with WinPE add-on installed
- Windows 10/11 machine with admin access
- `.wim` or `.esd` image files to deploy

## Step 0: (Optional) Prep your Windows images

If you want a debloated, customized `install.wim` (instead of using one
straight off a Microsoft ISO), use the companion script
`scripts/prepare_wim.ps1`. It mounts an ISO, picks the edition you
want, removes provisioned AppX packages with a whitelist, optionally
disables Copilot, and re-exports a compressed clean WIM. See the
[Script Reference](SCRIPT_REFERENCE.md#prepare_wimps1) for details.
You can skip this step and use unmodified ISO WIMs if you don't care
about debloat.

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
and `-ReleaseUsbLetter` which combine Steps 2 and 4 below.

### Why not `MakeWinPEMedia /UFD`?

The script's build output is the `media\` tree, not an ISO. We xcopy it onto
an already-partitioned USB (Steps 3-4) because `MakeWinPEMedia /UFD` wipes
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

## Step 3: Partition the USB Drive

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

## Step 4: Make USB Bootable with WinPE

Copy the built WinPE media to the boot partition:

```cmd
xcopy /s /e /y C:\WinPE_Build\media\*.* P:\
```

> **Note:** Do NOT use `MakeWinPEMedia /UFD` here — it reformats the entire USB
> and destroys the dual-partition layout created in Step 3.

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
> 4, and this release in one shot.

## Step 5: Add Windows Images to Data Partition

Copy your `.wim` or `.esd` files to the data partition:

```cmd
mkdir I:\images
copy D:\sources\install.wim I:\images\Win11_Pro.wim
```

**Optional — Dell BIOS configs:** if you built `boot.wim` with
`-CctkSource`, also create a `cctk\` folder on this same data partition
and drop your `.ini` configs there. The deploy script picks the right
config per machine (service tag → model → `default.ini`). See
[CCTK.md](CCTK.md) for setup and config format.

```cmd
mkdir I:\cctk
copy admin-machine:\configs\default.ini I:\cctk\default.ini
```

### Getting WIM Files

**From a Windows ISO:**
```cmd
:: Mount the ISO, then copy install.wim from sources/
copy E:\sources\install.esd I:\images\
```

**From a running Windows installation (capture):**

Always capture with `/CheckIntegrity` and `/verify` — `/CheckIntegrity`
embeds SHA1 hashes so integrity can be verified later, and `/verify`
re-reads every file after writing to catch bad source reads at capture
time rather than at deploy time.

```cmd
:: Boot into WinPE, then capture (directly onto the USB Images partition)
Dism /Capture-Image /ImageFile:I:\images\MyCapture.wim /CaptureDir:C:\ /Name:"My Windows Build" /CheckIntegrity /verify /Compress:max
```

If the captured image contains Windows Containers or Hyper-V layers (dense
reparse points + hard-link storms under `C:\ProgramData\Microsoft\Windows\Containers\Layers`),
the boot.wim must be built with the builder script (Step 2) — the
`NtfsEnableDirCaseSensitivity` reg tweak there is required for DISM apply
to succeed. To skip the layer cache entirely at capture time, use a
`/configfile` with an ExclusionList:

```ini
; exclude.ini - layer cache is rebuilt on first container use
[ExclusionList]
\ProgramData\Microsoft\Windows\Containers\Layers
```

```cmd
Dism /Capture-Image /ImageFile:I:\images\MyCapture.wim /CaptureDir:C:\ /Name:"My Windows Build" /ConfigFile:exclude.ini /CheckIntegrity /verify /Compress:max
```

**Export a specific edition from a multi-index WIM:**
```cmd
Dism /Get-WimInfo /WimFile:E:\sources\install.esd
Dism /Export-Image /SourceImageFile:E:\sources\install.esd /SourceIndex:7 /DestinationImageFile:I:\images\Win11_Pro.wim /Compress:max /CheckIntegrity
```

## Step 6: Test

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
│       └── boot.wim  (contains unified_winpe_deploy.ps1, optionally CCTK)
│
└── [Partition 2: NTFS "Images" remaining space]
    ├── images/
    │   ├── Win11_Pro_24H2.wim
    │   ├── Win10_Enterprise_LTSC.wim
    │   └── (more .wim/.esd files)
    └── cctk/                       (optional, Dell BIOS configs)
        ├── default.ini             (catch-all)
        ├── OptiPlex7090.ini        (per-model override, optional)
        └── 1A2B3C4.ini             (per-service-tag override, optional)
```

The `cctk\` folder is only used if your boot.wim was built with
`-CctkSource` (so `cctk.exe` is embedded in the image). See
[CCTK.md](CCTK.md) for the config-file format and selection rules.

## Tips

- **Use NTFS for the data partition** - FAT32 has a 4GB file limit, and WIM files are often larger
- **Label your WIM files clearly** - the script shows filenames in the selection menu
- **Keep WIM files in an `images/` directory** - it's searched first and avoids slow full-drive scans
- **32GB+ USB recommended** - a single Windows WIM is typically 4-6GB
- **USB 3.0+ strongly recommended** - image deployment is I/O heavy
