# Claude routine maintenance log

Lightweight log per the autonomous-maintenance brief. One short entry
per run so future passes don't re-investigate the same areas.

> **Note on duplicates:** open PRs #23-#29 each also add this file
> with their own first entry. Whichever PR merges first wins the
> create; the others will need a trivial rebase that keeps all
> entries in time order. Acknowledged.

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
