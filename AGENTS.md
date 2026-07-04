# AGENTS.md

This repository is a PowerShell-based WinPE deployment tool that
**wipes and repartitions disks** unattended. Any coding agent
(Claude, Codex, Cursor, future ones) working in this tree should
read [`CLAUDE.md`](CLAUDE.md) first — it carries the full project
context, conventions, and review workflow.

This file is the short version: the non-negotiable safety rules
and how to validate changes.

## Non-negotiable safety rules

The tool destroys data on real hardware. The rules below exist to
prevent silent regressions. CI enforces most of them via the
`masterize` job in `.github/workflows/ci.yml` — a red build is the
signal.

- **Never weaken or remove the typed-confirmation chain.** The
  `ERASE`, `DESTROY SYSTEM`, `WIPE ALL`, `WIPE DATA`, and
  `CONTINUE ANYWAY` prompts are the last line of defense between
  the operator and an irreversible wipe.
- **Never let `-Force` bypass system-disk protection.** `-Force`
  skips the `ERASE` typed prompt by design, but the `DESTROY
  SYSTEM` prompt for the currently-booted disk must always be
  typed by a human. The `Force cannot bypass` guard in
  `unified_winpe_deploy.ps1` must remain.
- **BitLocker and data-disk staging are opt-in.** Do not change
  these defaults:
  - `DataDiskNumber = -1`
  - `EnableBitLocker = $false`
  - `BitLockerPin = $null`
  PIN *content* policy (forbidden lists, character classes) is
  intentionally NOT enforced — admins decide. The only PIN check
  is Windows' 6-20 character window so a malformed PIN fails at
  deploy time instead of first boot.
- **Never commit real secrets.** No real BitLocker PINs, CCTK BIOS
  passwords, unattend.xml admin passwords or product keys, domain
  credentials, or signing certificates. Use placeholders and
  document the substitution.
- **WinPE / PowerShell 5.1 compatibility.** WinPE has a limited
  module set: no `Az`, no `ImportExcel`, no PSv7-only syntax in
  scripts that run inside WinPE. Use `Get-WmiObject`, not
  `Get-CimInstance` (documented in `CLAUDE.md`).
- **Drive letters `S:` and `C:`** are reserved for the EFI and
  Windows partitions respectively. Never unmount the system
  drive — `mountvol /d` must always check `$env:SystemDrive`
  first.
- **Use `shutdown.exe`, not `Stop-Computer`.** `Stop-Computer` is
  unreliable in WinPE.

## Required validation before pushing

Run these locally — they are also enforced in CI:

```bash
pwsh -NoProfile -File ./tests/test_parse.ps1
pwsh -NoProfile -File ./tests/test_wim_parser.ps1
```

The Pester suite (`tests/validation-gates.Tests.ps1`) runs in CI
only. PSGallery is typically blocked from the agent execution
environment, so `Install-Module Pester` will fail there — verify
the assertion logic manually and rely on CI to run the suite
end-to-end. See `CLAUDE.md` for the install-pwsh-once snippet.

## Human approval required

These areas have non-obvious safety, hardware, or operator-process
implications. Do not refactor or change behavior without explicit
human review:

- Destructive disk logic (diskpart script generation, target-disk
  selection, additional-wipe prompt, partition layout)
- Silent-mode behavior (`-Silent` / `-Force` contract, parameter
  validation gates in `Start-Deployment`)
- BitLocker staging (`Initialize-BitLockerSetup`,
  `Resolve-BitLockerKeyPath`, `SetupComplete.cmd` generation,
  recovery-key escrow paths)
- CCTK pre-apply behavior (config selection precedence, non-zero
  exit handling)
- The release workflow (version-bump fence in `CLAUDE.md` — four
  files must move together)

When in doubt, open the change as a PR with a clear summary and
let a human decide.
