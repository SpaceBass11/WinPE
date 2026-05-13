# Build the WinPE Deployment USB

One-time procedure to turn a blank USB stick into a bootable Windows
deployment USB. Once built, the USB is reusable indefinitely — you only
have to redo this when you want a newer WinPE base (roughly once a
year, when Microsoft ships a new Windows ADK).

**Where you do this:** any admin Windows 10 or 11 workstation with
internet access. **Not** in WinPE.

**Time required:** about 60 minutes the first time, mostly waiting on
ADK downloads. Subsequent rebuilds are ~15 minutes.

---

## Step 0 — What You Need

- Admin Windows 10/11 workstation
- USB drive, 32 GB or larger (8 GB minimum — won't fit many images)
- A Windows ISO (download from
  [Microsoft](https://www.microsoft.com/software-download/windows11) or
  your VLSC/Visual Studio subscription)

---

## Step 1 — Install the Windows ADK

The ADK is Microsoft's free deployment toolkit. You need two installers:

1. **Windows ADK** — download from Microsoft's
   [ADK page](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install).
   During install, **only check "Deployment Tools"**. You don't need
   the other features.
2. **Windows PE add-on for the ADK** — same page, downloaded
   separately. Install it after the ADK finishes.

When both are installed, you'll have a new Start menu shortcut:
**"Deployment and Imaging Tools Environment"** (under "Windows Kits").
That's a Command Prompt with all the ADK tools on PATH. We'll use it
in Step 4.

---

## Step 2 — Partition the USB

Plug the USB into your admin workstation. Open Command Prompt **as
Administrator**. Run `diskpart`:

```
diskpart
list disk
```

Find your USB by size. **Triple-check the disk number.** Picking the
wrong disk here will wipe your workstation's drive. Then:

```
select disk <USB_NUMBER>
clean
create partition primary size=2048
format quick fs=fat32 label="WinPE"
assign letter=P
create partition primary
format quick fs=ntfs label="IMAGES"
assign letter=I
exit
```

You now have:

- `P:` — 2 GB FAT32 (will hold WinPE boot files)
- `I:` — remaining space, NTFS (will hold Windows images)

> Why FAT32 for the boot partition? UEFI firmware can only boot from
> FAT32. Why NTFS for the data partition? WIM files are routinely
> larger than the 4 GB single-file limit on FAT32.

---

## Step 3 — Copy WinPE to a Working Folder

Open **Deployment and Imaging Tools Environment** as Administrator
(Start menu → Windows Kits). At the prompt:

```
copype amd64 C:\WinPE_Build
```

This creates `C:\WinPE_Build` with a `media\` subfolder (the WinPE
file tree) and a fresh `boot.wim` you'll customize next.

---

## Step 4 — Mount boot.wim and Add Components

Stay in the **Deployment and Imaging Tools Environment** prompt.

### 4a. Mount the image

```
dism /Mount-Image /ImageFile:C:\WinPE_Build\media\sources\boot.wim /Index:1 /MountDir:C:\WinPE_Build\mount
```

### 4b. Add the required optional components

Run these one at a time. Each takes ~30 seconds. **Order matters** —
some components depend on `WinPE-WMI` being installed first.

```
dism /Image:C:\WinPE_Build\mount /Add-Package /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-WMI.cab"

dism /Image:C:\WinPE_Build\mount /Add-Package /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\en-us\WinPE-WMI_en-us.cab"

dism /Image:C:\WinPE_Build\mount /Add-Package /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-NetFx.cab"

dism /Image:C:\WinPE_Build\mount /Add-Package /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\en-us\WinPE-NetFx_en-us.cab"

dism /Image:C:\WinPE_Build\mount /Add-Package /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-Scripting.cab"

dism /Image:C:\WinPE_Build\mount /Add-Package /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\en-us\WinPE-Scripting_en-us.cab"

dism /Image:C:\WinPE_Build\mount /Add-Package /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-StorageWMI.cab"

dism /Image:C:\WinPE_Build\mount /Add-Package /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\en-us\WinPE-StorageWMI_en-us.cab"

dism /Image:C:\WinPE_Build\mount /Add-Package /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-EnhancedStorage.cab"

dism /Image:C:\WinPE_Build\mount /Add-Package /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\en-us\WinPE-EnhancedStorage_en-us.cab"

dism /Image:C:\WinPE_Build\mount /Add-Package /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-FMAPI.cab"
```

(If your ADK is installed somewhere other than the default location,
replace the path prefix.)

### 4c. Apply the NTFS case-sensitivity fix

Some Windows images (especially anything that has the Containers or
Hyper-V feature installed) include files with the NTFS
`CASE_SENSITIVE_DIR` flag. Without this registry tweak, DISM apply
will fail at ~19% with "Incorrect function (exit 1)".

```
reg load HKLM\WinPE_SYSTEM C:\WinPE_Build\mount\Windows\System32\config\SYSTEM
reg add "HKLM\WinPE_SYSTEM\ControlSet001\Control\FileSystem" /v NtfsEnableDirCaseSensitivity /t REG_DWORD /d 1 /f
reg unload HKLM\WinPE_SYSTEM
```

### 4d. Replace startnet.cmd so the prompt opens with helpful info

```
notepad C:\WinPE_Build\mount\Windows\System32\startnet.cmd
```

Replace the contents with:

```cmd
@echo off
wpeinit
echo.
echo =============================================================
echo  Windows Deployment USB - WinPE Command Prompt
echo =============================================================
echo.
echo  See README.md on the IMAGES partition for the deploy recipe.
echo  Quick reference:
echo    wmic logicaldisk get caption,volumename   (find IMAGES partition)
echo    diskpart                                  (list and partition disks)
echo    dism /Apply-Image ...                     (apply WIM)
echo    bcdboot C:\Windows /s S: /f UEFI          (configure boot)
echo    wpeutil reboot
echo.
```

Save and close Notepad.

### 4e. Unmount and commit

```
dism /Unmount-Image /MountDir:C:\WinPE_Build\mount /Commit
```

This takes 2-5 minutes. When it finishes you have a customized
`boot.wim` in `C:\WinPE_Build\media\sources\`.

---

## Step 5 — Copy WinPE to the USB

Back in any Command Prompt (admin not strictly required for this part,
but doesn't hurt):

```
xcopy /s /e /y C:\WinPE_Build\media\*.* P:\
```

> **Do not use `MakeWinPEMedia /UFD`.** It reformats the whole USB and
> destroys the dual-partition layout from Step 2.

After it finishes, verify these exist:

- `P:\bootmgr`
- `P:\sources\boot.wim`
- `P:\EFI\Boot\bootx64.efi`

If any are missing, repeat the xcopy.

---

## Step 6 — Add Windows Images

Copy the `.wim` or `.esd` file(s) you want to deploy onto the data
partition under `\images\`:

```
mkdir I:\images
copy <path-to-iso>\sources\install.wim I:\images\Win11.wim
```

> [!TIP]
> Naming the WIM after the edition (`Win11_Pro_24H2.wim`,
> `Win10_LTSC.wim`) helps the tech pick the right file during deploy.

### Where to get WIM files

- **From a Windows ISO** — mount the ISO (right-click → Mount), then
  copy `sources\install.wim` or `sources\install.esd` from the mounted
  drive to `I:\images\`. That's it for most use cases.
- **Captured from a reference machine** — boot the reference into
  WinPE, then:
  ```
  Dism /Capture-Image /ImageFile:I:\images\MyCapture.wim ^
       /CaptureDir:C:\ /Name:"My Build" ^
       /CheckIntegrity /verify /Compress:max
  ```
  `/CheckIntegrity` embeds SHA1 hashes so you can detect corruption
  later. `/verify` re-reads every file at capture time to catch bad
  source reads early.

### Pulling one edition out of a multi-edition install.wim

A retail install.wim contains Home, Pro, Education, Enterprise, etc.
You can deploy any of them directly with `/Index:N` at deploy time
(see README.md step 4). Or, if you'd rather ship a smaller USB with
only one edition:

```
Dism /Get-WimInfo /WimFile:E:\sources\install.wim
:: note the Index of the edition you want, e.g. Index:6 = Pro

Dism /Export-Image /SourceImageFile:E:\sources\install.wim /SourceIndex:6 ^
     /DestinationImageFile:I:\images\Win11_Pro.wim ^
     /Compress:max /CheckIntegrity
```

---

## Step 7 — (Optional) Add unattend.xml

Skip this if you're OK clicking through Windows OOBE manually.

See [UNATTEND.md](UNATTEND.md) for how to fill out the answer file. The
short version: copy the template and edit it, then drop it on the
IMAGES partition:

```
mkdir I:\configs
copy <your-edited-unattend.xml> I:\configs\unattend.xml
```

The deploy procedure (README step 8) copies this to
`C:\Windows\Panther\unattend.xml` on the target.

---

## Step 8 — (Optional, Dell Only) Add CCTK

Skip this if your fleet isn't Dell.

See [CCTK.md](CCTK.md) for the full procedure. The short version:

1. Download Dell Command | Configure to your admin workstation.
2. Re-mount boot.wim, copy `cctk.exe` + the HAPI folder to
   `C:\WinPE_Build\mount\cctk\`, install the HAPI `.inf` driver, unmount
   /Commit, re-xcopy media to USB.
3. Drop your `.ini` BIOS configs into `I:\cctk\` on the IMAGES
   partition.

---

## Step 9 — Test the USB

Boot a non-production machine from the USB to confirm WinPE loads. You
should see:

```
=============================================================
 Windows Deployment USB - WinPE Command Prompt
=============================================================
```

Followed by `X:\Windows\System32>`. From here you can follow
[the daily deploy steps in README.md](../README.md#daily-deploy--step-by-step).

If WinPE doesn't boot, see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#usb-doesnt-boot-from-uefi-menu).

---

## Refreshing the USB (yearly)

When a new ADK ships or you want a newer Windows ISO:

- **New images only?** Just replace files in `I:\images\`. Skip
  everything else.
- **New ADK / new WinPE base?** Repeat steps 3-5. Steps 1, 2, 6
  don't need to be redone.

---

## Final Layout

```
USB Drive
+-- P:\ (FAT32 "WinPE", ~2 GB)
|   +-- bootmgr
|   +-- EFI\Boot\bootx64.efi
|   `-- sources\boot.wim       <- the customized WinPE
|
`-- I:\ (NTFS "IMAGES", remaining)
    +-- images\
    |   +-- Win11_Pro.wim
    |   `-- Win10_LTSC.wim
    +-- configs\               (optional - unattend.xml)
    |   `-- unattend.xml
    `-- cctk\                  (optional - Dell BIOS configs)
        `-- default.ini
```

When you're done, you can free the drive letters in your admin
workstation so Explorer isn't cluttered:

```
mountvol P: /d
mountvol I: /d
```

The USB stays bootable — only the letters assigned in your current
Windows session are released.
