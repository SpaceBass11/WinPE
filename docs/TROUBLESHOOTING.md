# Troubleshooting Guide

For the end-to-end build process, see [docs/RUNBOOK.md](RUNBOOK.md).
For the operator's USB + boot SOP, see [docs/USB_SETUP.md](USB_SETUP.md).

## Operator-facing problems

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Rufus write fails | Bad USB drive or wrong mode | Try a different USB. Use DD mode (Rufus prompts on ISO load). |
| Laptop boots into existing Windows instead of USB | Boot order or wrong entry | Press F12 at POST, select the **UEFI** USB entry. |
| Clonezilla reports "no disk found" | BIOS in RAID mode | Enter BIOS setup, switch SATA mode to AHCI, save, retry. |
| Black screen / "Security Violation" after USB boot | Secure Boot blocking | Disable Secure Boot in BIOS setup. |
| Restore loops back into Clonezilla after first reboot | USB still plugged in | Unplug USB during the post-restore POST. |
| Windows logs in but `BitLocker-RecoveryKey-*.txt` is missing | `Enable-BitLocker.ps1` failed | Check `C:\ProgramData\ManualClonezilla\Logs\Enable-BitLocker.log`. **Do not hand off the machine.** Escalate to admin. |
| BIOS settings did not apply after first boot | Two-POST setting (TPM clear, SATA flip, virt toggle) | Reboot once more to confirm before further troubleshooting. |

## Admin-facing problems

### Sysprep refuses to generalize

**Common causes** on a reference machine:

| Error | Cause | Fix |
|---|---|---|
| `A fatal error occurred while trying to sysprep the machine` | Provisioned AppX with version mismatch between the system account and active user accounts | Open `C:\Windows\System32\Sysprep\Panther\setupact.log`, find the AppX that fails, run `Get-AppxPackage -AllUsers <name> \| Remove-AppxPackage -AllUsers` |
| `Sysprep was not able to validate your Windows installation` | The image has been generalized too many times **or** Windows is already in OOBE state | Check `setupact.log` for the specific reason; reinstall the reference image and start over if rearm limit was hit |
| `0x80073cf2` | Built-in AppX corruption | `Get-AppxPackage -AllUsers \| Where PublisherId -eq '8wekyb3d8bbwe' \| Foreach { Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" }` then retry |

### Clonezilla capture fails or produces an unrestorable image

| Symptom | Cause | Fix |
|---|---|---|
| Capture aborts mid-stream | Source disk has bad sectors | Run `chkdsk /f` on the reference disk before capturing. |
| Restore writes the image but Windows won't boot | Reference machine wasn't sysprepped before capture | Re-sysprep with `sysprep /generalize /oobe /shutdown`, recapture. Don't boot between sysprep and capture. |
| Restore writes the image but Windows boots into specialize loop | Image captured from a machine that had already completed first-boot | Sysprep was either not run or interrupted. Re-sysprep cleanly and recapture. |
| Image is much larger than expected | Reference disk has unused space full of uncompressed data (page file, hiberfile, temp) | Before capture: disable hibernation (`powercfg -h off`), set page file to a small fixed size, clear `%TEMP%` and `%WINDIR%\Temp`. |

### SetupComplete.cmd doesn't run on the deployed machine

