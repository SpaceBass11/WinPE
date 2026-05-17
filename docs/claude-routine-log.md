# Claude Routine Maintenance Log

Lightweight per-run log for the autonomous maintenance agent. One short
entry per run so future passes don't re-investigate the same areas.

> **Note on file ownership:** Several open PRs (#23, #24, #25, #26) also
> introduce this file. Whichever lands second/third/fourth will need a
> trivial rebase that keeps all entries in time order. Acknowledged.

---

## 2026-05-17 — BCDBoot failure diagnostics

**Investigated:** `Set-BootConfiguration` in `unified_winpe_deploy.ps1`.
PR #25's body listed BCDBoot exit-code expansion as its next recommended
follow-up; the function itself logged only `BCDBoot failed with exit code N`
and the caller printed two generic recovery lines. Underneath that, the
`Start-Process` call used `-WindowStyle Hidden`, which silently swallows
bcdboot's own stderr (`Failure when attempting to copy boot files`,
BFSVC errors, etc.) — exactly the diagnostic that would have helped the
operator. All three other `Start-Process` calls in the file
(`diskpart.exe`, `dism.exe`) already use `-NoNewWindow`.

**Changed:**

- `unified_winpe_deploy.ps1` — `Set-BootConfiguration`:
  - `-WindowStyle Hidden` → `-NoNewWindow` so bcdboot's stderr reaches the
    console (matches the diskpart/DISM pattern).
  - On non-zero exit, log a diagnostics block: presence of
    `C:\Windows\Boot\EFI\bootmgfw.efi` (bcdboot's source file), `S:` mount
    state and free space, and four common-cause reminders.
  - Caller block in `Start-Deployment` (the two-line recovery hint) is
    unchanged — function-level diagnostics now print before it.
- `docs/TROUBLESHOOTING.md` — expanded "BCDBoot fails" with a
  symptom-to-cause table and a "what the script surfaces" note so the
  doc and the new in-script output stay in sync.

**Verification:**

- Brace balance: 322 open / 322 close (was 320/320; +2/+2 net from the
  new `if`/`else` block).
- Region balance: 10 `#region` / 10 `#endregion` (unchanged).
- All four `Start-Process` flags now consistent (`-NoNewWindow`).
- `pwsh` is not present in this Linux session, so `tests/test_parse.ps1`
  cannot run locally — same constraint flagged in the deep-review's
  Validation Notes and in open PRs #23–#26. CI's `syntax` job on
  `windows-latest` will run `PSParser::Tokenize` on push.

**Risk:** Minimal. Function-level changes are additive logging plus a
single flag swap on `Start-Process`. The flag swap means bcdboot's own
one-line success message ("Boot files successfully created.") will now
appear in the console alongside the script's `Write-Log` line — strictly
more information, no destructive code path touched. No diskpart, DISM,
or partition-handling changes.

**Next recommended improvement:**

- `Show-ImageList` / `Show-ImageSelection` in the deploy script share
  ~30 lines of listing code that could be factored out (cleanup-only,
  flagged by PR #26's body).
- A fixture test for `Get-SystemDisks` partition enumeration paralleling
  PR #24's WIM parser test would close the last untested parser in the
  deploy script (flagged by PRs #24 and #25 bodies).
- `scripts/refresh_usb.ps1` is a thin wrapper around `prepare_wim.ps1`
  but only supports `-SourceIso`, not the `-SourceWim` flow added by
  PR #22. Closing that gap would restore wrapper-script parity.
