# USB Drive Setup Guide

Complete guide for preparing a bootable WinPE USB drive with the image deployment tool.

## Prerequisites

- USB drive (32GB+ recommended, 8GB minimum)
- Windows ADK with WinPE add-on installed
- Windows 10/11 machine with admin access
- `.wim` or `.esd` image files to deploy

## Step 0: (Optional) Prep your Windows image

Use `scripts/prepare_wim.ps1` to produce a debloated, customized WIM from
a stock Windows ISO. Run on your **admin workstation** (not in WinPE):

```powershell
# Minimal: debloat default whitelist + disable Copilot
.\scripts\prepare_wim.ps1 `
    -SourceIso 'D:\iso\Win11_24H2_English_x64.iso' `
    -OutputWim 'I:\images\Win11_Enterprise.wim' `
    -DisableCopilot

# With pre-baked drivers (chipset, NVMe, NIC — inject at WIM prep time)
.\scripts\prepare_wim.ps1 `
    -SourceIso 'D:\iso\Win11_24H2_English_x64.iso' `
    -OutputWim 'I:\images\Win11_Enterprise.wim' `
    -DriverPath 'C:\Drivers\Dell_OptiPlex7090' `
    -DisableCopilot
```

**What it does:** mounts the ISO, picks the requested edition, removes
provisioned AppX packages not on the whitelist, optionally injects drivers
and applies registry tweaks, then re-exports a `Compress:max` WIM.

You can skip this step and copy an unmodified `.wim`/`.esd` directly from
the ISO — just drop it in `I:\images\` in Step 5.

For full options, see [Script Reference](SCRIPT_REFERENCE.md#prepare_wimps1).

## Step 1: Install Windows ADK + WinPE Add-on

Download and install from Microsoft:
1. [Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
2. Windows PE add-on for the ADK

Only the **Deployment Tools** feature is required from the ADK.

## Step 2: Build a Customized boot.wim

Open **Deployment and Imaging Tools Environment** as Administrator, then run
the builder from this repo:

> [!TIP]
> **Three ways to find the shell:**
> 1. Type **Deploy** in the Start menu → right-click → **Run as administrator** (fastest — it appears immediately)
> 2. **Start → Windows Kits → Deployment and Imaging Tools Environment** → right-click → **Run as administrator**
> 3. Open an elevated Command Prompt (Win+R → `cmd`, Ctrl+Shift+Enter), then: `call "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\DandISetEnv.bat"`

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
(the volume-label lookup lets the deploy script skip a full scan; the
`deploy.args` block enables per-USB parameter overrides without
rebuilding `boot.wim` — see [DEPLOY_ARGS.md](DEPLOY_ARGS.md)):

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
:: Optional per-USB args file. One line of PowerShell parameters; lets
:: operators retarget a USB without rebuilding boot.wim. See docs/DEPLOY_ARGS.md.
set "DEPLOYARGS="
if defined DEPLOY_IMAGE_DRIVE (
    if exist "%DEPLOY_IMAGE_DRIVE%\deploy.args" (
        set /p DEPLOYARGS=<"%DEPLOY_IMAGE_DRIVE%\deploy.args"
        echo Loaded deploy args from %DEPLOY_IMAGE_DRIVE%\deploy.args
        echo   Parameters loaded. Secrets, if present, are not displayed.
    )
)
:: Replace {DRIVE} placeholder with the actual image-drive letter.
:: build_iso.ps1 uses this so deploy.args paths work regardless of
:: which drive letter WinPE assigns the USB.
if defined DEPLOY_IMAGE_DRIVE (
    if defined DEPLOYARGS (
        set "DEPLOYARGS=!DEPLOYARGS:{DRIVE}=%DEPLOY_IMAGE_DRIVE%!"
    )
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\scripts\unified_winpe_deploy.ps1 !DEPLOYARGS!
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
format quick fs=ntfs label="IMAGES"
assign letter=I
exit
```

> [!WARNING]
> Double-check the disk number. This erases the entire USB drive.

## Step 4: Make USB Bootable with WinPE

Copy the built WinPE media to the boot partition:

```cmd
xcopy /s /e /y C:\WinPE_Build\media\*.* P:\
```

> [!NOTE]
> Do NOT use `MakeWinPEMedia /UFD` here — it reformats the entire USB and
> destroys the dual-partition layout created in Step 3.

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

> [!TIP]
> `build_boot_wim.ps1 -UsbDrive P: -ReleaseUsbLetter` does Steps 2, 4, and
> this release in one shot.

## Step 5: Add Windows Images to Data Partition

Copy your `.wim` or `.esd` files to the data partition:

```cmd
mkdir I:\images
copy D:\sources\install.wim I:\images\Win11_Pro.wim
```

**Optional — Unattend.xml for first-boot configuration:** if you want
Windows Setup to auto-configure on first boot (skip OOBE, set computer
name, join a domain, configure autologon), create an `unattend.xml` and
keep it on your admin machine. Pass it to the deploy script at runtime
via `-UnattendFile` — it is copied to `C:\Windows\Panther\` after apply,
before the machine reboots:

```powershell
.\unified_winpe_deploy.ps1 `
    -WimFile "D:\images\Win11.wim" `
    -UnattendFile "D:\configs\unattend.xml"
```

The unattend file does **not** need to be on the USB — it can live anywhere
accessible from the machine running the script (typically from the USB
IMAGES partition for convenience):

```cmd
mkdir I:\configs
copy admin-machine:\configs\unattend.xml I:\configs\unattend.xml
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
└── [Partition 2: NTFS "IMAGES" remaining space]
    ├── images/
    │   ├── Win11_Enterprise_Custom.wim    ← output of prepare_wim.ps1
    │   ├── Win10_Enterprise_LTSC.wim
    │   └── (more .wim/.esd files)
    ├── configs/                           (optional, unattend.xml answer files)
    │   ├── unattend.xml                   ← used with -UnattendFile
    │   └── unattend_domain.xml
    └── cctk/                             (optional, Dell BIOS configs)
        ├── default.ini                   (catch-all)
        ├── OptiPlex7090.ini              (per-model override, optional)
        └── 1A2B3C4.ini                   (per-service-tag override, optional)
```

- The `configs\` folder is a convention; `-UnattendFile` accepts any
  path accessible during the WinPE session.
- The `cctk\` folder is only used if your boot.wim was built with
  `-CctkSource` (so `cctk.exe` is embedded in the image). See
  [CCTK.md](CCTK.md) for the config-file format and selection rules.

## Tips

- **Use NTFS for the data partition** - FAT32 has a 4GB file limit, and WIM files are often larger
- **Label your WIM files clearly** - the script shows filenames in the selection menu
- **Keep WIM files in an `images/` directory** - it's searched first and avoids slow full-drive scans
- **32GB+ USB recommended** - a single Windows WIM is typically 4-6GB
- **USB 3.0+ strongly recommended** - image deployment is I/O heavy
