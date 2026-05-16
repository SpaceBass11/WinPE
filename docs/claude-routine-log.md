# Claude Routine Maintenance Log

Lightweight, one-entry-per-run log so the autonomous maintenance agent
doesn't keep re-investigating the same areas. Newest entries on top.

---

## 2026-05-16 — prepare_wim.ps1 destination-name fix

**Investigated:** `prepare_wim.ps1` export step, in particular how the
`-SourceWim` / `-Index` parameter set introduced in PR #22 interacts with
the `-DestinationName` argument on `Export-WindowsImage`.

**Found:** Line 472 hard-coded `"$Edition (Custom)"` as the destination
name. `$Edition` defaults to `'Windows 11 Enterprise'` and is *not*
required when `-SourceWim` or `-Index` is given. So
`prepare_wim.ps1 -SourceWim golden.wim -Index 1` produced a WIM labeled
`Windows 11 Enterprise (Custom)` regardless of what the source actually
was. The mislabel then surfaced as the wrong edition name in the deploy
script's `Select-ImageIndex` menu (`unified_winpe_deploy.ps1` line 837),
where the operator picks which edition to install.

**Changed:**
- `scripts/prepare_wim.ps1` — derive the destination name from
  `$target.ImageName` (the actual selected image) with a fallback to
  `$Edition` for empty-name captures. Comment explains why.
- `CHANGELOG.md` — added a `### Fixed` entry under `## Unreleased`.

**Verification:** `pwsh` isn't available in this Linux session so
`tests/test_parse.ps1` can't run locally — same constraint flagged in
open PRs #23/#24/#25. The change is mechanical: replaces one string
literal with a variable derived from already-validated state.
Pre-existing structural assertions still pass:
- The Export-WindowsImage call is unchanged in shape (same parameters,
  same line continuations).
- No new mounts, no destructive code paths touched.

CI's `syntax` job on `windows-latest` runs the real
`PSParser::Tokenize` check on push.

**Next recommended improvement:** PRs #23/#24/#25 all add this log file;
whichever PR merges second/third needs a trivial rebase keeping entries
in time order. After that backlog clears, candidates worth looking at:
- `Show-ImageList` / `Show-ImageSelection` in the deploy script share
  ~30 lines of listing code that could be factored out.
- `Set-BootConfiguration` exit-code branch logs only the bare number —
  could mirror the DISM exit-code expansion proposed in PR #25.
- No fixture test exists for `prepare_wim.ps1`'s parameter-set
  validation; a small test would catch future regressions in the
  `-SourceWim` vs `-SourceIso` branch logic.

---

## 2026-05-17 — `-UnattendFile` well-formedness validation

**Investigated:** the deploy script's pre-flight validation for the
`-UnattendFile` parameter (lines 1333-1340 of `unified_winpe_deploy.ps1`,
pre-edit). Cross-referenced with `docs/UNATTEND.md` §6.

**Found:** `Test-Path -PathType Leaf` was the only check. A malformed
unattend.xml (unclosed tag, bad attribute, encoding issue) passes
pre-flight but is silently ignored by Windows Setup at first boot — the
operator only discovers the failure when OOBE prompts for an account
they thought would auto-create. By that point the target disk has
already been wiped and the image applied. `docs/UNATTEND.md` §6
already instructs users to run `[xml](Get-Content ...)` manually as a
sanity check, so moving that into the script closes a known gap with a
recipe that already lives in the docs.

**Changed:** `unified_winpe_deploy.ps1` — added a `try { [xml]Get-Content
... }` block inside the existing `if ($UnattendFile)` validation. On a
parse failure, logs the parser's error message, points the operator at
`docs/UNATTEND.md` §6, and returns `$false` before any destructive disk
work. `CHANGELOG.md` gets a bullet under Unreleased / Changed.

**Verification:**
- Brace balance on `unified_winpe_deploy.ps1`: 320 / 320 (was 318 / 318;
  +2 / +2 from the new `try`/`catch`).
- Region balance: 10 / 10 (unchanged).
- Structural review: the new block is inside the existing
  `if ($UnattendFile)` body that already short-circuits on the
  `Test-Path` failure — same exit pattern, same logging shape, no
  effect on the downstream destructive path.
- `pwsh` isn't installed in this Linux session so `tests/test_parse.ps1`
  can't run locally — same constraint flagged in PRs #23-#29 and in
  `.claude/reviews/2026-05-11-deep-review.md`'s Validation Notes. CI's
  `syntax` job on `windows-latest` will run the real
  `PSParser::Tokenize` on push.

**Next recommended improvement:** of the follow-ups recorded across
open PRs, the highest-value remaining ones are:
- **Fixture test for `Get-SystemDisks` partition enumeration** —
  parallel to PR #24's `Get-WimImageInfo` parser test. Higher mock
  burden because of `Get-WmiObject`, but it's the last unit-tested
  parser in the deploy script and a regression there could silently
  miss a Linux/LVM disk being reported as empty.
