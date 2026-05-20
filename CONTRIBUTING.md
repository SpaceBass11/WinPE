# Contributing

Thank you for your interest. This project enables BitLocker and applies
BIOS configs on real machines, so contributions are held to a slightly
higher bar than the usual script repo.

## Before You Start

1. Read [CLAUDE.md](CLAUDE.md) - it covers the workflow, key files, and
   the script invariants (especially around BitLocker).
2. Read [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) - many "bug
   reports" are already documented behavior. The "Known Caveats"
   section lists intentional design decisions that may look like bugs
   but are accepted-risk positions.

## Development Environment

The scripts run on a deployed Windows 11 machine during first-boot
OOBE (PowerShell 5.1). For syntax checking on any platform with
PowerShell 7:

```bash
pwsh -NoProfile -Command "[System.Management.Automation.PSParser]::Tokenize((Get-Content scripts/<file>.ps1 -Raw), [ref]\$null)"
```

End-to-end testing requires:

- A reference machine or VM with virtual TPM (for BitLocker work)
- A Dell test machine with DCC 5.x installed (for CCTK work)
- Clonezilla Live media (for capture/restore flow)

The masterize grep checks in `.github/workflows/ci.yml` are
deliberately portable to bash; you can run them locally before
pushing.

## What Makes a Good PR

- **Small and focused.** One logical change per PR.
- **Preserves the BitLocker invariants.** Never weaken the TpmPin or
  RecoveryPassword protector gates. An encrypted volume with no
  recovery protector is worse than no encryption.
- **Tested.** Syntax passing is not the same as working. Describe
  what you actually tested and on what hardware or VM.
- **CHANGELOG entry.** Add to `[Unreleased]` in `CHANGELOG.md`.
- **Docs updated.** If you changed staging paths, file names, or
  behavior, update `docs/RUNBOOK.md` and the relevant operator-facing
  doc.

## Code Style

- **PowerShell 5.1 compatible.** No `??`, `?.`, ternary, `&&`/`||` in
  PS code, no pipeline parallel. PS 5.1 is what ships in the deployed
  Windows OOBE environment.
- **ASCII only in `.ps1` and `.cmd`.** PS 5.1 without UTF-8 BOM reads
  files as Windows-1252; non-ASCII chars cascade-break the parser.
  Markdown can use Unicode (em dashes etc.) but stay conservative.
- **Idempotent.** Every script must safely re-run. Use SHA256 markers
  or state-file checks, not "did we run this already?" boolean flags
  in memory.
- **`Start-Transcript -Append`** for logging. Don't truncate.

## Safety Rules (Non-Negotiable)

These are load-bearing. If your PR touches them, the review bar is
high:

1. **`Enable-BitLocker.ps1` must verify both `TpmPin` and
   `RecoveryPassword` protectors are present after enable.** Don't
   relax these checks to "make it work" on a machine with a missing
   PIN file - fix the staging gap instead.
2. **`Finalize-Cleanup.ps1` must remove `bitlocker-pin.txt` and
   `dell-config.cctk`.** Don't add files to `Config\` that aren't
   also added to the cleanup list.
3. **`State\` is preserved across cleanup.** Don't move the recovery
   key file into `Config\`; don't delete `State\` in cleanup.
4. **Never store the PIN in `State\`.** State outlives cleanup;
   leaving the PIN there defeats the cleanup invariant.
5. **Don't add a SecureString to disk.** `bitlocker-pin.txt` is
   plaintext by design (the trust model is documented in the README);
   adding fake encryption code that doesn't actually protect anything
   is worse than the honest plaintext.
6. **Never commit third-party binaries.** Dell CCTK and any vendor
   tool must be installed onto the gold image at build time, not
   redistributed via this repo. `.gitignore` blocks common paths
   (`cctk.exe`, `hapint*.inf/.sys`) but don't rely on that alone.

## Commit Messages

- Imperative mood: "Fix recovery key path" not "Fixed" / "Fixes".
- First line <= 72 chars, explains the **what**.
- Body (optional) explains the **why** - what was broken, what
  changed, what the new invariant is.

## Reporting Bugs

Use the bug-report issue template. Include:

- Which script and the commit SHA
- Reference machine OS / build / DCC version
- Relevant log content from `C:\ProgramData\ManualClonezilla\Logs\`
- Output of `manage-bde -status C:` and `manage-bde -protectors -get C:`
  for BitLocker reports

## Reporting Security Issues

Do **not** open a public issue. See [SECURITY.md](SECURITY.md) - use
GitHub Security Advisories for private disclosure.

## License

By contributing, you agree that your contributions will be licensed
under the [MIT License](LICENSE).
