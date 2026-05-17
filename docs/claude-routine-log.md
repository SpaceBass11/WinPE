# Claude Routine Maintenance Log

Lightweight log of autonomous maintenance passes on this repo. One short
entry per run. Newer entries on top. Purpose: avoid re-investigating
the same area twice.

PRs #23, #24, #25, #26, and #27 each also add this file in their own
branch. Whichever of those PRs merges last will need a trivial rebase
that keeps all entries in time order.

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
