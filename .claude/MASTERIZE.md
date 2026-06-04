# Masterize Process

A once-per-release audit. **Run when you tag a new version, not every
session.** Most of what masterize used to do is now automated in CI; the
manual pass below is what CI can't do -- read-driven semantic checks.

**Cadence:**
- **CI runs on every push:** the `masterize` job in
  [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs all
  mechanical doc-consistency and code-safety greps. If it's red, fix
  before merging -- that's the only signal you need most of the time.
- **You run Phase 2 once per release:** before tagging a release, do
  the read pass below.

Older `masterize-log.md` entries describe a multi-pass / per-session
rhythm (and the earlier WinPE/MDT line) that predates the CI port and the
Clonezilla pivot. They are history -- don't repeat that rhythm, and don't
rewrite the log.

---

## What CI checks (Phase 1, automated)

These run as the `masterize` job in `ci.yml` and fail the build on
regression. You don't need to run them manually -- understanding what
they cover helps interpret a red build. See `ci.yml` for the exact greps;
the current set (numbered there) is:

**Script invariants (`ManualClonezilla/Scripts/`):**
1. `SetupComplete.cmd` calls the first-boot set (Apply-DellConfig,
   Scrub-AuditArtifacts, New-LocalAccounts, Stage-DockerData, Set-Level0ACL,
   Harden-Administrator, Assert-AdminGroup, Enable-BitLocker, Finalize-Cleanup)
   **and** does NOT call the gold-phase scripts (Disable-RDP,
   Apply-StigHardening, Install-NotepadPP).
2-5. BitLocker: TpmAndPin (not Tpm-only) protector, RecoveryPassword
   protector added, recovery-key export path
   `C:\ProgramData\ManualClonezilla\RecoveryKeys`, TpmPin + RecoveryPassword
   verification gates after enable, ACL-locked key dir + skip-path recovery guard.
6-7. Finalize-Cleanup removes the staged secrets; Apply-DellConfig hard-fails
   on missing inputs.
7a-7k. Per-script behavior: Set-Level0ACL deny ACE; Harden-Administrator
   RID-500 disable/rename; Disable-RDP `fDenyTSConnections`; New-LocalAccounts
   group-by-SID; Install-NotepadPP `exit 0`; Scrub autologon/Panther;
   Apply-StigHardening Guest-501/lockout/UAC; Stage-DockerData CreateProfile +
   non-fatal; Assert-AdminGroup hard-fail; Apply-GoldHardening runs the 3
   gold-phase scripts.

**Doc invariants:**
8-16. No MDT mechanics in operational docs; README points at Rufus + ISO;
   RUNBOOK documents `bitlocker-pin.txt`, `accounts.csv`, and the pre-sysprep
   `Apply-GoldHardening` run; OPERATIONS documents the recovery-key location;
   unattend keeps `CopyProfile=true`; recovery-key path consistent across docs;
   no stale `State\` or `C:\ProgramData\BitLockers` recovery path.

**Adding a new mechanical check:** add it to the `masterize` job in
`ci.yml`. Sanity-test it against a known-bad state first -- break the
file, run the grep locally, confirm it FAILs, revert. A check that
silently passes is worse than no check.

---

## Phase 2 -- Read-driven semantic checks (manual, once per release)

These need you to read and judge. CI can't do them. Each was added in
response to a real miss.

### A. The first-boot / gold-phase chain agrees everywhere

The deploy chain order and the gold-vs-first-boot split are stated in
several places that must agree: `ManualClonezilla/Scripts/SetupComplete.cmd`
(the source of truth), `CLAUDE.md` (Architecture diagram + key-files table),
`README.md`, `docs/RUNBOOK.md`, and `docs/ARCHITECTURE.md`. Read each and
confirm the step list and the "this runs in the gold, that runs at first
boot" labelling match the `.cmd`. CI check 1 pins the `.cmd` itself; the
prose copies are judgment-only.

### B. Cross-reference accuracy

Every "Step N", "Section X", "see <doc>" reference must point to the
correct target. Grep can confirm the reference exists; only reading the
target can confirm it's correct.

```bash
grep -rn 'RUNBOOK.md\|USB_SETUP.md\|ARCHITECTURE.md' docs/ README.md CLAUDE.md
# For each match, open the target and confirm it says what the reference claims.
```

### C. Diagram completeness

When prose describes a flow with N steps, every ASCII diagram in the same
doc (and the diagrams in `README.md` / `docs/ARCHITECTURE.md` / `CLAUDE.md`)
that summarizes that flow must include all N. Compare each diagram's bullets
against the prose; if the prose lists a step the diagram doesn't, fix the
diagram.

### D. Path consistency after a layout change

The repo mirrors the on-disk staging tree (`ManualClonezilla/Scripts`,
`ManualClonezilla/Config`, `configs/unattend.example.xml`). After any move,
confirm docs/CI reference the real locations:

```bash
# Stale references to a MOVED script (PascalCase *.ps1) at the old top-level
# scripts/ path. Targets the moved files specifically so it does not flag the
# historical scripts/mdt/ mentions in CHANGELOG / CLAUDE.
git grep -nE 'scripts/[A-Z][A-Za-z-]*\.ps1' -- . ':(exclude)CHANGELOG.md' | grep -v 'ManualClonezilla/Scripts'
# Expect no hits.
```

### E. Doc staleness

Any doc with a date header is suspect once two releases have shipped past
it. Time-stamped review artifacts belong under `.claude/reviews/`, not in
user-facing `docs/`.

```bash
grep -rl '([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\})' docs/
# For each, compare against current CHANGELOG and the current scripts list.
```

### F. Self-improvement

If you found an issue this release, ask:

- **Can a future grep catch it?** Yes -> add a check to the `masterize`
  job in `ci.yml` (sanity-test against a known-bad state first).
- **Or is it judgment-only?** Yes -> add a Phase 2 entry above.

---

## Log

[`masterize-log.md`](./masterize-log.md) (alongside this file) is an
append-only record of past passes. Older entries reference the earlier
WinPE/MDT line -- that's history; read them for recurring root causes, but
do not rewrite them. Add new entries per tagged release, not per session.
