# Masterize Process

A once-per-release audit. **Run when you tag a new version, not every
session.** Most of what masterize used to do is now automated in CI; the
manual pass below is what CI can't do — read-driven semantic checks.

**Cadence:**
- **CI runs on every push:** the `masterize` job in
  [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs all
  mechanical doc-consistency and code-safety greps. If it's red, fix
  before merging — that's the only signal you need most of the time.
- **You run Phase 2 once per release:** before tagging `vX.Y.Z`, do
  the read pass below. Update the log entry. Tag.

Older log entries describe a multi-pass / per-session rhythm that
predates the CI port. Don't repeat that — it burned tokens for marginal
value.

---

## What CI checks (Phase 1, automated)

These run as the `masterize` job in `ci.yml`. They fail the build on
regression. You don't need to run them manually — but understanding
what they cover helps interpret a red build.

**Phase 1A — Doc consistency:**
1. Version consistency (script version appears in CHANGELOG, CLAUDE.md, README.md)
2. Cross-doc script coverage (all three scripts listed in every overview doc)
3. No stray `E:\images` references
4. Volume labels are `IMAGES` / `WinPE` / `Windows` only
5. Three-programs diagram in `ARCHITECTURE.md` mentions driver / unattend / cctk
6. README USB Drive Layout diagram lists `images/`, `cctk/`, `configs/`
7. In-script `.EXAMPLE` blocks use `I:\images\` paths

**Phase 1B — Code safety invariants:**
8. `-Force` has anti-bypass guard for `DESTROY SYSTEM`
9. `mountvol /d` guarded by `$env:SystemDrive`
10. No `Stop-Computer` (must be `shutdown.exe` for WinPE reliability)
11. Every `dism /Get-WimInfo` invocation uses `/English`
12. `dism /apply-image` uses `/CheckIntegrity`
13. `Invoke-CctkConfig` runs before `Select-TargetDisk` (positional)
14. Unattend copy is ordered `verify < unattend < bcdboot` (positional)

**Adding a new mechanical check:** add it to the `masterize` job in
`ci.yml`. Sanity-test it against a known-bad state first — break the
file, run the grep locally, confirm it FAILs, revert. A check that
silently passes is worse than no check.

---

## Phase 2 — Read-driven semantic checks (manual, once per release)

These need you to read and judge. CI can't do them. Each was added in
response to a real miss.

### A. Cross-reference accuracy

Every "Step N", "Section X", "see <doc>" reference must point to the
correct target. Grep can confirm the reference exists; only reading the
target can confirm it's correct.

```bash
grep -rn 'USB_SETUP.md Step [0-9]\|Step [0-9].*USB_SETUP' docs/ README.md
# For each match, open USB_SETUP.md and confirm the step number does
# what the reference claims.
```

Past miss: `TROUBLESHOOTING.md` said "USB_SETUP.md Step 4" for the
`IMAGES` volume label, but Step 4 is the xcopy step — the label is set
in Step 3.

### B. Diagram completeness

When prose describes a flow with N steps, every diagram in the same doc
that summarizes that flow must include all N. CI checks the two known
recurring diagrams (three-programs, USB layout). New diagrams need a
manual check or a new CI rule.

For each ASCII diagram in `docs/ARCHITECTURE.md`, `README.md`, and the
deploy script header, compare its bullets against the prose section
that describes the same flow. If the prose lists a step the diagram
doesn't, fix the diagram.

### C. Doc staleness

Any doc with a date header — audit files, anything in `docs/` that
opens with `(YYYY-MM-DD)` — is suspect once more than ~3 months old
or once two releases have shipped past it. Time-stamped review
artifacts (e.g. previous `DEEP_REVIEW.md`) belong under
`.claude/reviews/`, not in user-facing `docs/`.

```bash
grep -l '^# .*([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\})' docs/
# For each, compare against current CHANGELOG and current scripts list.
```

### D. Self-improvement

If you found an issue this release, ask:

- **Can a future grep catch it?** Yes → add a check to the `masterize`
  job in `ci.yml`.
- **Or is it judgment-only?** Yes → add a Phase 2 entry above.

Sanity-test new CI checks against a known-bad state before adding them.

---

## Log

[`masterize-log.md`](./masterize-log.md) (alongside this file) records
past passes and meta-changes. Future entries should be per-release
(one per tagged version), not per-session.
