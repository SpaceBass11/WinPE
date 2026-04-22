# Contributing

Thank you for your interest. This project wipes disks for a living, so
contributions are held to a slightly higher bar than the usual script repo.

## Before You Start

1. Read [CLAUDE.md](CLAUDE.md) — it documents the safety conventions,
   hard-coded drive letters, and WinPE compatibility constraints.
2. Read [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — many "bug
   reports" are already documented workarounds.
3. Check [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) — the issue might
   already be known or intentional.

## Development Environment

You need Windows (or a Windows VM) to run the script for real. For
syntax and static analysis, any platform with PowerShell 7 works.

```powershell
# Syntax parse
pwsh -NoProfile -File ./tests/test_parse.ps1

# Static analysis
pwsh -NoProfile -File ./scripts/validate_script.ps1

# PSScriptAnalyzer (matches CI)
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

Real deployment testing requires a WinPE boot medium and a disposable
target disk. A VM with a scratch VHD works well.

## What Makes a Good PR

- **Small and focused.** One logical change per PR.
- **Preserves the safety chain.** Never weaken
  `ERASE` / `DESTROY SYSTEM` / `CONTINUE ANYWAY` prompts. Never let
  `-Force` bypass system-disk protection.
- **Tested in WinPE.** Syntax passing is not the same as working.
  Describe what you actually tested and on what hardware.
- **Versioned.** Bump `$Script:Config.ScriptVersion` and the `.VERSION`
  header together when the change is release-worthy. Add a
  [CHANGELOG.md](CHANGELOG.md) entry under `[Unreleased]`.
- **Documented.** Update `docs/SCRIPT_REFERENCE.md` if you changed
  parameters or functions, and `docs/TROUBLESHOOTING.md` if you fixed
  a failure mode.

## Code Style

- PowerShell 5.1 compatible (WinPE ships 5.1). No `Get-CimInstance`,
  no PS7-only syntax (`??`, `?.`, ternary, etc.).
- `#region` / `#endregion` blocks organize sections.
- Use `Write-Log` for user-visible output (also writes to the deploy log).
- Use `$Script:Config` for shared configuration.
- Hard-coded drive letters are `C:` (Windows) and `S:` (EFI). Do not
  parameterize these without a very good reason.
- Avoid emojis in script output — WinPE consoles render them inconsistently.

## Safety Rules (Non-Negotiable)

These are load-bearing. If your PR touches them, the review bar is high:

1. **Never unmount the system drive.** `mountvol /d` must check
   `$env:SystemDrive` first.
2. **USB drives are excluded from target selection.** Don't "helpfully"
   re-enable them.
3. **`-Silent` requires `-WimFile`, `-TargetDisk`, and `-Force`** unless
   used with `-ListOnly`.
4. **`-Force` skips `ERASE` but never `DESTROY SYSTEM`.** System-disk
   deployment always requires the typed string.
5. **Use `shutdown.exe`, not `Stop-Computer`.** The PowerShell cmdlet is
   unreliable in WinPE.
6. **Never commit third-party binaries.** Dell CCTK, WinPE itself, and
   any vendor driver/tool must be fetched from the vendor at build time
   — not redistributed via this repo. `.gitignore` blocks common paths
   (`/vendor/`, `/cctk-source/`, `cctk.exe`, `hapint*.inf/.sys`) but
   don't rely on that alone.

## Commit Messages

- Imperative mood: "Fix diskpart abort" not "Fixed" / "Fixes".
- First line <= 72 chars, explains the *what*.
- Body (optional) explains the *why* — what was broken, what changed,
  what the new invariant is.

## Reporting Bugs

Use the bug-report issue template. Include:
- Tool version
- WinPE architecture and ADK version (if relevant)
- Exact command line
- Tail of the deploy log from the temp directory
- For DISM failures: the relevant section of `X:\Windows\Logs\DISM\dism.log`

## Reporting Security Issues

Do **not** open a public issue. See [SECURITY.md](SECURITY.md) — use
GitHub Security Advisories for private disclosure.

## License

By contributing, you agree that your contributions will be licensed
under the [MIT License](LICENSE).
