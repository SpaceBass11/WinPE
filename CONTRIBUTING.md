# Contributing

Thank you for your interest. This project wipes disks for a living, so
contributions are held to a slightly higher bar than the usual script repo.

## Before You Start

1. Read [CLAUDE.md](CLAUDE.md) — it covers the MDT standalone media
   layer, including safety conventions and MDT compatibility constraints.
2. Read [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — many "bug
   reports" are already documented workarounds. The "Known Caveats"
   section at the bottom lists intentional behavior that may look like
   a bug but isn't.

## Development Environment

You need Windows (or a Windows VM) to run the script for real. For
syntax and static analysis, any platform with PowerShell 7 works.

```powershell
# Syntax parse
pwsh -NoProfile -File ./tests/test_parse.ps1

# PSScriptAnalyzer (matches CI)
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

Real end-to-end testing requires MDT 8456 + ADK installed on a Windows
workstation, and a VM or spare machine to boot the resulting ISO.

## MDT Script Development

The MDT scripts (`scripts/mdt/`) require MDT 8456 + ADK installed on a Windows
workstation to test end-to-end. For syntax validation alone, any platform with
PowerShell 7 works:

```powershell
pwsh -NoProfile -File ./tests/test_parse.ps1
```

MDT scripts do not touch disks directly — they configure a deployment share and
build media. The underlying DISM/diskpart work happens inside the MDT task
sequence at deploy time.

## What Makes a Good PR

- **Small and focused.** One logical change per PR.
- **Preserves the safety chain.** Never weaken
  `ERASE` / `DESTROY SYSTEM` / `CONTINUE ANYWAY` prompts. Never let
  `-Force` bypass system-disk protection.
- **Tested.** Syntax passing is not the same as working.
  Describe what you actually tested and on what hardware or VM.
- **Versioned.** For MDT script changes: bump the `$Script:Version`
  comment block if the change is release-worthy. Add a
  [CHANGELOG.md](CHANGELOG.md) entry under `[Unreleased]`.
- **Documented.** Update `docs/SCRIPT_REFERENCE.md` if you changed
  parameters or functions, and `docs/TROUBLESHOOTING.md` if you fixed
  a failure mode. For MDT script changes, update `docs/MDT.md` and
  `docs/SCRIPT_REFERENCE.md` as appropriate.

## Code Style

- PowerShell 5.1 compatible (MDT runs scripts in a 5.1 environment). No
  PS7-only syntax (`??`, `?.`, ternary, etc.).
- `#region` / `#endregion` blocks organize sections.
- Use `Write-Log` for user-visible output (also writes to the deploy log).
- Avoid emojis in script output — some consoles render them inconsistently.

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

The MDT scripts (`scripts/mdt/`) configure MDT and build media — they do
not perform disk operations directly and are not subject to rules 1–5.
Rule 6 (no third-party binaries) applies to all scripts.

## Commit Messages

- Imperative mood: "Fix diskpart abort" not "Fixed" / "Fixes".
- First line <= 72 chars, explains the *what*.
- Body (optional) explains the *why* — what was broken, what changed,
  what the new invariant is.

## Reporting Bugs

Use the bug-report issue template. Include:
- Which MDT script and version
- ADK version
- Exact command line
- Relevant log or error output

## Reporting Security Issues

Do **not** open a public issue. See [SECURITY.md](SECURITY.md) — use
GitHub Security Advisories for private disclosure.

## License

By contributing, you agree that your contributions will be licensed
under the [MIT License](LICENSE).
