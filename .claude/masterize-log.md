# Masterize Session Log

Durable record of every `/masterize` pass. Newest at top. Future
Claude sessions: **read this before running a pass.** It tells you
what prior sessions caught, including issues whose root cause might
recur.

Format for new entries:

```
## YYYY-MM-DD — (commit <short-sha> on <branch>)

**Phase 1 result:** clean / N issues found and fixed
**Phase 2 result:** clean / N issues found and fixed

**Phase 1 catches:**
- [ ] none / list

**Phase 2 catches:**
- [ ] none / list

**New checks added to process:**
- [ ] none / list (these go in CLAUDE.md under Phase 1 or Phase 2)

**Notes / patterns observed:**
- free-form
```

---

## 2026-05-12 — CI Handoff (commit TBD on claude/masterize-improvements)

**Process change. This log entry is meta, not a pass.**

All Phase 1 checks (both 1A doc-consistency and 1B code-safety) have
been ported into the `masterize` job in `.github/workflows/ci.yml`.
They run on every push and PR. There is no longer any reason to run
them manually in a Claude session.

`docs/MASTERIZE.md` was rewritten to be a per-release Phase 2 reference
(read-driven checks only) plus a description of what CI covers for
context. CLAUDE.md was trimmed to a 10-line summary with explicit
guidance: **do not run masterize per session**.

**Future cadence:**
- CI red on a PR → fix it, re-push.
- Tagging a release → do the Phase 2 read pass in `docs/MASTERIZE.md`,
  update CHANGELOG, tag, append one log entry here per release.
- Anything else → don't run masterize.

**Why this matters:**
The previous trajectory was elaborating the process per session, with
each pass adding checks/logs that the next session had to read. The
marginal value per session was decreasing while the per-session token
cost was compounding. CI runs at zero session cost.

**Sanity-tested locally before pushing:** all 15 CI checks pass on
current code. Found two false-positive bugs in the design pass:
check 3 was matching `MASTERIZE.md`'s own documentation of the bad
pattern (fixed by excluding the file); check 7's `-A 12` window
didn't reach `cctk/` after `configs/` was added (fixed to `-A 16`).
Both would have been silent passes in a session; CI catches them.

---

## 2026-05-12 — Process Restructure (commit c4848da on claude/masterize-improvements)

Not a normal pass — this entry records a structural change to the
process itself, prompted by user request to critique and improve it.

**What changed:**
- Moved the masterize playbook out of `CLAUDE.md` into
  `docs/MASTERIZE.md`. CLAUDE.md kept a 15-line summary + pointer.
  CLAUDE.md dropped from 465 lines to ~200, reducing the per-session
  context tax.
- Added **Phase 1B: Code Safety Invariants** — 7 grep/positional checks
  that run against `unified_winpe_deploy.ps1` to verify safety
  properties haven't regressed:
  - 12. `-Force` anti-bypass guard near `DESTROY SYSTEM`
  - 13. `mountvol /d` guarded by `$env:SystemDrive`
  - 14. No `Stop-Computer` (must use `shutdown.exe`)
  - 15. All `dism /Get-WimInfo` invocations use `/English`
  - 16. `dism /apply-image` uses `/CheckIntegrity`
  - 17. CCTK runs before disk selection (positional)
  - 18. Unattend copy ordered between System32 verify and bcdboot
- Each Phase 1B check emits explicit `OK` / `FAIL` so a session can
  tell at a glance whether it passed. Phase 1A checks still print
  raw output — migrate as opportunity allows.
- Added preamble note: **sanity-test new checks against a known-bad
  state before adding them.** Prompted by Pass 4's discovery that
  check 5 had been silently returning empty for 3 passes.
- Folded Pass 4's check-5 grep fix and check-12 (README USB layout)
  into the new playbook so this branch is a superset.

**Why:**
Previous critique flagged that masterize was overweighted toward docs
and barely touched the script itself. The script is the actual
product — destructive code that operators run with admin rights — and
its safety invariants were enforced only by reviewer memory.
Phase 1B mechanizes the safety contract.

**Notes:**
- Phase numbering: existing Pass 1–4 log entries use "Phase 1" /
  "Phase 2". Going forward, sessions should report "Phase 1A" /
  "Phase 1B" / "Phase 2" separately. Old entries stay as written.
- The "concrete miss this caught" annotations were trimmed from
  MASTERIZE.md (the log is the durable record; the playbook should be
  evergreen instructions, not change history).

---

## 2026-05-11 — Pass 3 (commit fad4b93 on claude/fix-disk-partitioning-VdGdp → main)

**Phase 1 result:** clean (10/10 mechanical checks passed, plus new check 11 added)
**Phase 2 result:** 3 issues found and fixed

**Phase 1 catches:** none

