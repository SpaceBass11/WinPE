# BitLocker / data-disk setup

The deploy tool can optionally:

1. Wipe an additional internal disk and format it as an NTFS data
   volume (`D:`) in the same diskpart run that lays out the primary
   Windows disk.
2. Stage a `SetupComplete.cmd` that enables BitLocker on first boot —
   TPM + Enhanced PIN on `C:`, and (if a data disk was created)
   recovery-key protector + auto-unlock on `D:`.

Both behaviors are **opt-in**. Nothing happens unless the operator
passes the matching parameters.

> [!WARNING]
> Like every other destructive operation in this tool, `-DataDiskNumber`
> issues `clean` against a physical disk and is irreversible. Verify
> the disk number against `diskpart > list disk` and re-read the typed
> `WIPE DATA` confirmation before pressing Enter.

## Why opt-in

Older v4.6.x snapshots hard-coded `DataDiskNumber = 1` and shipped a
default startup PIN. Either could surprise an operator with a silent
extra-disk wipe or leak a known PIN into the fleet. v4.7.0 changes
both to off and requires the operator to supply the PIN at deploy
time.

## Parameters

| Parameter | Effect |
|-----------|--------|
| `-DataDiskNumber <int>` | Disk number to wipe + format as `D:`. `-1` (default) means no second disk. Validated: must exist, must not be the target disk, must not be USB, must not be the system disk. |
| `-EnableBitLocker` | Stage `bitlocker-setup.ps1` + `SetupComplete.cmd` into `C:\Windows\Setup\Scripts\` so Windows runs them after OOBE. |
| `-BitLockerPin <string>` | Startup PIN for TPM+PIN on `C:`. Required when `-EnableBitLocker`. 6-20 characters (Windows Enhanced PIN window — the only thing the script enforces; PIN content is the admin's call). In non-silent mode, the script prompts at the WinPE console if this is omitted. |
| `-BitLockerKeyPath <path>` | Override the recovery-key escrow location. Accepts a UNC share (e.g. `\\fileserver\BitLockerKeys`) or a fixed-disk path on the deployed machine. Default: look up the IMAGES partition by volume label at first-boot time and write to `<letter>:\BitLockerKeys` — requires the USB to remain plugged in through the first reboot. |

`-DataDiskNumber` and `-EnableBitLocker` are independent — you can use
either alone:

- `-DataDiskNumber 1` (no `-EnableBitLocker`): just lay down an NTFS
  data partition, no encryption.
- `-EnableBitLocker -BitLockerPin '...'` (no `-DataDiskNumber`):
  encrypt only `C:`. The staged script skips D:-related steps.
- Both together: `C:` gets TPM+PIN, `D:` gets recovery-key with
  auto-unlock tied to `C:`.

## Confirmation chain

| Trigger | Prompt | Skipped by `-Force`? |
|---------|--------|----------------------|
| `-DataDiskNumber` set | Type `WIPE DATA` | Yes |
| `-DataDiskNumber` is the system disk | (refused outright) | No |
| `-EnableBitLocker` with placeholder PIN | (refused outright) | No |
| `-Silent -DataDiskNumber N` without `-Force` | (refused; `WIPE DATA` cannot prompt) | n/a |

The existing `ERASE` / `DESTROY SYSTEM` / `WIPE ALL` chain for the
primary target and additional wipes is unchanged.

## Recovery-key escrow

Recovery keys are written via `Add-BitLockerKeyProtector
-RecoveryKeyProtector -RecoveryKeyPath <dir>` on first boot, with
the location picked in this precedence:

1. **`-BitLockerKeyPath` if given** — literal path. Use a UNC share
   or a fixed-disk path on the deployed machine. USB can be removed
   immediately after deploy.
2. **IMAGES partition (default)** — the staged first-boot script
   calls `Get-Volume -FileSystemLabel 'IMAGES' | Select -First 1`
   and writes to `<letter>:\BitLockerKeys`. **The USB must remain
   plugged in through the first reboot.** Looking up by label
   (rather than by the WinPE-time drive letter) means escrow works
   even when Windows reassigns the USB to a different letter than
   WinPE used — e.g. WinPE `I:` → Windows `D:`.
3. **`C:\Windows\Setup\BitLockerKeys` (fallback, with warning)** —
   used at deploy time when `$env:DEPLOY_IMAGE_DRIVE` is unset, and
   at first-boot time when `Get-Volume -FileSystemLabel 'IMAGES'`
   returns nothing (USB unplugged, partition relabeled, etc.).

> [!IMPORTANT]
> The fallback path (option 3) lands the recovery key on the volume
> it's protecting. If `C:` ever can't unlock — TPM reset, board
> swap, firmware change — the recovery key stored on `C:` is
> unreachable, and the auto-unlock metadata for `D:` lives in `C:`'s
> metadata, so `D:` is unreachable too. Always check
> `C:\Windows\Setup\Scripts\bitlocker-setup.log` after first boot to
> confirm which path was used.

## How the first-boot stage works

`Initialize-BitLockerSetup` writes two files to the applied image at
`C:\Windows\Setup\Scripts\`:

- `bitlocker-setup.ps1` — runs `Enable-BitLocker` for `C:` (TPM+PIN)
  and, if `-DataDiskNumber` was used, also for `D:` (recovery-key +
  auto-unlock). Logs to `C:\Windows\Setup\Scripts\bitlocker-setup.log`.
  The body runs inside a `try { ... } finally { ... }`, and the
  `finally` always self-deletes both this script and `SetupComplete.cmd`
  — even if `Enable-BitLocker` throws on C: — so the plaintext PIN never
  lingers on disk. The log file persists either way for diagnosis.
- `SetupComplete.cmd` — Windows runs this once, after OOBE completes,
  with `SYSTEM` privileges. It just launches the `.ps1` above and
  redirects output to `setupcomplete.log`.

After the encryption initializes, the script reboots the machine
(`shutdown.exe /r /t 15`) so BitLocker can finalize against the TPM.

## Failure modes worth knowing

- **`unattend.xml` `<AutoLogon><LogonCount>1</LogonCount>` interaction:**
  the first OOBE pass consumes one count; the reboot at the end of the
  BitLocker script doesn't trigger another AutoLogon. If your unattend
  depends on a second AutoLogon for follow-up provisioning, set
  `LogonCount` to 2 or higher.
- **Recovery key unreachable on D:** (legacy issue from v4.6.x) — fixed
  in v4.7.0 by escrowing off-volume. If you upgraded an existing fleet,
  rotate the C: recovery key on those machines through
  `manage-bde -protectors -add C: -RecoveryPassword` and save the
  output to your real escrow location.
- **TPM not present / not provisioned:** `Enable-BitLocker
  -TpmAndPinProtector` will fail. The script logs the exception, wipes
  the PIN-bearing staging scripts (see below), and exits non-zero
  without rebooting. Check `bitlocker-setup.log` for the failure.
  Typical fix: `manage-bde -tpm -takeownership` or enable TPM in BIOS
  (CCTK can automate this — see [CCTK.md](CCTK.md)). Re-running
  `unified_winpe_deploy.ps1` (full reinstall) is the cleanest retry
  path; in-place re-enrolment after BIOS fixes can also be done with
  `manage-bde -on C: -tp <PIN> -RecoveryPassword`.
- **Plaintext PIN on disk:** between deploy and first boot, the PIN
  exists in `C:\Windows\Setup\Scripts\bitlocker-setup.ps1`. The script
  self-deletes after use *on every code path* (success or
  Enable-BitLocker failure) via a `try/finally`, so a TPM fault on C:
  no longer leaves the PIN file behind. The only window where the file
  can linger is between WIM-apply and the first `SetupComplete.cmd`
  run — i.e. the operator powers down between deploy and OOBE. Treat
  the staged image as a pre-shared credential and don't ship `C:`
  images across an org with this staging in place.

## Example invocations

```powershell
# Interactive: prompt for everything except the PIN and the data disk
.\unified_winpe_deploy.ps1 `
    -DataDiskNumber 1 `
    -EnableBitLocker `
    -BitLockerPin 'CorrectHorse42'

# Interactive with TUI PIN prompt: omit -BitLockerPin in non-silent mode
# and the script prompts via Read-Host. PIN is visible on screen so the
# operator can verify what they typed (and is plaintext downstream in
# bitlocker-setup.ps1 anyway, so hiding it would be theater).
.\unified_winpe_deploy.ps1 -DataDiskNumber 1 -EnableBitLocker

# Silent / scripted: -Force is mandatory for the WIPE DATA bypass.
# Silent mode requires -BitLockerPin - it does NOT prompt (would deadlock
# an unattended deploy).
.\unified_winpe_deploy.ps1 -Silent -Force `
    -WimFile 'I:\images\Win11_Enterprise.wim' `
    -TargetDisk 0 `
    -DataDiskNumber 1 `
    -EnableBitLocker `
    -BitLockerPin 'CorrectHorse42' `
    -BitLockerKeyPath '\\fileserver\BitLockerKeys'

# Encryption only, no extra data disk
.\unified_winpe_deploy.ps1 -EnableBitLocker -BitLockerPin 'CorrectHorse42'
```
