# Claude Routine Maintenance Log

Lightweight, one-entry-per-run log so the autonomous maintenance agent
doesn't keep re-investigating the same areas. Newest entries on top.

---

## 2026-05-24 — `build_iso.ps1` BitLocker PIN validation parity

**Investigated:** Open PRs (#46 only — test_parse coverage extension)
and the routine-log backlog. Then audited the BitLocker PIN handling
across the three places it appears: `unified_winpe_deploy.ps1`
(`Start-Deployment` validation, line 1676-1693), `docs/BITLOCKER.md`
(parameter table, line 35), and `scripts/build_iso.ps1` (build-time
gate, line 203-211 pre-edit).

**Found:** The deploy script rejects four placeholder PINs
(`ChangeMe123!`, `password`, `Password1`, `123456`) and enforces a
6-20 character Enhanced-PIN-policy length window. The docs in
`BITLOCKER.md` state both rules. But `build_iso.ps1` only rejected
the literal `'ChangeMe123!'` and never checked length. Concrete
failure mode: someone runs
`build_iso.ps1 -BitLockerPin password ...` — build succeeds, ISO is
flashed, end-user boots, and `Start-Deployment` aborts with
"BitLockerPin is a forbidden placeholder" after WinPE has already
loaded. The check should fail at build time, not on the target.

**Changed:**
- `scripts/build_iso.ps1` — expanded the `if ($BitLockerPin)` block
  to mirror the deploy script's two extra gates: the forbidden-list
  membership check (same four PINs, hardcoded in a local
  `$forbiddenPins` array with a comment pointing to the source of
  truth in `unified_winpe_deploy.ps1` line 146) and the 6-20
  character length window. The original placeholder warning now
  emits via the forbidden-list path; the "no UnattendFile" warning
  is unchanged. `.PARAMETER BitLockerPin` doc block rewritten to
  state both rules.
- `CHANGELOG.md` — bullet appended to `## Unreleased / ### Changed
  (security / safety)` describing the build-time-vs-runtime gap and
  why mirroring matters. No version bump (build-time validation
  improvement, no `$Script:Config.ScriptVersion` touch).
- `docs/claude-routine-log.md` — this entry.

**Verification:**
- `pwsh` 7.4.6 installed once for this session per the CLAUDE.md
  note. Both local tests stay green:
  - `pwsh -NoProfile -File ./tests/test_parse.ps1` → 39/0 (unchanged).
  - `pwsh -NoProfile -File ./tests/test_wim_parser.ps1` → 16/0
    (unchanged).
- Direct AST parse of `scripts/build_iso.ps1` via
  `[System.Management.Automation.Language.Parser]::ParseFile` →
  parsed OK.
- Behavioral test of the new logic with 11 edge cases (each of the
  4 forbidden PINs, 3 too-short / too-long values, and 4 accepted
  values at the boundaries) → 11/11 pass. The acceptance cases reach
  the next pipeline step as expected.
- End-to-end invocation test: ran the script (with `#Requires` line
  stripped on a /tmp copy) against fake WimFile + MediaDir. Each
  forbidden PIN throws with the new message and the right PIN
  proceeds past the gate. No false positives, no false negatives.

**Risks:** Minimal. Build-time validation only — no change to any
destructive code path (diskpart, DISM apply, BCDBoot) and no change
to the deploy script. Worst case: someone using a 5-character or
21-character PIN that previously built cleanly now sees a clear
throw at build time, which is exactly the desired behavior.
PSv5.1-safe (only `-contains`, `.Length`, `throw`).

**Next recommended improvement:**
- Outstanding routine-backlog item: fixture test for
  `Get-SystemDisks` partition enumeration paralleling PR #24's WIM
  parser test (the last untested parser in the deploy script,
  carried forward across PRs #24/#25/#27-#30 and the
  test_parse-coverage PR #46).
- Consider whether `build_iso.ps1`'s ADK / oscdimg lookup deserves
  the same kind of fail-fast helpfulness — today a wrong `-AdkPath`
  throws "oscdimg.exe not found", which is fine; a wrong
  `-Architecture` value with a valid ADK silently looks at the
  wrong subdir. Smaller payoff than the PIN gap.

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

## 2026-05-17 — `refresh_usb.ps1` `-SourceWim` parity

**Investigated:** open Claude routine PRs (#23–#27) and their stated
follow-ups. Three candidates were called out: (a) `Get-SystemDisks`
fixture test, (b) `Show-ImageList` / `Show-ImageSelection` code
factoring, (c) `refresh_usb.ps1` lacking `-SourceWim` support added by
PR #22 to `prepare_wim.ps1`. Picked (c) — smallest blast radius, no
touch to destructive code paths, restores documented wrapper-script
parity.

**Changed:**
- `scripts/refresh_usb.ps1` — converted `-SourceIso` from a plain
  mandatory parameter to a member of a `FromIso` / `FromWim`
  parameter set, mirroring `prepare_wim.ps1`. Added `-SourceWim`,
  `-Index`, `-Edition`, and `-DisableExtraBloat`; source-existence
  check and output-name derivation now use whichever of the two source
  parameters is bound. Pass-through hashtable in step 1 picks
  `SourceIso`/`SourceWim` and forwards `-Index`/`-Edition`/
  `-DisableExtraBloat` only when bound. Synopsis, parameter help, and
  a new `-SourceWim` example added.
- `docs/SCRIPT_REFERENCE.md` — refresh_usb.ps1 parameters and Examples
  section updated to cover both flows.
- `CHANGELOG.md` — entry added under `## Unreleased / ### Added`.

**Verification:**
- Brace / paren / bracket balance on `scripts/refresh_usb.ps1`:
  29/29, 38/38, 22/22 (after string and comment stripping).
- Visual structural review of pass-through block: `-Index` /
  `-Edition` only bound via `$PSBoundParameters.ContainsKey(...)`, so
  `prepare_wim.ps1` defaults still apply when the caller doesn't supply
  them. The wrapper's `[string]$Edition` has no default, so we don't
  accidentally clobber `prepare_wim.ps1`'s `'Windows 11 Enterprise'`
  default by forwarding an empty string.
- `pwsh` is not installed in this Linux session, so
  `tests/test_parse.ps1` cannot run locally (same constraint flagged in
  PRs #23–#27 and in `.claude/reviews/2026-05-11-deep-review.md`).
  CI's `syntax` job on `windows-latest` runs `PSParser::Tokenize` on
  push and is the source of truth.

**Risks / follow-ups:**
- Minimal. No destructive code paths (diskpart, DISM apply, BCDBoot)
  touched. Worst case is a help-text typo or a parameter-set rule that
  surfaces only at parameter-binding time on Windows; both caught by
  CI's `PSParser::Tokenize` and the masterize Phase 1 invariants.
- Outstanding follow-ups from the open routine PRs that I didn't take
  this pass:
  - `Get-SystemDisks` fixture test paralleling PR #24's WIM parser test
    (last untested parser in the deploy script).
  - `Show-ImageList` / `Show-ImageSelection` share ~30 lines of listing
    code that could be factored out — cleanup-only and risks subtle
    UX changes.

---


---

## 2026-05-17 — `tests/test_parse.ps1` Required-Functions list refresh

**Investigated:**
- Open PRs (#23-#30) and their stated follow-ups, to avoid duplicating
  in-flight work.
- `tests/test_parse.ps1` Test 5 (`$requiredFunctions`) against the actual
  `function` definitions in `unified_winpe_deploy.ps1` v4.6.0.
- `.github/workflows/ci.yml` Phase 1B checks 8-19 to confirm the gap
  isn't already covered indirectly.

**Found:** Four functions added since v4.5.0 were not in the
required-functions check — `Invoke-CctkConfig`,
`Select-AdditionalWipeDisks`, `Test-FinalWipeConfirmation`,
`Show-ImageList`. Two are destructive-operation entry points; one is the
shared typed-confirmation parser; one backs the public `-ListOnly` flag.
The masterize CI check 12 (`Invoke-CctkConfig` ordering) and check 19
(`DELETE ALL DATA`/`DESTROY SYSTEM` strings) cover those two indirectly,
but a clean function-renaming refactor would still slip the existing
test net without this list update.

**Changed:**
- `tests/test_parse.ps1` — added the four function names, regrouped the
  list so related functions stay together, added a comment about why
  each addition matters for safety.
- `CHANGELOG.md` — `## Unreleased / ### Changed` bullet describing the
  coverage extension.

**Verification:**
- Brace balance on `tests/test_parse.ps1` unchanged (4 / 4).
- Each added function name confirmed present in
  `unified_winpe_deploy.ps1` via `grep -nE '^function '`.
- Existing `function\s+Name\b` regex pattern handles all four names
  without modification.
- `pwsh` isn't available in this Linux session so the test cannot run
  locally — same constraint flagged in open PRs #23-#30 and
  `.claude/reviews/2026-05-11-deep-review.md` Validation Notes. CI's
  `syntax` job on `windows-latest` will run `PSParser::Tokenize` and
  the updated function-list assertions on push.

**Next recommended improvement:**
- Fixture test for `Get-SystemDisks` partition enumeration paralleling
  PR #24's `Get-WimImageInfo` test — flagged as outstanding across PRs
  #24/#25/#27/#28/#29/#30; the last untested parser in the deploy
  script. Higher mock burden because of `Get-WmiObject` /
  `Win32_DiskPartition` ASSOCIATORS-OF queries.
- `Show-ImageList` and `Show-ImageSelection` share ~30 lines of
  listing-render code that could be factored out — flagged across PRs
  #26/#27/#28/#29 but deferred because the menu rendering is
  load-bearing UX.


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

## 2026-05-16 — WIM index parser regression test

**Investigated:** The deep-review's "next recommended improvement" list
flagged the absence of a structural smoke test for `Get-WimImageInfo`,
the function that parses `dism /Get-WimInfo /English` output into the
edition-selection menu. A silent regex failure here would either abort
the deploy (best case) or — if regex shape changed in a way that still
matched but mis-attributed fields — let the operator pick the wrong
edition to deploy. No existing test covered the parser; `test_parse.ps1`
only validates script-level syntax and structure.

**Changed:**

- `tests/test_wim_parser.ps1` — new fixture test. Defines three
  realistic DISM `/Get-WimInfo /English` outputs (multi-index, single-
  index, error/empty), runs them through a parser that mirrors
  `Get-WimImageInfo`, and asserts index count, name, description, size,
  and integer index numbers. Includes a drift guard that confirms the
  four parser regex patterns still live verbatim in
  `unified_winpe_deploy.ps1`; if either side changes without the other,
  the guard fails and forces the test to be updated.
- `.github/workflows/ci.yml` — wired the new test into the `syntax` job
  as a follow-on step. Runs on every push and PR to `main`.

**Verification:** PowerShell (`pwsh`) is not present in the Linux
session, so the test cannot run locally — same constraint flagged by
the deep-review's Validation Notes and the previous routine entry. The
file was reviewed by hand for: balanced braces, regex patterns matching
the deploy script verbatim, return semantics (`return ,$indexes` to
preserve empty / single-element arrays through PowerShell's output
unwrapping), and PSSA-friendly explicit-parameter passing rather than
dynamic-scope lookup inside the helper. CI's Windows runner will
execute the real `pwsh ./tests/test_wim_parser.ps1`.

**Risks:** Test-only addition. No production code touched. Only CI
risk: if my drift-guard regex patterns somehow don't match the script
even though they should, CI fails — caught on the first push.

**Next recommended improvement:**

- Consider whether `Apply-WindowsImage`'s DISM exit-code → recovery
  message table covers the other common WinPE failure modes (50, 87,
  1392). Today only exit code 1 has bespoke guidance.
- A similar fixture test could be added for `Get-SystemDisks` /
  `Win32_DiskDrive` enumeration to guard against partition-count
  regression on Linux/LVM disks. Less urgent — the current behavior is
  documented in the deep-review as a mitigated risk.


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