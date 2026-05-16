# Claude Routine Maintenance Log

Lightweight log of autonomous-maintenance runs against this repo. One
short entry per run so future passes don't re-investigate the same areas.

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
