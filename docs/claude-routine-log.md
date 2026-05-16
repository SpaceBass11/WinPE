# Claude Routine Maintenance Log

Lightweight, one-entry-per-run log so the autonomous maintenance agent
doesn't keep re-investigating the same areas. Newest entries on top.

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
