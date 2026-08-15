# Per-USB deploy.args

Drop a one-line text file named `deploy.args` at the root of the
IMAGES partition. When `startnet.cmd` boots, it reads the line and
passes it verbatim to `unified_winpe_deploy.ps1`. No `boot.wim`
rebuild required for a different deploy profile — just edit the file.

## Quick start

1. Copy [`configs/deploy.args.example`](../configs/deploy.args.example)
   to the IMAGES partition root as `deploy.args`.
2. Edit the parameters for this USB.
3. Plug into the target, boot, walk away.

Example contents (one line):

```text
-WimFile "I:\images\Win11_Enterprise.wim" -TargetDisk 0 -UnattendFile "I:\configs\unattend.xml" -DataDiskNumber 1 -EnableBitLocker -BitLockerPin "ReplaceWithYourPin42" -Force -Silent
```

If `deploy.args` is missing, `startnet.cmd` launches the script
**without arguments** — same as before, fully interactive TUI.

## How it works

`startnet.cmd` (written by `scripts/build_boot_wim.ps1`) does this
after locating the IMAGES partition:

```cmd
set "DEPLOYARGS="
if defined DEPLOY_IMAGE_DRIVE (
    if exist "%DEPLOY_IMAGE_DRIVE%\deploy.args" (
        set /p DEPLOYARGS=<"%DEPLOY_IMAGE_DRIVE%\deploy.args"
        echo Loaded deploy args from %DEPLOY_IMAGE_DRIVE%\deploy.args
        echo   Parameters loaded. Secrets, if present, are not displayed.
    )
)
if defined DEPLOY_IMAGE_DRIVE (
    if defined DEPLOYARGS (
        set "DEPLOYARGS=!DEPLOYARGS:{DRIVE}=%DEPLOY_IMAGE_DRIVE%!"
    )
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\scripts\unified_winpe_deploy.ps1 !DEPLOYARGS!
```

The raw args are **not** echoed. `startnet.cmd` confirms only that
a `deploy.args` was loaded — never its contents — so a BitLocker
PIN or other secret in the file does not appear on the WinPE
console, KVM, or any over-the-shoulder view. To inspect the args,
read the file from the IMAGES partition directly.

## The `{DRIVE}` placeholder

`startnet.cmd` substitutes every literal `{DRIVE}` in the args
line with the letter of the IMAGES partition (whatever WinPE
assigned it — `D:`, `E:`, `I:`, etc.) before handing the line to
PowerShell. Use it whenever the deploy paths live on the same USB
as WinPE and you can't predict what letter WinPE will pick:

```text
-WimFile "{DRIVE}\images\Win11_Pro.wim" -TargetDisk 0 -UnattendFile "{DRIVE}\configs\unattend.xml" -Force -Silent
```

This is the form [`scripts/build_iso.ps1`](../scripts/build_iso.ps1)
writes into the ISO's `deploy.args` automatically — a single ISO
that Rufus flashes to any USB still boots and finds its own WIM.

Hard-coded drive letters (`I:\images\...`) also work and are
appropriate for the legacy two-partition workflow where you
control both the WinPE and IMAGES partitions and know their
letters. Pick whichever fits how the USB was built:

| USB layout | Recommended path form |
|------------|-----------------------|
| Two-partition USB you partitioned yourself, letters stable | Absolute (`I:\images\...`) |
| Single ISO from `build_iso.ps1`, or any USB where the letter is unpredictable | `{DRIVE}\images\...` |

If `DEPLOY_IMAGE_DRIVE` is unset (rare — the IMAGES-label probe
failed), the substitution is skipped and any `{DRIVE}` tokens
reach PowerShell literally, which produces an obvious "path not
found" error rather than a silent wrong-target deploy.

## Constraints

- **Single line.** `set /p` reads only the first line of the file.
  If you need more parameters than fit on one line, stop using
  `deploy.args` and rebuild `boot.wim` with a customized
  `startnet.cmd`.
- **Quoting follows cmd.exe rules.** Wrap paths with spaces in
  double quotes. PowerShell re-parses the args on its end so the
  normal `-Param "value"` pattern works.
- **No environment-variable expansion** beyond what cmd.exe and
  startnet.cmd already set. Two things are available: the
  `{DRIVE}` placeholder documented above (substituted before
  PowerShell launches) and `%DEPLOY_IMAGE_DRIVE%` if you want to
  reference it in a customized `startnet.cmd` rebuild.

## Security caveat — same as CCTK

> [!WARNING]
> `deploy.args` lives in plaintext on the data partition. Anyone with
> physical access to the USB can read any embedded secret, including
> BitLocker PINs. The USB is the trust boundary.

Same trust model as the CCTK configs (see [`CCTK.md`](CCTK.md#security-honest-accounting)). Mitigations:

- Use a unique PIN per USB.
- Store the USB in the same locker as the laptops it deploys.
- For higher-assurance environments, leave `deploy.args` off the
  USB and run the deploy interactively, typing the PIN at the
  prompt (the v4.7.0 `WIPE DATA` + PIN gates work the same way
  whether they came from `-Force -Silent` args or interactive
  Read-Host).

## Use cases

**Per-machine PIN.** Edit `deploy.args` between deploys to change
the `-BitLockerPin` while keeping everything else constant.

**Per-model image.** Maintain multiple USB sticks, each with its
own `deploy.args` pointing at the right `-WimFile` for that
hardware family (Dell OptiPlex 7090 WIM vs. Latitude 5520 WIM,
each with their respective pre-baked drivers).

**Interactive override.** During testing, rename `deploy.args` to
`deploy.args.disabled` so the script boots into the interactive
TUI for one-off deploys. Rename back when you're done.

**Lab vs. production.** Same boot.wim, different `deploy.args`
files for `-TargetDisk 0` (production single-disk) vs `-TargetDisk
1 -DataDiskNumber 2` (lab dual-disk).

## Failure modes

- **Args silently invalid.** PowerShell's parameter binding rejects
  unknown parameters loudly (the deploy aborts in the first
  validation block). Misspelled values that pass binding will then
  hit the runtime validation gates — wrong disk number, missing
  WIM, etc. Either way you see an error log line and `exit 1`
  rather than a destructive surprise.
- **PIN with unescaped special characters.** Wrap any PIN with `&`,
  `|`, `<`, `>`, or `%` in double quotes. The example file already
  does this defensively.
- **File missing or empty.** `startnet.cmd` falls back to launching
  the script without args (interactive TUI). Not a failure — that's
  the documented default.
