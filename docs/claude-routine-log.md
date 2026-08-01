# Claude Routine Maintenance Log

Lightweight, one-entry-per-run log so the autonomous maintenance agent
doesn't keep re-investigating the same areas. Newest entries on top.

---

## 2026-08-01 — `build_iso.ps1` warns on `-VolumeLabel` mismatch

**Investigated:** open PRs (#231-#250 are the most recent open Claude
branches, many still unmerged) and the `git log --all` topic history
for `build_iso`, `label`, `IMAGES`. Cross-referenced against the
`build_iso.ps1` parameter surface to find something not already in
flight. Recent open PRs cover PIN redaction (#236), PIN length
(#245), silent-mode disk collisions (existing side branch dc13e72),
Interactive-mode param drops (#231), and PR-template resync (#249).
Nothing addresses the volume-label mismatch case.

**Found:** `scripts/build_iso.ps1` takes an optional `-VolumeLabel`
parameter (default `IMAGES`, line 145). The `startnet.cmd` baked into
`boot.wim` by `scripts/build_boot_wim.ps1` (lines 279-286) scans
mounted volumes for the *literal* string `IMAGES` to set
`%DEPLOY_IMAGE_DRIVE%`. If the operator builds an ISO with
`-VolumeLabel 'X'` (any value other than `IMAGES`), the runtime chain
silently degrades in three places:

1. **`deploy.args` never loads.** `startnet.cmd` gates the
   `set /p DEPLOYARGS=...` block on `defined DEPLOY_IMAGE_DRIVE`, so
   without a label hit, the silent-mode ISO reverts to a bare
   `powershell.exe -File unified_winpe_deploy.ps1` launch — an
   interactive TUI, not the silent wipe the operator paid for with
   `-ConfirmSilentDestructiveIso`.
2. **CCTK BIOS config apply is skipped.** `Invoke-CctkConfig`
   (unified_winpe_deploy.ps1 line 1290-1293) prints
   `"CCTK embedded but DEPLOY_IMAGE_DRIVE is unset - skipping BIOS config"`
   and returns success. The BIOS is left untouched. On a Dell fleet
   with CCTK profiles staged, that means the machine boots with
   whatever the previous BIOS state was — not the deploy contract.
3. **BitLocker recovery keys fall back to `C:\Windows\Setup\BitLockerKeys`.**
   `Resolve-BitLockerKeyPath` (line 1485-1497) only picks the IMAGES
   partition when `$env:DEPLOY_IMAGE_DRIVE` is set. Otherwise it
   silently falls back to a path on the encrypted volume itself,
   which the operator must remember to copy off before first
   reboot — or lose the recovery key on TPM reset.

All three are runtime failures on the end-user's laptop, discoverable
only after the ISO has been produced, flashed to USB, and booted. The
docs (build_iso.ps1 `.PARAMETER VolumeLabel` block, lines 83-86)
already tell the operator "Change only if you also rebuild boot.wim
with a matching label" but there's no runtime guard.

**Changed:**

- `scripts/build_iso.ps1` — new `if ($VolumeLabel -ne 'IMAGES')` block
  right after the existing `-BitLockerPin` warning, before staging
  starts. Emits four `Write-Warn` lines: header naming the mismatch,
  then a bullet list of the three silent degradations, then the
  fix-it hint (rebuild boot.wim or revert to default). Kept as a
  warning (not `throw`) because an advanced user who has already
  rebuilt boot.wim with a custom startnet.cmd should be able to
  proceed — this fires early enough (during input validation, before
  the WIM robocopy) that they can Ctrl-C if they didn't mean it.
- `CHANGELOG.md` — new `## Unreleased / ### Changed` bullet placed
  atop the existing entries; describes the three downstream effects.
- `docs/claude-routine-log.md` — this entry.

**Verification:**

- `pwsh` v7.4.6 installed once per the CLAUDE.md note (GitHub Releases
  tarball into `/opt/pwsh/`).
- `pwsh -NoProfile -File ./tests/test_parse.ps1` → 48 passed / 0
  failed (was 48/0 before the edit — `+0` new assertions, but the
  `build_iso.ps1` syntax-valid line now covers the new block).
- `pwsh -NoProfile -File ./tests/test_wim_parser.ps1` → 16/0 unchanged.
- `pwsh -NoProfile -File ./tests/test_disk_enumeration.ps1` → 34/0
  unchanged (sanity: no cross-contamination).
- Manual read of the edit against the flow above: the block sits at
  build_iso.ps1 line 211-234 (post-edit), between the BitLocker PIN
  warning and the output-dir resolution — before any file operation
  or oscdimg invocation, after all input validation.

**Risks / follow-ups:**

- Minimal. Warning-only, PSv5.1-safe (only `Write-Host` + string
  comparison), no destructive code paths touched, no new parameters
  added. Worst case: an advanced-user warning noise on custom-label
  builds — which is exactly the point.
- Outstanding backlog candidates from prior entries (unchanged from
  the 2026-05-24 pass, all still open or unclaimed):
  - `Show-ImageList` / `Show-ImageSelection` still share ~30 lines of
    listing-render code. A `Write-ImageMenuTable` helper was extracted
    on side branch 569ada0 but is not yet merged.
  - Many other `warn(...)` and `safety(...)` side branches are
    open (#231-#250, and older). None duplicate this change.

---

## 2026-05-24 — `tests/test_parse.ps1` coverage of `build_iso.ps1` + `first-login.ps1`

**Investigated:** open + closed PRs (#33-#45 all merged; nothing open),
the routine log's "next recommended improvement" backlog, and the
actual list of `.ps1` files shipped under the repo root. Compared
that inventory against the four scripts validated by `tests/test_parse.ps1`.

**Found:** the repo ships six PowerShell scripts in the deploy pipeline
(`unified_winpe_deploy.ps1` + five under `scripts/`), but
`tests/test_parse.ps1` only parses four — `scripts/build_iso.ps1`
(361 lines, added in PR #35 as the new end-user distribution
packager) and `scripts/first-login.ps1` (181 lines, staged into
target images by `prepare_wim.ps1 -DisableExtraBloat`) were never
wired in. PSSA in CI catches hard parse errors recursively, so the
gap was invisible at the CI level — but the test that CLAUDE.md
and AGENTS.md point operators and agents at for local validation
silently skipped both. A future agent renaming a function in
`build_iso.ps1` or breaking a brace in `first-login.ps1` would
need to wait for the CI PSSA job to surface it, instead of getting
an immediate local-test failure.

The script's own `.SYNOPSIS` and the CLAUDE.md table entry both
called out "four scripts" verbatim, so this was a literal documentation
drift, not just a missing assertion.

**Changed:**
- `tests/test_parse.ps1` — added `$buildIsoPath` and `$firstLoginPath`,
  two new `Test-ScriptSyntax` calls (Test 12 + Test 13) following the
  same pattern as the existing builder/prep/refresh blocks. Synopsis
  text rewritten to enumerate all six scripts instead of four.
- `CLAUDE.md` — Key Files table row and Running Checks table row
  updated; replaced the literal "four scripts" / "four deploy scripts"
  phrasing with "every shipped pipeline script" so the docs don't
  drift again the next time a script is added.
- `CHANGELOG.md` — `## Unreleased / ### Changed` bullet at the top
  describing the coverage extension. Kept short; no version bump
  (test-only change, no `$Script:Config.ScriptVersion` touch).

**Verification:**
- `pwsh` installed once per session per the CLAUDE.md note
  (PowerShell/Releases v7.4.6 tarball into `/opt/pwsh/`); the network
  policy allows the GitHub-Releases download.
- Baseline: `pwsh -NoProfile -File ./tests/test_parse.ps1` → 39 passed
  / 0 failed before edits.
- Post-edit: `pwsh -NoProfile -File ./tests/test_parse.ps1` → 43 passed
  / 0 failed (the +4 are existence + syntax-valid for each new script;
  matches the pattern set by the existing build_boot_wim / prepare_wim
  / refresh_usb blocks).
- Sanity: `pwsh -NoProfile -File ./tests/test_wim_parser.ps1` → 16/0
  unchanged (no contamination of the parser test).
- Pre-checked that `build_iso.ps1` and `first-login.ps1` both
  `PSParser::Tokenize` clean against the same PSv7 runtime so the
  newly added assertions go from missing-to-green, not missing-to-red.

**Risks / follow-ups:**
- Minimal. Test-only change. No production code touched. No new
  network dependencies. Pattern matches the existing four blocks
  exactly, including PSv5.1 compatibility (only `Join-Path`, `Get-Content`,
  and `PSParser::Tokenize` — all PSv5.1-safe).
- Outstanding routine-backlog candidates from prior entries that I
  did not take this pass:
  - **`Get-SystemDisks` fixture test** paralleling the WIM parser test
    — the last untested parser in the deploy script. Higher mock burden
    because of `Get-WmiObject` / `Win32_DiskPartition` `ASSOCIATORS OF`
    queries, but it would guard against the
    Linux/LVM-disk-reported-as-empty regression class.
  - **`Show-ImageList` / `Show-ImageSelection`** share ~30 lines of
    listing-render code that could be factored out — cleanup only,
    deferred across multiple routine entries because the menu render
    is load-bearing TUI UX.

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