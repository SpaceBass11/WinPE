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

## Drive-letter placeholder — `{DRIVE}`

The literal token `{DRIVE}` anywhere in `deploy.args` is substituted
with the IMAGES partition's drive letter (`%DEPLOY_IMAGE_DRIVE%`,
including the trailing colon — e.g. `I:`) before the args are
handed to PowerShell. So:

```text
-WimFile "{DRIVE}\images\Win11_Pro.wim" -UnattendFile "{DRIVE}\configs\unattend.xml" -Force -Silent
```

becomes, at boot:

```text
-WimFile "I:\images\Win11_Pro.wim" -UnattendFile "I:\configs\unattend.xml" -Force -Silent
```

Use `{DRIVE}` when you don't know — or don't want to hardcode —
which letter WinPE will assign the USB. That is the normal case
for the single-ISO workflow: `build_iso.ps1` generates its
`deploy.args` with `{DRIVE}\...` paths for exactly this reason,
so the same ISO works on any host regardless of how WinPE lays
out drive letters. The two-partition USB workflow can hardcode
letters if the operator has verified them on the target hardware,
but `{DRIVE}` works there too.

Substitution is a literal text replace — the token must be
capitalized exactly (`{DRIVE}`, not `{drive}`), and no other
placeholders are recognized.

## Constraints

- **Single line.** `set /p` reads only the first line of the file.
  If you need more parameters than fit on one line, stop using
  `deploy.args` and rebuild `boot.wim` with a customized
  `startnet.cmd`.
- **Quoting follows cmd.exe rules.** Wrap paths with spaces in
  double quotes. PowerShell re-parses the args on its end so the
  normal `-Param "value"` pattern works.
- **No environment-variable expansion** beyond what cmd.exe and
  startnet.cmd already set. The only path-portability tool is the
  `{DRIVE}` token described above; `%DEPLOY_IMAGE_DRIVE%` is
  reserved for use inside `startnet.cmd` itself and is not
  substituted inside `deploy.args`.

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
