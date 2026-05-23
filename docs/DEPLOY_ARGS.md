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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\scripts\unified_winpe_deploy.ps1 !DEPLOYARGS!
```

The raw args are **not** echoed. `startnet.cmd` confirms only that
a `deploy.args` was loaded — never its contents — so a BitLocker
PIN or other secret in the file does not appear on the WinPE
console, KVM, or any over-the-shoulder view. To inspect the args,
read the file from the IMAGES partition directly.

## Constraints

- **Single line.** `set /p` reads only the first line of the file.
  If you need more parameters than fit on one line, stop using
  `deploy.args` and rebuild `boot.wim` with a customized
  `startnet.cmd`.
- **Quoting follows cmd.exe rules.** Wrap paths with spaces in
  double quotes. PowerShell re-parses the args on its end so the
  normal `-Param "value"` pattern works.
- **No environment-variable expansion** beyond what cmd.exe and
  startnet.cmd already set (notably `%DEPLOY_IMAGE_DRIVE%` is
  available, but the example uses absolute drive letters because
  those are stable on the IMAGES USB).

## Security caveat — same as CCTK

`deploy.args` lives in plaintext on the FAT32/NTFS data partition.
If you embed a BitLocker PIN there, anyone with physical access to
the USB can read it. This is the same trust model as the CCTK
configs documented in [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#known-caveats):
the USB is the trust boundary. Mitigations:

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
