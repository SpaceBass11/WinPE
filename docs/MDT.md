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

Open **MDT Deployment Workbench** → Task Sequences → double-click your TS.
Common changes:
- **Locale / timezone** — Update `TimeZoneName` in `configs/mdt/CustomSettings.ini`
- **Computer naming** — Set `OSDComputerName=%SerialNumber%` for serial-based names
- **Admin password** — Set `AdminPassword=` in CustomSettings.ini
- **Unattend.xml** — Right-click TS → Properties → OS Info → Edit Unattend.xml
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

Drop drivers into the deployment share before building media:

```powershell
Import-Module 'C:\Program Files\Microsoft Deployment Toolkit\bin\MicrosoftDeploymentToolkit.psd1'
New-PSDrive -Name 'DS001' -PSProvider MDTProvider -Root 'C:\MDTDeploymentShare' -Verbose:$false

# Import a folder of drivers (INF files)
Import-MDTDriver -Path 'DS001:\Out-of-Box Drivers\Dell\Latitude5540' `
    -SourcePath 'C:\Drivers\Dell\Latitude5540'
```

MDT injects the matching driver during the "Inject Drivers" task sequence
step based on Plug and Play IDs. Rebuild the media after adding drivers.

## Dell CCTK (BIOS Pre-Configuration)

To apply BIOS settings before Windows images (AHCI mode, Secure Boot, etc.),
add CCTK as an MDT Application and insert it before the "Apply OS" step.

```powershell
# After mounting DS001:
Import-MDTApplication -Path 'DS001:\Applications' `
    -Name         'Dell CCTK - BIOS Config' `
    -ShortName    'Dell-CCTK' `
    -CommandLine  'cctk.exe --infile="%DEPLOYROOT%\Applications\Dell-CCTK\configs\default.ini"' `
    -WorkingDirectory '.\Applications\Dell-CCTK\bin' `
    -ApplicationSourcePath 'C:\Path\To\Dell\CommandConfigure\X86_64' `
    -DestinationFolder 'Dell-CCTK'
```

Drop your CCTK config files under:
```
DeploymentShare\Applications\Dell-CCTK\configs\
├── default.ini       ← catch-all
├── OptiPlex7090.ini  ← per-model
└── 1A2B3C4.ini       ← per-service-tag
```

In the task sequence, move the CCTK application step to run *before*
"Format and Partition Disk". CCTK changes queue in BIOS and activate on
the next POST (the post-deploy reboot) — same behavior as the USB tool.

> [!IMPORTANT]
> CCTK binaries are not redistributable. Copy them to the deployment share
> manually; do not commit them to this repo.

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
