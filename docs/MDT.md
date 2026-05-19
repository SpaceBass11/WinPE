# MDT Manual Deployment Guide

A complete walkthrough for building a zero-touch Windows 11 deployment USB
using MDT Deployment Workbench. No scripts. No automation layer to maintain.
Configure MDT once through the GUI, build an ISO, hand it to operators.

**Time estimate:** 2-3 hours first time. 30 minutes to rebuild after a WIM update.

---

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Create the Deployment Share](#2-create-the-deployment-share)
3. [Import the OS Image](#3-import-the-os-image)
4. [Create the Task Sequence](#4-create-the-task-sequence)
5. [Configure Zero-Touch Settings](#5-configure-zero-touch-settings)
6. [Windows 11 ADK Compatibility Fixes](#6-windows-11-adk-compatibility-fixes)
7. [Configure the Task Sequence](#7-configure-the-task-sequence)
8. [Add Drivers](#8-add-drivers)
9. [Add Applications](#9-add-applications)
10. [Unattend.xml](#10-unattendxml)
11. [Update the Deployment Share](#11-update-the-deployment-share)
12. [Create Media](#12-create-media)
13. [Update Media -- Build the ISO](#13-update-media----build-the-iso)
14. [Create Bootable USB](#14-create-bootable-usb)
15. [Updating the Image](#updating-the-image)
16. [Operator Instructions](#operator-instructions)
17. [DoD STIG Steps](#dod-stig-steps)

---

## 1. Prerequisites

Install these on your **admin workstation** in order. All require Administrator
rights. Reboot between the ADK and WinPE add-on installs.

| # | Software | What to select |
|---|----------|----------------|
| 1 | [Windows ADK for Windows 11](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) | **Deployment Tools** only -- uncheck everything else |
| 2 | [Windows PE add-on for ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) | Full install (separate installer, same download page) |
| 3 | [MDT 8456](https://www.microsoft.com/en-us/download/details.aspx?id=54259) | Full install -- last MDT version; supports Windows 11 |
| 4 | [Hotfix KB4564442](https://support.microsoft.com/kb/4564442) | Required for Windows 11 UEFI deployments |

You also need:

- A Windows 11 `.wim` or `.iso` file (from Microsoft media, or a captured
  image -- see [Capturing a Custom Image](#capturing-a-custom-image) below)
- Administrator rights on the workstation
- ~30 GB free disk space for the deployment share

---

## 2. Create the Deployment Share

1. Open **Deployment Workbench** (Start > Microsoft Deployment Toolkit >
   Deployment Workbench).
2. Right-click **Deployment Shares** > **New Deployment Share**.
3. Fill in the wizard:

   | Field | Value |
   |-------|-------|
   | Deployment share path | `C:\MDTDeploymentShare` |
   | Share name | `MDTDeploymentShare$` |
   | Deployment share description | Windows 11 Deployment |
   | Ask if image should be captured | Uncheck |
   | Ask user to set local admin password | Uncheck |
   | Ask user for product key | Uncheck |

4. Click **Next** through the summary, then **Finish**.

The deployment share appears under **Deployment Shares** in the tree.

---

## 3. Import the OS Image

### From a WIM file (recommended)

1. In Deployment Workbench, expand **Deployment Shares** > **your share** >
   **Operating Systems**.
2. Right-click **Operating Systems** > **Import Operating System**.
3. Select **Custom image file**.
4. Browse to your `.wim` file. Click **Next**.
5. Leave "Setup files are not needed" checked. Click **Next**.
6. Destination folder name: `Windows 11 Enterprise` (or any descriptive name).
   Click **Next** > **Next** > **Finish**.

### From ISO media

1. Mount the ISO: double-click it in Explorer (Windows 10/11 mounts it
   automatically as a drive letter).
2. Follow the wizard above but select **Full set of source files** and point
   to the mounted drive letter.
3. Workbench copies and imports the WIM automatically.

After import you will see one or more OS entries. If the ISO contained multiple
editions (Home/Pro/Enterprise), each appears as a separate entry. You select
the correct edition when creating the task sequence.

### Capturing a custom image

To deploy a pre-configured image (software already installed):

1. On a reference machine, install and configure Windows exactly as desired.
2. Run Sysprep from an elevated command prompt:
   ```
   C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
   ```
3. The machine shuts down. Boot it from any WinPE USB.
4. From the WinPE command prompt, capture the image:
   ```
   Dism /Capture-Image /ImageFile:D:\custom.wim /CaptureDir:C:\ /Name:"Windows 11 Custom" /CheckIntegrity
   ```
5. Copy `custom.wim` to your admin workstation and import it using the
   "From a WIM file" steps above.

---

## 4. Create the Task Sequence

In Deployment Workbench, expand **Deployment Shares** > **your share** >
**Task Sequences**.

1. Right-click **Task Sequences** > **New Task Sequence**.
2. Fill in the wizard:

   | Field | Value |
   |-------|-------|
   | Task sequence ID | `WIN11-DEPLOY` |
   | Task sequence name | Windows 11 Enterprise Deployment |
   | Task sequence comments | (leave blank) |
   | Template | **Standard Client Task Sequence** |
   | OS | Select the Windows 11 image you just imported |
   | Product key | Do not specify |
   | Full name | (your org, or leave blank) |
   | Organization | (your org, or leave blank) |
   | IE home page | (leave blank) |
   | Admin password | Do not specify |

3. Click **Next** > **Next** > **Finish**.

---

## 5. Configure Zero-Touch Settings

Zero-touch is controlled by two INI files baked into the deployment share
and then into the bootable ISO. MDT reads these at runtime to skip all
interactive wizard screens.

Open **Deployment Share Properties**: right-click your deployment share >
**Properties** > **Rules** tab.

### Bootstrap.ini

Click **Edit Bootstrap.ini** at the bottom of the Rules tab. Replace the
entire contents with:

```ini
[Settings]
Priority=Default

[Default]
DeployRoot=.
SkipBDDWelcome=YES
```

`DeployRoot=.` is what makes the ISO standalone -- WinPE reads the deployment
data from the same USB it booted from, no network required.

Click **OK** (or close the editor; it saves automatically).

### CustomSettings.ini

Back on the **Rules** tab, replace the text area contents with the following.
Read the comments before saving -- several settings need to match your
environment.

```ini
[Settings]
Priority=Default

[Default]
_SMSTSOrgName=Windows 11 Deployment
OSInstall=Y
HideShell=YES

; ---- Zero-touch: skip all wizard pages --------------------------------
SkipAdminPassword=YES
SkipApplications=YES
SkipBitLocker=YES
SkipCapture=YES
SkipComputerBackup=YES
SkipComputerName=YES
SkipDomainMembership=YES
SkipFinalSummary=YES
SkipLocaleSelection=YES
SkipPackageDisplay=YES
SkipProductKey=YES
SkipRoles=YES
SkipSummary=YES
SkipTaskSequence=YES
SkipTimeZone=YES
SkipUserData=YES
SkipWizard=YES

; ---- Task sequence and locale ----------------------------------------
TaskSequenceID=WIN11-DEPLOY
TimeZone=020
TimeZoneName=Central Standard Time
KeyboardLocale=0409:00000409

; ---- Domain vs. workgroup --------------------------------------------
; To join a domain, replace the block below with:
;   JoinDomain=yourdomain.local
;   DomainAdmin=svc_mdt
;   DomainAdminPassword=<password>
;   DomainAdminDomain=yourdomain.local
;   MachineObjectOU=OU=Workstations,DC=yourdomain,DC=local
JoinWorkgroup=WORKGROUP

; ---- Computer naming -------------------------------------------------
; Uncomment one of these patterns, or leave both commented to keep the
; current name / let the task sequence set one.
;OSDComputerName=PC-%SerialNumber%
;OSDComputerName=WS-%AssetTag%

; ---- No capture, no user data migration ------------------------------
DoCapture=NO
ComputerBackupLocation=NONE
UserDataLocation=NONE

; ---- Post-deploy action ----------------------------------------------
; Restart: machine reboots into Windows (operators see it working)
; Shutdown: machine powers off (operators pull USB and hand to user)
FinishAction=Restart
```

> **SkipFinalSummary=YES is required.** Without it MDT shows a "Deployment
> Complete" dialog that blocks the automated reboot indefinitely.

Click **OK** to close Properties.

The same content is at `configs/mdt/CustomSettings.ini` in this repo as a
reference. The media object (step 12) needs its own copy -- paste it there too.

---

## 6. Windows 11 ADK Compatibility Fixes

MDT 8456 predates Windows 11. Three manual fixes are required before running
**Update Deployment Share** or the WinPE build will fail.

### Fix 1 -- Create the x86 WinPE placeholder

MDT checks for `Boot\x86\LiteTouchPE_x86.wim` and aborts if the folder
does not exist.

1. Open Explorer, navigate to `C:\MDTDeploymentShare\Boot\`.
2. Create folder `x86` (if it does not already exist).
3. Inside `x86`, create an empty file named `LiteTouchPE_x86.wim`. One way:
   open Notepad, immediately File > Save As, navigate to
   `C:\MDTDeploymentShare\Boot\x86\`, set "Save as type" to All Files,
   filename `LiteTouchPE_x86.wim`. The file can be zero bytes -- it only
   needs to exist.

### Fix 2 -- Disable x86 platform

1. Open `C:\MDTDeploymentShare\Control\DeploymentShare.ini` in Notepad.
2. Under the `[Settings]` section, add or change:

   ```ini
   SupportedPlatforms=x64
   ```

3. Save the file.

This tells MDT to build only the x64 WinPE, skipping x86 build steps that
fail on modern ADK.

### Fix 3 -- WSIM path (only if Update Deployment Share fails with a WSIM error)

If step 11 fails with an error mentioning `imgmgr.exe` or "Windows System
Image Manager":

1. Navigate to `C:\Program Files\Microsoft Deployment Toolkit\Bin\`.
2. Open the Deployment Workbench config file (typically
   `DeploymentWorkbench.dll.config` or the Workbench `.exe.config`) in Notepad.
3. Find any reference to `\WSIM\imgmgr.exe` and update it to point to the
   amd64 path:
   ```
   C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\WSIM\imgmgr.exe
   ```
4. Save and restart Deployment Workbench.

> Most installs only need Fix 1 and Fix 2. Fix 3 applies only if you see
> a WSIM-specific error in the update output.

---

## 7. Configure the Task Sequence

Open the task sequence editor: expand **Task Sequences** > right-click
**Windows 11 Enterprise Deployment** > **Properties** > **Task Sequence** tab.

### 7a. Full step audit -- what to disable

Go through every group top to bottom and disable the steps below. To disable
a step: right-click it > **Disable**. Disabled steps show as greyed out and
are skipped at runtime without being deleted.

**State Capture** (top-level group)

Disable the **entire State Capture group**. You are doing fresh deployments --
there is no existing user state to capture.

**Preinstall > New Computer Only**

| Step | Action |
|------|--------|
| Format and Partition Disk **(BIOS)** | **Disable** -- UEFI machines only; keep the UEFI step |
| Offline User State Capture | **Disable** -- no user state to capture |
| Refresh only > Backup | **Disable** -- not doing in-place refresh |
| Enable BitLocker (Offline) | **Disable** -- pre-provisions encryption in WinPE before the OS is applied; conflicts with the State Restore BitLocker step which handles this properly with TPM+PIN |

All other Preinstall steps: keep.

**Install**

Nothing to disable. Both steps (Install Operating System, Next Phase) are required.

**Postinstall**

| Step | Action |
|------|--------|
| Add Windows Recovery (WinRE) | **Disable** -- WinRE is a known BitLocker bypass vector; disabling it removes that attack surface |

All other Postinstall steps: keep.

**State Restore**

| Step | Action |
|------|--------|
| Recover From Domain | **Disable** -- workgroup deployment |
| Opt In to CEIP and WER | **Disable** -- telemetry |
| Windows Update (Pre-Application Install) | **Disable** -- no network at deploy time |
| Windows Update (Post-Application Install) | **Disable** -- no network at deploy time |
| Restore User State | **Disable** -- no USMT migration |
| Restore Groups | **Disable** -- no USMT migration |
| Apply Local GPO Package | **Disable** -- unless you have an LGPO package ready |
| Enable BitLocker (built-in) | **Disable** -- only exposes TPM-only and TPM+USB; replaced by manage-bde steps in Custom Tasks (see 7e) |
| **Imaging** (entire group) | **Disable** -- Sysprep/capture path; not deploying a capture sequence |

All other State Restore steps: keep.

**Summary of what stays enabled:**

- Initialization, Validation, Install, and most of Postinstall run untouched
- In State Restore: Gather, Post-Apply Cleanup, Tattoo, Install Applications,
  Custom Tasks stay on; Enable BitLocker (built-in) is disabled and replaced
  by manage-bde Run Command Line steps you add to Custom Tasks (see 7e)
- You will add your STIG and BitLocker steps to Custom Tasks -- see below

---

### 7b. UEFI Partition Layout

Find the **Format and Partition Disk (UEFI)** step under **Preinstall** >
**New Computer Only**. Click it.

GPT and Disk 0 are already set by default -- leave them.

MDT's default partition list includes a recovery partition at the end. **Delete
it.** The recovery partition hosts WinRE, which is a known BitLocker bypass
attack surface (same reason WinRE is disabled in Postinstall). Removing it
here prevents it from being created on disk at all.

The correct layout after deleting recovery:

| # | Type | File system | Size | Flag |
|---|------|-------------|------|------|
| 1 | EFI System Partition | FAT32 | 499 MB | Boot partition (already flagged) |
| 2 | MSR (Reserved) | (none) | 128 MB | -- |
| 3 | Primary | NTFS | 100% of remaining space | -- |

Click **Apply** to save.


### 7c. Apply Operating System

Find the **Apply Operating System Image** step under **Install**.

- Verify it points to the correct OS entry and the correct index within the WIM.
- To check available indexes from an elevated command prompt:
  ```
  Dism /Get-WimInfo /WimFile:"C:\MDTDeploymentShare\Operating Systems\Windows 11 Enterprise\install.wim"
  ```

### 7d. Rename Built-in Accounts (DoD STIG)

Add these **Run Command Line** steps to State Restore > **Custom Tasks**,
or after **Tattoo**.

To add a step: right-click **Custom Tasks** >
**Add** > **General** > **Run Command Line**.

| Step name | Command line |
|-----------|-------------|
| Rename Administrator to X_Admin | `wmic useraccount where name='Administrator' call rename newname='X_Admin'` |
| Disable X_Admin | `net user X_Admin /active:no` |
| Rename Guest to Visitor | `wmic useraccount where name='Guest' call rename newname='Visitor'` |

See [DoD STIG Steps](#dod-stig-steps) for the full STIG task list including
firewall and security policy steps.

### 7e. BitLocker

The built-in **Enable BitLocker** step only exposes TPM-only and TPM+USB key
options -- there is no TPM+PIN option in the GUI. **Disable the built-in step**
and replace it with four **Run Command Line** steps in State Restore.

Add these steps in order, after your STIG steps and before the end of State
Restore. Right-click **Custom Tasks** > **Add** > **General** >
**Run Command Line** for each.

| Step name | Command line |
|-----------|--------------|
| BitLocker -- Create recovery folder | `cmd /c md D:\BitLocker 2>nul` |
| BitLocker -- Add recovery password | `manage-bde -protectors -add C: -RecoveryPassword` |
| BitLocker -- Save recovery key | `manage-bde -protectors -get C: -Type RecoveryPassword > D:\BitLocker\RecoveryKey.txt` |
| BitLocker -- Add TPM+PIN and encrypt | `manage-bde -protectors -add C: -TPMAndPIN %BDEPin% & manage-bde -on C: -UsedSpaceOnly -skiphardwaretest` |

The PIN comes from `BDEPin` in CustomSettings.ini -- set it there:

```ini
BDEPin=123456
```

Replace `123456` with your deployment PIN (numeric, 6+ digits).

> **BDEPin is plaintext in the ISO.** Anyone with the USB or ISO can read it.
> Treat the ISO like a credential -- physical security and rotating the PIN
> post-deploy are your mitigations.

> `-UsedSpaceOnly` encrypts only the space already written to disk, which is
> much faster than full-disk encryption on a fresh image. Full encryption
> completes in the background after the machine is in service.

### 7f. Computer Name (optional)

To name machines automatically from serial number, add a **Set Task Sequence
Variable** step early in State Restore:

- Variable: `OSDComputerName`
- Value: `PC-%SerialNumber%`

Or uncomment `OSDComputerName=PC-%SerialNumber%` in CustomSettings.ini to
apply it globally.

---

## 8. Add Drivers

Drivers imported here get injected during OS apply (offline DISM injection
before first Windows boot).

### Import drivers

In Deployment Workbench, expand **Deployment Shares** > **your share** >
**Out-of-Box Drivers**.

1. Right-click **Out-of-Box Drivers** > **New Folder** > name it for the
   hardware model (e.g., `Dell Latitude 5540 Win11`).
2. Right-click the new folder > **Import Drivers**.
3. Browse to the folder containing extracted driver `.inf` files.
4. Workbench imports all `.inf` files found recursively. Click **Finish**.

### Target drivers to specific hardware (recommended)

Without selection profiles, MDT injects every driver into every deployment,
causing conflicts across hardware models.

**Create a selection profile:**

In Deployment Workbench, expand **Deployment Shares** > **your share** >
**Advanced Configuration** > **Selection Profiles**.

1. Right-click **Selection Profiles** > **New Selection Profile**.
2. Name it for the hardware (e.g., `Dell Latitude 5540`).
3. In the folder tree, check only the driver folder for that model.
4. Click **Next** > **Finish**.

**Match by model in CustomSettings.ini:**

```ini
[Settings]
Priority=Model,Default

[Dell Latitude 5540]
DriverGroup001=Dell Latitude 5540 Win11

[HP EliteBook 840 G9]
DriverGroup001=HP EliteBook 840 G9 Win11
```

MDT matches `Win32_ComputerSystem.Model` against section headers. To see the
exact model string on a target machine, run from an elevated command prompt:

```
wmic computersystem get model
```

Use that exact string as the section header (spaces and all).

---

## 9. Add Applications

Applications added here install automatically during State Restore.

In Deployment Workbench, expand **Deployment Shares** > **your share** >
**Applications**.

1. Right-click **Applications** > **New Application**.
2. Select **Application with source files**.
3. Fill in the wizard:

   | Field | Value |
   |-------|-------|
   | Application name | Notepad++ 8.6 (or whatever) |
   | Source directory | Folder containing the installer -- **not the .exe itself**, the folder it lives in |
   | Destination directory | Leave default |
   | Command line | The installer filename + silent switches, e.g. `npp.8.6.0.Installer.x64.exe /S` |
   | Working directory | Leave default |

   MDT copies the entire source folder into the deployment share and runs
   the command line from inside it. You browse to a folder, not a file --
   put the `.exe` in its own folder first if it isn't already.

4. Click **Next** > **Finish**.

**To install zero-touch**, two options:

**Option A -- MandatoryApplications in CustomSettings.ini (recommended)**

Get the application GUID: right-click the application in Workbench >
**Properties** -- the GUID is shown at the bottom of the General tab.

Add it to CustomSettings.ini:

```ini
MandatoryApplications001={PASTE-GUID-HERE}
MandatoryApplications002={PASTE-GUID-HERE}
```

The Install Applications step in State Restore reads these automatically
at runtime and installs them in order.

**Option B -- Dedicated task sequence step**

In the task sequence editor, right-click **State Restore** > **Add** >
**General** > **Install Application**. Select the application from the list.
This adds a single-app step you can position anywhere in State Restore.

**Option C -- Bundle script (alternative for many apps)**

Instead of importing each installer separately, create one folder with all
your installers and a script that runs them:

```
Software\
  npp.8.6.0.Installer.x64.exe
  vlc-3.0.21-win64.exe
  7z2301-x64.exe
  install.cmd
```

`install.cmd`:
```cmd
npp.8.6.0.Installer.x64.exe /S
vlc-3.0.21-win64.exe /L=1033 /S
7z2301-x64.exe /S
```

Import the `Software` folder as a single MDT application with command line
`install.cmd`. One GUID in CustomSettings.ini installs everything.

To add or update an app: edit `install.cmd` and swap the `.exe` -- no
Workbench wizard needed again.

Trade-off: the task sequence log shows one step instead of per-app entries,
so a failure requires digging into the cmd output to find which installer broke.

### Dell CCTK (BIOS pre-configuration)

See [docs/CCTK.md](CCTK.md) for the full walkthrough. CCTK is **not** an
MDT Application -- it's a one-shot CLI tool that lives in the deployment
share's `Tools\` folder and is called from a Run Command Line step in
State Restore > Custom Tasks.

---

## 10. Unattend.xml

An `unattend.xml` controls Windows OOBE, account creation, autologon, and
first-boot commands.

MDT picks up a per-task-sequence unattend.xml from:

```
C:\MDTDeploymentShare\Control\WIN11-DEPLOY\unattend.xml
```

Replace `WIN11-DEPLOY` with your task sequence ID if you changed it.

**To install:**

1. Create or edit the unattend.xml. Use `configs/unattend.example.xml` in
   this repo as a starting point. See [docs/UNATTEND.md](UNATTEND.md) for the
   full reference.
2. Copy it to `C:\MDTDeploymentShare\Control\WIN11-DEPLOY\unattend.xml`.
3. Run **Update Deployment Share** (step 11) for MDT to pick it up.

**Validate before deploying:**

```powershell
[xml](Get-Content .\unattend.xml)
```

This throws on XML syntax errors. For schema validation open the file in
Windows System Image Manager (WSIM) -- red entries indicate schema violations.

---

## 11. Update the Deployment Share

Regenerates the WinPE boot image. **Required after any change to drivers,
task sequences, applications, or INI files.**

1. Right-click your deployment share > **Update Deployment Share**.
2. First run: select **Completely regenerate the boot images**.
   Subsequent runs: **Optimize the boot image updating process** (faster).
3. Click **Next** > **Next** and wait.

**Time:** 10-30 minutes. Normal -- not a hang.

Output in `C:\MDTDeploymentShare\Boot\`:
- `LiteTouchPE_x64.iso` -- network-boot ISO (not the standalone USB ISO)
- `LiteTouchPE_x64.wim` -- WinPE boot image used by the media object

---

## 12. Create Media

The Media object builds a self-contained copy of the deployment share that
boots standalone from USB -- no network required at deploy time.

**Create the media object (one-time):**

1. In Deployment Workbench, expand **Deployment Shares** > **your share** >
   **Advanced Configuration** > right-click **Media** > **New Media**.
2. Fill in:

   | Field | Value |
   |-------|-------|
   | Media path | `C:\MDTDeploymentShare\Media` |
   | Media profile | `Everything` (or a selection profile from step 8) |
   | Comments | (optional) |

3. Click **Finish**. Media item **MEDIA001** appears.

### Set the media rules

The media needs its own Bootstrap.ini and CustomSettings.ini -- these are
separate from the deployment share's rules and get baked into the ISO.

1. Right-click **MEDIA001** > **Properties** > **Rules** tab.
2. Click **Edit Bootstrap.ini** and paste:

   ```ini
   [Settings]
   Priority=Default

   [Default]
   DeployRoot=.
   SkipBDDWelcome=YES
   ```

3. In the **Rules** text area, paste the same CustomSettings.ini content
   from step 5.
4. Click **OK**.

> **Why two copies?** The deployment share rules apply for network deployments.
> The media rules are baked into the ISO for standalone USB deployments. Both
> need the same zero-touch settings.

---

## 13. Update Media -- Build the ISO

1. Right-click **MEDIA001** > **Update Media Content**.
2. Click **Next** through the wizard.
3. Wait (10-30 minutes first run; faster on subsequent runs if only content
   changed, not drivers or WinPE).

Output: `C:\MDTDeploymentShare\Media\MEDIA001\LiteTouchMedia_x64.iso`

This is the file you upload and distribute to operators.


---

## 14. Create Bootable USB

Operators use Rufus to write the ISO to USB.

1. Download [Rufus](https://rufus.ie) (portable -- no install needed).
2. Insert a USB drive (16 GB minimum; 32 GB recommended).
3. Open Rufus:

   | Setting | Value |
   |---------|-------|
   | Device | Select your USB drive |
   | Boot selection | Click SELECT > browse to `LiteTouchMedia_x64.iso` |
   | Partition scheme | GPT |
   | Target system | UEFI (non-CSM) |

4. Click **START**. Accept the drive-erase warning.
5. Takes approximately 20 minutes.

**Test boot:** Plug USB into a target machine, press F12 (Dell/Lenovo) or F9
(HP) at POST, select the USB. LiteTouch should skip all screens and start
deploying automatically. If you see wizard screens, check that
`SkipBDDWelcome=YES` is in Bootstrap.ini and all `SkipXxx=YES` lines are in
the media's CustomSettings.ini.

---

## Updating the Image

When a new WIM is available (patch recapture, software update, OS upgrade):

1. Import the new WIM -- Operating Systems > Import Operating System.
2. Update the task sequence: Task Sequence Properties > Task Sequence tab >
   **Apply Operating System** step > select the new WIM.
3. Run **Update Deployment Share** (step 11).
4. Run **Update Media Content** (step 13).
5. Replace the download link with the new ISO.

Operators use the same Rufus process. No instruction changes needed.

---

## Operator Instructions

Send or print this as a card:

---

**Windows Deployment USB -- Operator Steps**

1. Download the ISO from [your link].
2. Download Rufus from https://rufus.ie (free, portable, no install needed).
3. Insert a USB drive (16 GB or larger).
4. Open Rufus. Select the ISO and your USB drive. Leave all settings as
   defaults. Click **START**. Takes about 20 minutes.
5. Plug the USB into the target laptop.
6. Power on. At the manufacturer logo, press:
   - **Dell:** F12  |  **HP:** F9  |  **Lenovo:** F12 or Enter then F12
7. Select the USB from the boot menu.
8. The screen shows "LiteTouch" briefly, then Windows Setup starts
   automatically. Walk away.
9. Deployment takes about 20 minutes. The machine reboots (or shuts down)
   automatically when done.

---

## DoD STIG Steps

Add each as a **Run Command Line** step in State Restore (right-click State
Restore > Add > General > Run Command Line).

### Account hardening

| Step name | Command |
|-----------|---------|
| Rename Administrator to X_Admin | `wmic useraccount where name='Administrator' call rename newname='X_Admin'` |
| Disable X_Admin | `net user X_Admin /active:no` |
| Rename Guest to Visitor | `wmic useraccount where name='Guest' call rename newname='Visitor'` |

### Local security policy

If you have LGPO.exe from the Microsoft Security Compliance Toolkit, add it
as an Application and call it from a Run Command Line step:

```
LGPO.exe /g .\LGPO_PolicyFiles\
```

Or apply a security baseline with secedit:

```
secedit /configure /db C:\Windows\Security\Local.sdb /cfg .\security-baseline.inf /overwrite /quiet
```

Download a Windows 11 security baseline from:
https://www.microsoft.com/en-us/download/details.aspx?id=55319

### Firewall

```
cmd /c netsh advfirewall set allprofiles state on & netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound
```

Add as a Run Command Line step.
