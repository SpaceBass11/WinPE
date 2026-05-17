# Claude Routine Maintenance Log

One entry per autonomous-maintenance run. Append, don't rewrite. Keeps
future passes from re-investigating areas that were already swept.

> **Concurrent-PR note:** PRs #23, #24, #25, #26, #27, #28, #29, and #30
> each also add this file with their own first entry. Whichever lands
> first wins the create; the remaining PRs need a trivial rebase that
> keeps all entries in chronological order.

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