**Phase 2 catches:**
- `docs/ARCHITECTURE.md`: three-programs diagram missing `- optional drivers`
  in the `prepare_wim.ps1` column. `-DriverPath` driver injection was added in
  v4.6.0 but the diagram column was never updated. Fixed by adding
  `│  - optional drivers       │` to the prepare_wim column. Same pattern as
  the "unattend staging missing from deploy column" catch in Pass 2.
- `docs/SCRIPT_REFERENCE.md` line 267: `-UsbDrive` parameter description said
  the FAT32 boot partition was "created per USB_SETUP.md Step 4". Step 3 creates
  the partition (diskpart, format, assign letter=P); Step 4 only copies WinPE
  content to it. Fixed "Step 4" → "Step 3".
- `docs/KNOWN_ISSUES.md`: items A and B (Silent contract, WimFile validation)
  lacked `(v4.3.0)` version tags, inconsistent with items C-J which all carry
  version tags. Fixed by adding `(v4.3.0)` to both headers.

**New checks added to process:**
- Phase 1 check 11: Three-programs diagram feature coverage — greps confirm
  the prepare_wim.ps1 column mentions "driver" and the deploy column mentions
  "unattend" and "cctk". Mechanizes the diagram-completeness pattern that has
  now been caught in two consecutive passes.

**Notes / patterns observed:**
- The diagram-miss pattern (Phase 2 check B) has now recurred twice in a row.
  The new Phase 1 check 11 should prevent it recurring a third time.
- The step-reference bug (SCRIPT_REFERENCE.md "Step 4" vs "Step 3") is a
  low-level instance of Phase 2 check A (cross-reference accuracy). It's the
  kind of thing that drifts when a doc is rewritten and step numbers shift.
- Version tag consistency (items A/B) is cosmetic but reduces operator
  confusion when scanning the Recently Fixed section chronologically.

---

## 2026-05-11 — Pass 2 (commit b44085c on claude/fix-disk-partitioning-VdGdp)

**Phase 1 result:** clean (10/10 mechanical checks passed)
**Phase 2 result:** 4 issues found and fixed

**Phase 1 catches:** none

**Phase 2 catches:**
- `docs/TROUBLESHOOTING.md`: wrong cross-reference — "USB_SETUP.md Step 4"
  for the IMAGES volume label, but the label is set in Step 3 (partition
  step), not Step 4 (xcopy step). Fixed.
- `docs/ARCHITECTURE.md`: compact three-programs diagram at the top of
  the file was missing the `unattend staging` row in the deploy column,
  even though the runtime data-flow section lower in the same file
  listed it. Fixed.
- `docs/KNOWN_ISSUES.md`: "Recently Fixed" section had entries for
  v4.5.0 (G, H) and v4.3.0 (A, B) and v4.4.0 (C-F), but no v4.6.0
  entries for the two new features. Added entries I (`-DriverPath`)
  and J (`-UnattendFile`).
- `docs/DEEP_REVIEW.md`: stale — dated 2026-03-17 (pre-v4.5.0). Scope
  section mentioned only the deploy script, missing `build_boot_wim.ps1`
  and `prepare_wim.ps1`. The "Suggested Ongoing Review Checklist" inside
  it predated the Masterize Checklist in CLAUDE.md. Full rewrite to
  v4.6.0 state.

**New checks added to process:**
- Phase 2 section restructured into named checks A-E in CLAUDE.md so
  future sessions don't have to rediscover these miss categories:
  - A. Cross-reference accuracy
  - B. Diagram completeness
  - C. Release-coverage in KNOWN_ISSUES.md
  - D. Doc staleness
  - E. Self-improvement loop (codified)

**Notes / patterns observed:**
- All four catches were semantic — none were greppable. This is the
  argument for keeping Phase 2 mandatory even when Phase 1 is clean.
- Three of the four (B, C, D) were "the prose says X but the diagram/
  summary/scope says ~X". Pattern: when adding a feature, every
  view of the feature must be updated, not just the canonical one.
  CHANGELOG.md is canonical; KNOWN_ISSUES.md, README.md, ARCHITECTURE.md
  diagrams, and DEEP_REVIEW.md are derived views that drift.
- Doc staleness (D) is time-driven, not change-driven. A dated review
  doc should be checked every release even if nothing in its scope
  has changed, because its claims about coverage may have been
  invalidated by a release that broadened scope.

---

## 2026-05-11 — Pass 1 (commit 4259ea1 on claude/fix-disk-partitioning-VdGdp)

**Phase 1 result:** clean (10/10 mechanical checks passed)
**Phase 2 result:** not run this pass — Phase 2 was added afterward
based on what Pass 2 caught

**Phase 1 catches:** none

**Phase 2 catches:** N/A

**New checks added to process:**
- This was the inaugural run after the Masterize Checklist was added
  to CLAUDE.md. Process was grep-only at the time.

**Notes / patterns observed:**
- All grep checks were clean on first run. Subsequent deeper read pass
  (Pass 2 above) revealed that grep-clean ≠ docs-clean.
