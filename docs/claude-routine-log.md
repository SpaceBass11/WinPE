# Claude Routine Maintenance Log

Lightweight log of autonomous-maintenance passes. Each entry summarises
what was investigated, what (if anything) changed, how the change was
verified, and the next recommended improvement so the next pass doesn't
re-investigate the same area.

> **Cross-PR note:** at the time this file was created (2026-05-17) six
> prior routine PRs (#23, #24, #25, #26, #27, #28) also each add this
> same file with their own first entry. Whichever PR merges first wins
> the create; the rest will need a trivial rebase that keeps all
> entries in time order. This is by design — the routine brief expects
> a persisted log, and one had to be the first.

---

## 2026-05-17 — `tests/test_parse.ps1`: add `first-login.ps1` syntax coverage

**Investigated:**
- Open routine PRs #23–#28 to avoid duplicating work.
- The set of `.ps1` files under the repo vs. the set covered by
  `tests/test_parse.ps1`.
- Whether `PSScriptAnalyzer`'s recursive CI job already catches parser
  errors in any uncovered scripts.

**Changed:**
- `tests/test_parse.ps1` — added `scripts/first-login.ps1` (the
  per-user debloat / UX-tweak script PR #21 added at v4.6.0, staged
  into `C:\Windows\Setup\Scripts\` inside the deployed image and run
  at first sign-in via the unattend `FirstLogonCommands` entry) to
  the per-script syntax pass:
  - New `$firstLoginPath` variable beside the existing
    `$builderPath` / `$prepPath` / `$refreshPath`.
  - New `Test 12` invoking the existing `Test-ScriptSyntax` helper.
  - Synopsis updated to list the fifth covered script.
- `docs/claude-routine-log.md` *(new)* — this file.

**Verification:**
- Brace balance on the edited `tests/test_parse.ps1`: open/close counts
  unchanged in net (added a new helper invocation that mirrors the
  existing four `Test-ScriptSyntax` calls).
- Brace balance on `scripts/first-login.ps1` confirmed via shell grep:
  57 / 57, consistent with a well-formed script.
- `pwsh` is not installed in this Linux session, so `tests/test_parse.ps1`
  cannot run locally — same constraint flagged in PRs #23–#28 and
  `.claude/reviews/2026-05-11-deep-review.md`'s Validation Notes. CI's
  `syntax` job on `windows-latest` runs the real
  `[System.Management.Automation.PSParser]::Tokenize` on push.

**Risks:**
- Minimal. Test-only addition; production scripts untouched. Worst case
  is `first-login.ps1` failing its first CI run — that would mean we'd
  surfaced an existing latent parser issue in a script that runs inside
  every deployed image, which is the whole point of adding the check.

**Why this and not something else:**
- All other obvious low-hanging fruit (log path on exit, DISM exit codes,
  BCDBoot diagnostics, prepare_wim destination name, refresh_usb wrapper
  parity, fixture test for `Get-WimImageInfo`) is already covered by
  open PRs #23–#28.
- PSSA's CI job would catch a parser error in `first-login.ps1`
  *implicitly* via its recursive scan, but explicit per-script coverage
  in `test_parse.ps1` matches the pattern set for the other four scripts
  and surfaces failures with cleaner per-script PASS/FAIL output.

**Next recommended improvement(s):**
- The `Set-BootConfiguration` callers in `Start-Deployment` and the
  `Apply-WindowsImage` callers print a recovery banner from the *caller*
  while the new function-level diagnostics in PR #27 print from inside
  the function — once #27 merges, audit whether the two layers say the
  same thing in different words and consolidate.
- A fixture test for `Get-SystemDisks` partition enumeration paralleling
  PR #24's WIM-parser test (the last untested parser in the deploy
  script). Higher mock burden than the WIM parser because the function
  is `Get-WmiObject`-heavy; a pure-logic refactor would help.
- `Show-ImageList` / `Show-ImageSelection` share ~30 lines of listing
  code that could be factored out — flagged in PRs #26, #27, #28 as a
  cleanup-only follow-up; deferred because UX is load-bearing here.