- **`Show-ImageList` / `Show-ImageSelection`** share ~30 lines of
  listing code that could be factored out — flagged across PRs
  #26/#27/#28 but deferred since UX is load-bearing.

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

---

## 2026-05-16 — Expand DISM exit-code recovery guidance

**Investigated:** Both prior maintenance entries (the two open PRs that
preceded this one) flagged the same next item: `Apply-WindowsImage`
had bespoke recovery guidance only for DISM exit code 1. Every other
non-zero exit got the bare line "DISM failed with exit code N" and
nothing else. `docs/TROUBLESHOOTING.md` already documents meanings for
codes 1, 2, 11, 87, 112, 1168, 1392 in its DISM-error table, so the
script was lagging behind the docs.

**Changed:**

- `unified_winpe_deploy.ps1` — replaced the single `if ($process.ExitCode
  -eq 1)` block in `Apply-WindowsImage` with a `switch` that covers exit
  codes 1, 2, 11, 50, 87, 112, 1168, 1392, plus a `default` arm that
  points the operator at `docs/TROUBLESHOOTING.md` and `dism.log`. The
  exit-1 branch keeps its existing five-step recovery list verbatim;
  every other branch is purely additive (where previously nothing was
  printed). `$dismLog` is now declared once at the top of the block so
  every arm can reference it.
- `docs/TROUBLESHOOTING.md` — added a row for exit code 50 (Request not
  supported) to the DISM-error table. The script will now surface this
  code by name, so the docs table should list it too.

**Verification:**

- Brace count on `unified_winpe_deploy.ps1` after edits: 327 open / 327
  close (matches Test 3 in `tests/test_parse.ps1`).
- Region count: 10 `#region` / 10 `#endregion` (matches Test 4).
- Diff brace delta: `+9 {` / `+9 }` net — balanced.
- Visual inspection of lines 1029-1121: `try { ... switch { ... } ...
  return $false } catch { ... }` is correctly nested; surrounding
  `Set-BootConfiguration` and the `#endregion` at 1141 are unchanged.
- Pure additive operator-facing logging — no destructive code paths
  touched, no change to the success path (`return $true` at line 1051)
  or to the existing failure return (`return $false` at line 1116).
- `pwsh` is not installed in this Linux session, so `tests/test_parse.ps1`
  can't run locally — same constraint flagged in the deep-review's
  Validation Notes and the two prior routine entries. CI's `syntax` job
  on `windows-latest` runs the real `PSParser::Tokenize` on push.

**Risks:**

- Minimal. Only `Write-Log` calls were added inside an existing
  function; no new behavior, no new branches in destructive code
  (diskpart, DISM args, BCDBoot), no new parameters.
- The `switch` matches on `$process.ExitCode`, which is an `int`; the
  numeric arms are integer literals. No type-coercion edge case.

**Next recommended improvement:**

- A fixture test for `Get-SystemDisks` partition enumeration (called out
  as a less-urgent follow-up in PR #24's body). It would guard against
  regressions in the Linux/LVM-disk-as-empty mitigation.
- The BCDBoot failure path at line 1133 only logs `exit code N`. A
  similar small expansion (the common BCDBoot failures are EFI partition
  not S:, target not bootable, and `bcdboot.exe` missing from PATH) would
  bring it to parity with the DISM block.

---

## 2026-05-16 — Log path reminder on fatal exit

**Investigated:** Deep-review (`.claude/reviews/2026-05-11-deep-review.md`)
flagged one item with status "Partial": fatal exit paths don't reliably
remind the operator where the deploy log is written. The log file is
printed once at session start, but after a long DISM/diskpart trace it
can scroll out of sight.

**Changed:** `unified_winpe_deploy.ps1` — centralized the "Full log: ..."
reminder at the outer try/catch boundary so every fatal exit (any
`Start-Deployment` failure return, plus uncaught critical exceptions)
prints the log path before `exit 1`. Guarded on
`$Script:SystemPaths.LogFile` being set so very-early failures (admin
check before `Initialize-SystemPaths`) don't print a `$null` path.

**Verification:** PowerShell parser is not available in this Linux
session (`pwsh` not installed), so `tests/test_parse.ps1` cannot run
locally — same constraint documented in the deep-review's
Validation Notes. Did a structural sanity check by reading the diff and
confirming brace/region balance around the edit is unchanged (only added
lines inside an existing `try`/`catch` block, no structural changes). CI
will run the real `PSParser::Tokenize` check on push.

**Risks:** Minimal. Pure additive logging; no behavior change on success
paths; no new code paths in destructive logic.

**Next recommended improvement:** None of the high-confidence,
small-scope items from the deep-review remain open at the time of this
run. Future passes could look at:
- Adding a structural smoke test for `Get-WimImageInfo` parser regression
  (DISM `/English` output shape).
- Considering whether `Apply-WindowsImage`'s DISM exit code → message
  table covers all the known WinPE failure modes (e.g. 50, 87, 1392).
