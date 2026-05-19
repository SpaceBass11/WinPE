# Script Reference

> This reference covers the MDT standalone media scripts. The WinPE tool scripts (unified_winpe_deploy.ps1, etc.) are on the main branch.

Parameter reference for the MDT scripts in `scripts/mdt/`. For
architecture and design rationale see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## MDT Scripts (`scripts/mdt/`)

These run on the **admin workstation** to build the operator payload. Requires
MDT 8456 and ADK installed.

### Initialize-MDTDeploymentShare.ps1

One-time setup: creates the MDT deployment share, imports WIM(s), creates a
task sequence per OS (UEFI GPT layout), and writes zero-touch
`CustomSettings.ini` / `Bootstrap.ini`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-SharePath` | string | `C:\MDTDeploymentShare` | Local path for the deployment share |
| `-WimPaths` | string[] | `@()` | One or more `.wim`/`.esd` files to import; each becomes an OS + task sequence |
| `-OrgName` | string | `My Organization` | Organization name embedded in task sequences |
| `-TimeZone` | string | `Central Standard Time` | Windows time-zone name (`tzutil /l` to list valid names) |
| `-BDEPin` | String | `''` (empty) | BitLocker startup PIN. Alphanumeric, 6+ chars. Same value used for C: TPM+PIN and data drive password. Leave blank to skip BitLocker entirely (VMs, non-TPM hardware). |
| `-FinishAction` | String | `'REBOOT'` | Post-deployment action baked into CustomSettings.ini. Valid values: `REBOOT` or `SHUTDOWN`. |
| `-OSDComputerName` | String | `''` (empty) | Computer naming pattern. Empty = Windows random name. `%SerialNumber%` = service tag/serial. Fixed string = same name on every machine (test only). |

```powershell
# Typical first-time setup
.\scripts\mdt\Initialize-MDTDeploymentShare.ps1 `
    -WimPaths 'C:\images\Win11_Pro_24H2.wim' `
    -OrgName  'Contoso IT'

# Multiple WIMs, different share path
.\scripts\mdt\Initialize-MDTDeploymentShare.ps1 `
    -SharePath 'D:\MDT' `
    -WimPaths 'C:\images\Win11_Pro.wim','C:\images\Win10_LTSC.wim' `
    -OrgName  'Contoso IT' `
    -TimeZone 'Eastern Standard Time'
```

---

### Import-WimImages.ps1

Add one or more WIMs to an existing deployment share. Optionally creates task
sequences and re-runs `Update-MDTDeploymentShare` to regenerate `LiteTouchPE_x64.wim`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-SharePath` | string | `C:\MDTDeploymentShare` | Local path to the existing deployment share |
| `-WimPaths` | string[] | `@()` | Explicit WIM/ESD file paths to import |
| `-WimFolder` | string | — | Folder to scan for `*.wim`/`*.esd`; ignored if `-WimPaths` is set |
| `-CreateTaskSequences` | bool | `$true` | Create a task sequence for each imported OS |
| `-OrgName` | string | `My Organization` | Organization name for task sequences |
| `-UpdateShare` | bool | `$true` | Re-run `Update-MDTDeploymentShare` after import to regenerate boot.wim |

```powershell
# Import a single new OS
.\scripts\mdt\Import-WimImages.ps1 -WimPaths 'C:\images\Win11_Ent_24H2.wim'

# Import all WIMs in a folder, skip task sequence creation
.\scripts\mdt\Import-WimImages.ps1 -WimFolder 'C:\images' -CreateTaskSequences:$false
```

---

### New-MDTMedia.ps1

Build the operator payload ISO (`LiteTouchMedia_x64.iso`). Run this every
time you want to publish an updated payload. The ISO is self-contained — no
network required when operators use it.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-SharePath` | string | `C:\MDTDeploymentShare` | Local path to the MDT deployment share |
| `-OutputPath` | string | `C:\MDTMedia` | Where to write media files and the final ISO |
| `-MediaName` | string | `MEDIA001` | MDT media object name; leave at default unless managing multiple media targets |
| `-SelectionProfile` | string | `Everything` | Content to include; create a named profile in MDT Workbench to limit ISO size (e.g. one OS only) |

```powershell
# Standard build — generates C:\MDTMedia\LiteTouchMedia_x64.iso
.\scripts\mdt\New-MDTMedia.ps1

# Custom output folder
.\scripts\mdt\New-MDTMedia.ps1 -OutputPath 'D:\Payloads\Win11_24H2'
```

---

### Enable-BitLocker.ps1

Encrypts C: with TPM + enhanced startup PIN (XTS-AES-256) and data drives
with the same string as a BitLocker password with auto-unlock. Recovery keys
are written to the recovery path before encryption starts.

Called automatically by the MDT task sequence State Restore step. Can also
be run manually post-deployment to re-apply BitLocker.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Pin` | String | `''` | Enhanced startup PIN for C: and password for data drives. Empty = skip BitLocker. |
| `-RecoveryPath` | String | `D:\BitLocker` | Folder where recovery key .txt files are saved before encryption starts. |
| `-DataDrives` | String[] | `@('D:')` | Data drives to encrypt with password + auto-unlock. Non-existent drives are skipped. |

```powershell
# Typically invoked by the task sequence as:
powershell.exe -ExecutionPolicy Bypass -NonInteractive `
    -File "%SCRIPTROOT%\Enable-BitLocker.ps1" -Pin "%BDEPin%"

# Manual re-application post-deployment
.\scripts\mdt\Enable-BitLocker.ps1 -Pin 'MyAlphanumericPIN' -RecoveryPath 'E:\Keys'
```
