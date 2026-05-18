# MDT as a USB Payload Factory — Full Reference

MDT's **standalone media** feature lets you build a single self-contained
bootable ISO on your admin workstation. That ISO becomes the payload —
copy it to a USB stick and it carries everything: WinPE, the task sequence,
the WIM, all drivers, and the zero-touch config. No deployment server,
no network share, no PXE, no credentials. The operator never touches MDT;
they just boot a laptop and walk away.

```
Admin workstation (one-time setup, then per update)
  │
  ├── Install MDT + ADK
  ├── Create deployment share  ←  your "kitchen"
  ├── Import WIM(s)
  ├── Create task sequence(s)  ←  hardcode everything here
  ├── Configure for zero-touch
  └── Build media ISO          ←  the "payload"
          │
          ▼
  Upload ISO to download link
          │
          ▼
  Operator downloads ISO
  Rufus → USB (one click, ~20 min)
          │
          ▼
  Boot laptop from USB
  Fully automated: partitions, applies image, reboots
  No prompts. No decisions.
```

The USB is entirely self-contained. No network required at deploy time.
Updating the image means rebuilding the ISO once and replacing the download link.

For the three-command quick start, see the [README](../README.md).

## Prerequisites

Install in this order on your **admin workstation** (not the target laptops):

1. **Windows ADK** — select *Deployment Tools* only
   [Download](https://docs.microsoft.com/en-us/windows-hardware/get-started/adk-install)

2. **Windows ADK WinPE add-on** — separate installer, same page

3. **MDT 8456**
   [Download](https://www.microsoft.com/en-us/download/details.aspx?id=54259)

4. **MDT hotfix KB4564442** — required for Windows 11 UEFI deployments
   [Download](https://support.microsoft.com/en-us/topic/windows-10-deployments-fail-with-microsoft-deployment-toolkit-on-computers-with-bios-type-firmware-70557b0b-6be3-81d2-556f-b313e29e2cb7)

One admin workstation serves as the build machine indefinitely. The ISO it
produces is handed off; the workstation itself never goes to a deployment site.

## Setup (Run Once)

The three scripts below automate the initial setup. Every step can also be done
via **MDT Deployment Workbench** (the GUI). The scripts are useful for
repeatable or automated builds; the Workbench is useful for one-off changes,
debugging, and browsing the share structure.

### Step 1 — Create the deployment share and import your WIM

```powershell
# Admin PowerShell — elevated
.\scripts\mdt\Initialize-MDTDeploymentShare.ps1 `
    -WimPaths 'C:\images\Win11_Pro_24H2.wim' `
    -OrgName  'Contoso IT'
```

This creates `C:\MDTDeploymentShare` and an SMB share (local only, used by
MDT tooling — not exposed to operators). It also creates a task sequence
named `DEPLOY-WIN11-PRO` pre-configured for zero-touch UEFI deployment.

### Step 2 — Tune the task sequence (optional)

Open **MDT Deployment Workbench** → expand your deployment share → **Task
Sequences** → double-click your TS to open its properties → click the **Task
Sequence** tab to view and edit individual steps.

Common changes:
- **Locale / timezone** — Update `TimeZoneName` in `configs/mdt/CustomSettings.ini`
- **Computer naming** — Set `OSDComputerName=%SerialNumber%` for serial-based names
- **Admin password** — Set `AdminPassword=` in CustomSettings.ini
- **Unattend.xml** — Right-click TS → **Properties** → **OS Info** tab → **Edit Unattend.xml**
  (use `configs/unattend.example.xml` as a starting point if you have one)

### Step 3 — Build the payload ISO

```powershell
.\scripts\mdt\New-MDTMedia.ps1 -OutputPath 'C:\MDTMedia'
```

Takes 10–30 minutes the first time (copies the WIM into the media). Output:

```
C:\MDTMedia\
└── LiteTouchMedia_x64.iso   ← this is your payload
```

Upload `LiteTouchMedia_x64.iso` to your download link.

## Operator Instructions

Give operators these steps (nothing else required):

1. Download `LiteTouchMedia_x64.iso` from your shared download link.
2. Open [Rufus](https://rufus.ie), select the ISO, select the USB drive,
   click **START**. Wait ~20 minutes for the write to complete.
3. Plug the USB into the target laptop, boot from USB (F12 boot menu,
   or set USB first in BIOS boot order). Walk away.

The laptop partitions itself, applies the Windows image, runs the task
sequence, and reboots fully unattended. No menus, no prompts, no decisions.

> **Note:** Remove the USB before the post-deploy reboot completes, or the
> laptop will loop back into the installer.

## How Zero-Touch Works

`configs/mdt/Bootstrap.ini` is baked into the WinPE image. The key line:

```ini
DeployRoot=.
```

This tells LiteTouch "the deployment share is on the same media you booted
from" — no network, no credentials, no server.

`configs/mdt/CustomSettings.ini` (also baked in) suppresses every wizard
page and hardcodes all settings:

```ini
SkipBDDWelcome=YES
SkipTaskSequence=YES
TaskSequenceID=DEPLOY-WIN11-PRO
OSDDiskIndex=0
SkipSummary=YES
FinishAction=REBOOT
```

The operator sees a brief "LiteTouch is initializing" splash and then the
progress bar. No decisions needed.

## Updating the Payload

When you update the WIM, add drivers, or change settings:

```powershell
# Re-import the new WIM (or skip if WIM hasn't changed)
.\scripts\mdt\Import-WimImages.ps1 -WimPaths 'C:\images\Win11_Pro_24H2_v2.wim'

# Rebuild the ISO
.\scripts\mdt\New-MDTMedia.ps1 -OutputPath 'C:\MDTMedia'

# Upload C:\MDTMedia\LiteTouchMedia_x64.iso to replace the old download link
```

Existing operators with the old USB keep working until they re-download.
The build process is fully repeatable — run it as many times as you like.

## Adding Drivers

Drop drivers into the deployment share before building media.

**Using MDT Workbench (GUI):**

1. Open **Deployment Workbench** → expand your deployment share → expand **Out-of-Box Drivers**.
2. Right-click **Out-of-Box Drivers** → **New Folder**. Name it after the model (e.g., `Dell Latitude 5540`).
3. Right-click the new folder → **Import Drivers**.
4. Browse to your driver folder (must contain `.inf` files). MDT scans recursively.
5. Click **Next** through the wizard. MDT copies the drivers into the share.
6. After all drivers are imported, right-click the deployment share root → **Update Deployment Share** → complete the wizard to regenerate boot.wim.

**Using PowerShell (scriptable / repeatable):**

```powershell
Import-Module 'C:\Program Files\Microsoft Deployment Toolkit\bin\MicrosoftDeploymentToolkit.psd1'
New-PSDrive -Name 'DS001' -PSProvider MDTProvider -Root 'C:\MDTDeploymentShare' -Verbose:$false

# Import a folder of drivers (INF files)
Import-MDTDriver -Path 'DS001:\Out-of-Box Drivers\Dell\Latitude5540' `
    -SourcePath 'C:\Drivers\Dell\Latitude5540'
```

MDT injects the matching driver during the "Inject Drivers" task sequence
step based on Plug and Play IDs.

After adding drivers, rebuild the media: `.\scripts\mdt\New-MDTMedia.ps1`

## Dell CCTK (BIOS Pre-Configuration)

To apply BIOS settings before Windows images (AHCI mode, Secure Boot, etc.),
add CCTK as an MDT Application and insert it before the "Apply OS" step.

**Quick reference — MDT Application (GUI):**

1. Open **Deployment Workbench** → **Applications** → **New Application** → *Application with source files*.
2. Source: your local Dell Command | Configure `X86_64` folder.
3. Command line: `cctk.exe --infile="%DEPLOYROOT%\Applications\Dell-CCTK\configs\default.ini"`
4. Working directory: `.\Applications\Dell-CCTK\bin`
5. In the task sequence editor, drag the application step to run *before* **Format and Partition Disk**.

See [docs/CCTK.md](CCTK.md) for the full walkthrough including PowerShell
import, config file layout, per-model targeting, and troubleshooting.

> [!IMPORTANT]
> CCTK binaries are not redistributable. Copy them to the deployment share
> manually; do not commit them to this repo.

## BitLocker Encryption

BitLocker is configured automatically during the MDT State Restore phase.
C: is encrypted with TPM + an enhanced startup PIN (alphanumeric allowed).
Data drives (D: by default) are encrypted with the same string used as a
BitLocker password and have auto-unlock enabled so the operator never types
a second PIN. Recovery keys are written to D:\BitLocker\ **before** D: is
encrypted, so they remain accessible immediately after deployment.

### Step 1 — Set the PIN in CustomSettings.ini

```ini
; In configs/mdt/CustomSettings.ini
BDEPin=YourPinHere
```

`BDEPin` is left blank in the repo — fill it in before rebuilding the ISO.
Leave it blank to skip BitLocker entirely on that build (useful for VMs or
hardware without a TPM).

### Step 2 — Rebuild the ISO

```powershell
.\scripts\mdt\New-MDTMedia.ps1
```

`Enable-BitLocker.ps1` and the task sequence step are already wired in by
`Initialize-MDTDeploymentShare.ps1` — no manual setup needed.

### Verifying the task sequence step (Workbench GUI)

Open **Deployment Workbench** → **Task Sequences** → double-click your TS →
**Task Sequence** tab → scroll to the **State Restore** group → find the
**Enable BitLocker** step. Verify it is present and enabled. Click the
**Options** tab and confirm the condition reads **BDEPin not equals ""** —
this ensures the step is a no-op when `BDEPin` is empty.

> **Note:** If the step is missing (e.g., after Workbench re-saved the TS),
> re-run `Initialize-MDTDeploymentShare.ps1` to reapply it.

### Adding the step manually (Workbench GUI)

For admins who need to add it by hand:

1. In the **State Restore** group, right-click → **Add** → **General** →
   **Run Command Line**.
2. Set **Name** to `Enable BitLocker`.
3. Set **Command line** to:
   ```
   powershell.exe -ExecutionPolicy Bypass -NonInteractive -File "%SCRIPTROOT%\Enable-BitLocker.ps1" -Pin "%BDEPin%"
   ```
4. Click the **Options** tab → **Add Condition** → **Task Sequence Variable**
   → set `BDEPin` **not equals** `""`.

### Hardware requirements

- Windows 11 Pro or Enterprise (BitLocker is not available on Home editions)
- TPM 2.0 enabled and cleared in BIOS (CCTK can automate this — see [docs/CCTK.md](CCTK.md))
- UEFI boot mode (already enforced by the task sequence GPT disk layout)

### Recovery keys

Recovery keys are saved to `D:\BitLocker\` as plain-text files
(`C_RecoveryKey.txt`, `D_RecoveryKey.txt`) before encryption starts. After
deployment:

- **C:** unlocks via TPM + PIN at every boot.
- **D:** auto-unlocks when C: is unlocked — no second PIN needed.
- If the TPM is cleared or the drive is moved to another machine, boot from
  recovery media and supply the key from `D_RecoveryKey.txt` (keep a copy
  somewhere safe, as D: will be locked at that point).

## Deployment Share Structure

```
C:\MDTDeploymentShare\
├── Boot\
│   └── LiteTouchPE_x64.wim        ← WinPE boot image
├── Operating Systems\
│   └── Win11_Pro_24H2\             ← imported WIM files live here
├── Task Sequences\
│   └── DEPLOY-WIN11-PRO\
├── Applications\
│   └── Dell-CCTK\                  ← optional
├── Out-of-Box Drivers\             ← optional, per-model driver packages
└── Control\
    ├── CustomSettings.ini          ← configs/mdt/CustomSettings.ini
    └── Bootstrap.ini               ← configs/mdt/Bootstrap.ini
```

The deployment share is your build environment. The ISO (`LiteTouchMedia_x64.iso`)
is a snapshot of it at build time — operators never touch the share itself.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Rufus writes fail / ISO not bootable | Use **DD image mode** in Rufus if GPT/UEFI mode fails |
| Task sequence not found at boot | `TaskSequenceID=` in CustomSettings.ini must match exactly (case-sensitive) |
| Laptop boots to Windows instead of USB | Set USB first in BIOS boot order, or use F12 boot menu |
| Laptop reboots back to USB install loop | Remove USB before the post-deploy reboot completes |
| Apply fails with "Incorrect function" | WinPE is missing `NtfsEnableDirCaseSensitivity` registry key — see `scripts/build_boot_wim.ps1` in this repo for how to bake it into WinPE, or add it via a custom MDT WinPE profile |
| MDT WinPE won't start on some UEFI laptops | Disable Secure Boot on the target, or sign the WinPE boot files |
| Deploy completes but Windows won't boot | Verify BIOS is in UEFI mode (not Legacy/CSM) — the task sequence creates a GPT disk |