| Cause | Fix |
|---|---|
| `SetupComplete.cmd` was only staged in `C:\ProgramData\ManualClonezilla\Scripts\` and not also in `C:\Windows\Setup\Scripts\` | Windows only auto-runs the latter. Recopy on the gold image before sysprep. See [RUNBOOK.md section 2](RUNBOOK.md). |
| Sysprep was run while a Microsoft account was signed in | Some sysprep failure modes silently disable `SetupComplete`. Recapture from a clean reference. |
| The image was already syspreppped previously and is being re-syspreppped without specialize completing | `SetupComplete` only runs on the first specialize pass. Use a fresh reference. |

### Apply-DellConfig fails

See [docs/CCTK.md](CCTK.md#troubleshooting). Common cases:

- `Missing config package` -> `dell-config.cctk` wasn't staged.
- `Missing Dell Command Configure executable` -> DCC wasn't installed
  in the gold image.
- `cctk` exit 116 / 149 -> BIOS password authentication missing.

### New-LocalAccounts fails

| Error in log | Cause | Fix |
|---|---|---|
| `Accounts file not found` | `Config\accounts.csv` wasn't staged in the gold image | Stage it (see `configs/accounts.example.csv`); the chain hard-fails without it. Recapture. |
| `... has an empty Password` / `empty Username` | Malformed CSV row | Fix the row; every account needs a username and password. |
| `... has invalid Role` | Role column isn't `Admin` or `Standard` | Correct the Role value. |

### Set-Level0ACL fails

| Symptom | Cause | Fix |
|---|---|---|
| `Account 'Level 0' does not exist` (hard fail) | `New-LocalAccounts.ps1` didn't create it (missing/renamed CSV row) | Ensure `accounts.csv` has a `Level 0` row; it runs before the ACL step. |
| `Target not found, skipping` (warning, non-fatal) | `C:\Programs` or the Quick Links folder isn't present on this image | Expected if the folder doesn't exist. Create the folder in the gold image if the lockdown is required. |

### Harden-Administrator fails

| Symptom | Cause | Fix |
|---|---|---|
| `Could not locate the built-in Administrator account (RID 500)` | Unusual; account enumeration failed | Check the account exists (`Get-LocalUser`); inspect `Harden-Administrator.log`. |
| Re-run says "already renamed; leaving as-is" | Normal idempotent path on a second run | No action -- the account is found by RID 500 regardless of name. |

### Apply-StigHardening fails

| Error in log | Cause | Fix |
|---|---|---|
| `Unexpected member(s) in 'Administrators'` (hard fail) | An account other than `IT_Admin` + the disabled built-in admin is a local admin | Investigate how it got there (CSV Role, manual change). The whole posture depends on Level 0-3 being standard users. |
| `secedit failed to apply password/lockout policy` | secedit returned non-zero | Check `Apply-StigHardening.log`; inspect `C:\Windows\security\logs\scesrv.log`. |
| `Could not set firewall profiles` (warning, non-fatal) | NetSecurity module stripped from the image | Non-fatal; set firewall posture another way if required. |

### Install-NotepadPP "fails" (non-fatal)

`Install-NotepadPP.ps1` is **non-fatal by design** -- it logs and exits 0
even on failure, so it never aborts the chain. A `installer not found`
or non-zero installer warning in `Install-NotepadPP.log` does **not** stop
deployment. To actually get Notepad++ installed, stage
`Installers\npp-installer.exe` in the gold image.

### Enable-BitLocker fails

| Error in log | Cause | Fix |
|---|---|---|
| `TPM is not present/ready` | Virtual machine without vTPM, or physical TPM disabled/uninitialized | Enable TPM in BIOS; clear+re-own TPM if it was previously used. For VM testing, attach a vTPM. |
| `PIN file not found` | `bitlocker-pin.txt` wasn't staged in the gold image | Stage at `C:\ProgramData\ManualClonezilla\Config\bitlocker-pin.txt` before sysprep, recapture. |
| `PIN file ... is empty` | File present but blank | Put one line of plaintext PIN, no BOM, no leading whitespace. |
| `Expected TpmPin protector missing after enable` | Enable-BitLocker silently downgraded the protector (rare); commonly indicates the "Allow enhanced PINs for startup" policy isn't set and the PIN contains non-numeric characters | Verify the policy is enabled in the gold image: `gpedit.msc` -> Computer Configuration -> Administrative Templates -> Windows Components -> BitLocker Drive Encryption -> Operating System Drives -> "Allow enhanced PINs for startup" = Enabled. Recapture. |
| `RecoveryPassword protector missing after Add-BitLockerKeyProtector` | Rare; check `manage-bde -protectors -get C:` to inspect actual state | Manually `manage-bde -protectors -add C: -RecoveryPassword` and re-export the key. Investigate why the script call failed. |

### Recovery key file not produced

If the protector verification gate passed but the file is missing,
check `C:\ProgramData\ManualClonezilla\Logs\Enable-BitLocker.log`
for an `Export-RecoveryKey` exception trace. The script throws hard
on a missing protector, so a missing file with a successful log means
the file was deleted post-deploy. Cross-check `Finalize-Cleanup.log`.

## Known caveats

These are intentional design choices or environmental constraints, not
bugs. For release history, see [CHANGELOG.md](../CHANGELOG.md).

### CCTK is not redistributable
Dell's EULA for Command | Configure does not allow shipping `cctk.exe`
or HAPI in this repo. The admin installs DCC on the reference machine
during the gold-image build; Clonezilla captures it along with the
rest of the install.

### BitLocker PIN is the same across the fleet
By design. See the [BitLocker PIN trust
model](../README.md#bitlocker-pin-trust-model) in the README.

### Recovery keys are local-only
This workflow is unmanaged (no AD, no MDM). Keys land at
`C:\ProgramData\BitLockers\BitLocker-RecoveryKey-*.txt` (ACL-locked to
administrators) on each deployed machine. Operator SOP is responsible for collecting them
before handoff. If you need centralized escrow, modify
`Export-RecoveryKey` in `scripts/Enable-BitLocker.ps1`.

### Image size is larger than a WIM
Captured Clonezilla images are typically 15-25 GB compressed (vs.
4-7 GB for a WIM). USB drives need 32 GB+ to comfortably hold the
ISO plus working space.

### One image per hardware family
Drivers are baked in. New laptop model = new gold image = new ISO.
This is the workflow's accepted-risk position; if you have many
families, the WinPE per-machine workflow on `main` is a better fit.
