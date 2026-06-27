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

## Drive-letter substitution: `{DRIVE}`

Before the args are handed to PowerShell, `startnet.cmd` does a
literal text replacement of every `{DRIVE}` token in the args line
with `%DEPLOY_IMAGE_DRIVE%` — the drive letter WinPE assigned to
the IMAGES partition this boot. So a `deploy.args` line like:

```text
-WimFile "{DRIVE}\images\Win11_Pro.wim" -UnattendFile "{DRIVE}\configs\unattend.xml" -TargetDisk 0 -Force -Silent
```

becomes (if WinPE mounted IMAGES as `E:` this boot):

```text
-WimFile "E:\images\Win11_Pro.wim" -UnattendFile "E:\configs\unattend.xml" -TargetDisk 0 -Force -Silent
```

This is what makes a single ISO portable across hardware — different
hosts may assign the USB a different letter, but the args still
resolve to the right paths. `scripts/build_iso.ps1` writes
`{DRIVE}\...` paths by default for exactly this reason.

Notes:

- **Token is case-sensitive.** `{drive}` is not substituted; use
  `{DRIVE}` exactly.
- **Substitution is unconditional inside the args line.** Anywhere
  `{DRIVE}` appears — `-WimFile`, `-UnattendFile`, `-BitLockerKeyPath`,
  custom values — gets the same replacement. There is no quoting or
  escape mechanism for a literal `{DRIVE}` string.
- **No substitution if IMAGES is not found.** If `startnet.cmd`
  cannot locate a volume labeled IMAGES (`%DEPLOY_IMAGE_DRIVE%`
  unset), the substitution block is skipped and the literal
  `{DRIVE}` reaches PowerShell. The deploy script's subsequent
  path validation will then fail loudly with a not-found error
  rather than running against a wrong path.
- **Absolute drive letters still work.** Hand-authored args using
  `I:\images\...` instead of `{DRIVE}\images\...` are passed through
  untouched. Use absolute letters when the IMAGES letter is stable
  on a given USB (legacy two-partition workflow); use `{DRIVE}` when
  the same args file is shared across builds that may mount on
  different letters (single-ISO + Rufus workflow).

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
