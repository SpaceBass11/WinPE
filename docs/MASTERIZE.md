# Masterize Process

A multi-phase audit run before any significant release or whenever the
user says "masterize". The phases are layered:

- **Phase 1A** (doc consistency) — fast greps on documentation.
- **Phase 1B** (code safety invariants) — fast greps on the deploy script.
- **Phase 2** (semantic checks) — read-driven, judgment required.

Run all three every time. Phase 1A clean does not imply Phase 1B clean,
and neither implies Phase 2 clean.

**Before you start:** read [`.claude/masterize-log.md`](../.claude/masterize-log.md)
— it records what prior sessions caught, including issues whose root cause
came back later. If a prior session added a new check, you must run it.

**When you finish:** append a new entry to that log. If a later phase
caught something an earlier phase didn't, add a new earlier-phase check
(or a Phase 2 entry if it can't be mechanized) so the next session
catches it for free. This is how the process improves itself.

**Sanity-test new checks before adding them.** A grep that silently
returns empty is indistinguishable from one that passes. Before adding
a check, deliberately break the relevant file, run the grep, confirm
it complains, then revert. (Pass 4 discovered that check 5 had been
silently passing for 3 passes because its grep pattern was wrong.)

---

## Phase 1A: Doc Consistency

Each item is a concrete grep — copy-pasteable, no judgement required.
Work top to bottom; fix anything that fails before moving on.

### 1. Version Consistency

| Location | What to check |
|----------|---------------|
| `unified_winpe_deploy.ps1` line ~4 | `.VERSION X.Y.Z` header comment |
| `unified_winpe_deploy.ps1` line ~39 | `$Script:Config.ScriptVersion = 'X.Y.Z'` |
| `CHANGELOG.md` | Latest `## [X.Y.Z]` section matches both above |
| `CHANGELOG.md` `[Unreleased]` link | Compare URL ends with `vX.Y.Z...HEAD` |
| `CHANGELOG.md` bottom | `[X.Y.Z]: .../releases/tag/vX.Y.Z` link exists |
| `docs/KNOWN_ISSUES.md` header | Title line says `(vX.Y.Z)` and lists all three scripts |
| `CLAUDE.md` Project Overview | First paragraph says `(vX.Y.Z)` |
| `README.md` | Version badge / footer matches |

```bash
# Quick grep — all should print the same version string
grep -n 'ScriptVersion\|\.VERSION\|^\## \[4' unified_winpe_deploy.ps1 CHANGELOG.md
grep -n 'v4\.' docs/KNOWN_ISSUES.md CLAUDE.md README.md | head -20
```

### 2. Cross-Doc Script Coverage

All three scripts must appear in every overview table:

- `README.md` — "Companion scripts" or "Parameters" table
- `ARCHITECTURE.md` — file layout / key files table
- `CLAUDE.md` — Key Files table
- `docs/KNOWN_ISSUES.md` — header line listing scripts

```bash
for f in README.md docs/ARCHITECTURE.md CLAUDE.md docs/KNOWN_ISSUES.md; do
  echo "=== $f ==="; grep -c 'prepare_wim\|build_boot_wim\|unified_winpe_deploy' "$f"
done
```

### 3. Drive-Letter Conventions

| Letter | Context | Correct usage |
|--------|---------|---------------|
| `I:\` | Admin workstation | IMAGES data partition when partitioning USB |
| `P:\` | Admin workstation | WinPE FAT32 boot partition |
| `D:\` | WinPE runtime | IMAGES partition as seen from booted WinPE |
| `X:\` | WinPE runtime | RAM disk (scripts, logs live here) |
| `C:\` | Target | Windows is deployed here |
| `S:\` | Target | EFI partition (hardcoded in diskpart script) |

Check for stray `E:\images\` references (the old incorrect convention):

```bash
grep -rn 'E:\\images\|E:/images' docs/ scripts/ unified_winpe_deploy.ps1
# Should produce zero matches
```

### 4. Volume Labels

Labels must be uppercase and consistent:

```bash
grep -rn 'label=' docs/ scripts/ | grep -iv '"IMAGES"\|"WinPE"\|label=Windows'
# Any match here is a bug — labels should be IMAGES and WinPE exactly.
# Known false positive (already filtered above): validate_script.ps1's
# check for the C:\ target partition uses label=Windows.
```

### 5. Parameter Coverage in SCRIPT_REFERENCE.md

Every parameter in each script must have a matching section in
`docs/SCRIPT_REFERENCE.md`:

```bash
# Extract param names from each script
grep '^\s*\[' unified_winpe_deploy.ps1 | grep 'Parameter\|string\|switch\|int' | grep -v '#'
grep '^\s*\[' scripts/prepare_wim.ps1 | grep 'Parameter\|string\|switch\|int' | grep -v '#'
grep '^\s*\[' scripts/build_boot_wim.ps1 | grep 'Parameter\|string\|switch\|int' | grep -v '#'

# Then confirm each name appears as a section header
grep '^### -' docs/SCRIPT_REFERENCE.md
```

### 6. Non-Goals Accuracy

`docs/ARCHITECTURE.md` and `README.md` "Don't use this if you" non-goals
must not list features that are now implemented:

- Driver injection → supported via `prepare_wim.ps1 -DriverPath` ✓
- Unattend.xml / OOBE / domain join → supported via `-UnattendFile` ✓
- BIOS config → supported via CCTK ✓

```bash
grep -n 'non.goal\|not.*support\|driver inject\|domain join\|unattend' \
  docs/ARCHITECTURE.md README.md | grep -iv 'supported\|now\|via'
```

### 7. Deployment Flow Completeness

The numbered steps must be consistent across three sources. Spot-check
that unattend staging, CCTK, and extra-wipe steps appear in all three:

- `CLAUDE.md` Deployment Flow (steps 1–20)
- `docs/ARCHITECTURE.md` runtime data flow diagram
- `docs/USB_SETUP.md` Step 6 test sequence

```bash
grep -n 'Unattend\|unattend\|CCTK\|cctk\|wipe\|Wipe' \
  CLAUDE.md docs/ARCHITECTURE.md docs/USB_SETUP.md
```

### 8. In-Script .EXAMPLE Paths

`.EXAMPLE` blocks inside scripts must use documented conventions
(`I:\images\` for admin workstation, not `E:\` or `D:\`):

```bash
grep -n '\.EXAMPLE' -A 10 unified_winpe_deploy.ps1 scripts/prepare_wim.ps1 \
  scripts/build_boot_wim.ps1 | grep 'images\\'
# All paths shown should start with I:\images\
```

### 9. CHANGELOG Link Integrity

```bash
# [Unreleased] compare URL
grep '\[Unreleased\]' CHANGELOG.md

# Every [X.Y.Z] section header has a matching link at the bottom
versions=$(grep '^\## \[' CHANGELOG.md | grep -oP '\d+\.\d+\.\d+')
for v in $versions; do
  if grep -q "\[$v\]:" CHANGELOG.md; then echo "OK $v"; else echo "MISSING link for $v"; fi
done
```

### 10. Three-Programs Diagram Feature Coverage

The compact ASCII diagram in `docs/ARCHITECTURE.md` must include each
script's current major capabilities:

```bash
# prepare_wim.ps1 column must mention driver injection (v4.6.0)
grep -A 15 'Prep time (admin Windows)' docs/ARCHITECTURE.md | grep 'driver'

# deploy script column must mention unattend staging (v4.6.0) and CCTK (v4.5.0)
grep -A 15 'Run time (inside WinPE)' docs/ARCHITECTURE.md | grep -i 'unattend'
grep -A 15 'Run time (inside WinPE)' docs/ARCHITECTURE.md | grep -i 'cctk'
# All three greps must produce output — empty = diagram is stale
```

### 11. README USB Drive Layout Diagram Coverage

The `## USB Drive Layout` ASCII diagram in `README.md` must list every
optional directory used by the deploy script:

```bash
grep -A 12 '## USB Drive Layout' README.md | grep 'images/'
grep -A 12 '## USB Drive Layout' README.md | grep 'cctk/'
grep -A 12 '## USB Drive Layout' README.md | grep 'configs/'
# Each must produce output. Empty = diagram is stale.
```

---

## Phase 1B: Code Safety Invariants

These greps run against `unified_winpe_deploy.ps1` and verify that the
deploy script's safety properties haven't regressed. Each prints `OK`
or `FAIL`. Any `FAIL` is a release blocker.

**Why these matter:** the script wipes disks. The invariants below are
the difference between "operator types a confirmation and the right
thing happens" and "automation silently destroys the wrong disk". They
need mechanical verification, not memory.

```bash
echo "=== 12. -Force has explicit anti-bypass guard for system disk ==="
grep -q 'Force cannot bypass\|cannot bypass system' unified_winpe_deploy.ps1 \
  && echo "OK" || echo "FAIL — -Force anti-bypass guard missing near DESTROY SYSTEM"

echo "=== 13. mountvol /d is guarded by \$env:SystemDrive ==="
grep -B 6 'mountvol.*\/d' unified_winpe_deploy.ps1 | grep -q 'SystemDrive' \
  && echo "OK" || echo "FAIL — mountvol /d call lacks SystemDrive guard above it"

echo "=== 14. No Stop-Computer (must use shutdown.exe in WinPE) ==="
grep -q 'Stop-Computer' unified_winpe_deploy.ps1 \
  && echo "FAIL — Stop-Computer found; use shutdown.exe instead" || echo "OK"

echo "=== 15. dism /Get-WimInfo invocations all use /English ==="
bad=$(grep -n 'dism\.exe.*Get-WimInfo\|& dism.*Get-WimInfo' unified_winpe_deploy.ps1 | grep -v '/English')
[ -z "$bad" ] && echo "OK" || (echo "FAIL — invocation missing /English:"; echo "$bad")

echo "=== 16. dism /apply-image invocation uses /CheckIntegrity ==="
ai=$(grep -n '\/apply-image' unified_winpe_deploy.ps1 | grep -v 'Write-Log\|Recovery\|manually\|Last resort\|#')
echo "$ai" | grep -q '/CheckIntegrity' \
  && echo "OK" || echo "FAIL — /apply-image invocation missing /CheckIntegrity"

echo "=== 17. CCTK runs before disk selection (no disks touched on CCTK abort) ==="
cctk_call=$(grep -n 'Invoke-CctkConfig' unified_winpe_deploy.ps1 | grep -v 'function ' | head -1 | cut -d: -f1)
disk_call=$(grep -n 'Select-TargetDisk -Disks' unified_winpe_deploy.ps1 | head -1 | cut -d: -f1)
if [ -n "$cctk_call" ] && [ -n "$disk_call" ] && [ "$cctk_call" -lt "$disk_call" ]; then
  echo "OK (cctk line $cctk_call < disk-select line $disk_call)"
else
  echo "FAIL — CCTK call (line $cctk_call) is not before disk selection (line $disk_call)"
fi

echo "=== 18. Unattend copy ordered between post-deploy verify and bcdboot ==="
verify_line=$(grep -n 'verifyPaths' unified_winpe_deploy.ps1 | head -1 | cut -d: -f1)
panther_line=$(grep -n 'pantherDir.*Panther' unified_winpe_deploy.ps1 | head -1 | cut -d: -f1)
bcdboot_line=$(grep -n 'Set-BootConfiguration' unified_winpe_deploy.ps1 | grep -v 'function ' | head -1 | cut -d: -f1)
if [ "$verify_line" -lt "$panther_line" ] && [ "$panther_line" -lt "$bcdboot_line" ]; then
  echo "OK (verify $verify_line → unattend $panther_line → bcdboot $bcdboot_line)"
else
  echo "FAIL — order should be verify < unattend < bcdboot, got $verify_line / $panther_line / $bcdboot_line"
fi
```

If any check above prints `FAIL`, fix the script before continuing. A
failure here means an operator-facing safety contract has regressed.

---

## Phase 2: Semantic Checks (read-driven)

These need you to read the file and judge, not just grep. Phase 1 clean
does not imply Phase 2 clean. Each check below was added in response to
a real miss; don't skip them.

### A. Cross-reference accuracy

Every "Step N", "Section X", "see <doc>" reference must point to the
correct target. Grep can confirm the reference exists; only reading the
target can confirm it's correct.

```bash
# Find every cross-reference to a numbered step in USB_SETUP.md
grep -rn 'USB_SETUP.md Step [0-9]\|Step [0-9].*USB_SETUP' docs/ README.md
# For each match, open USB_SETUP.md and confirm the step number actually
# does what the reference claims.
```

Concrete miss (Pass 2): `docs/TROUBLESHOOTING.md` said "matches
USB_SETUP.md Step 4" for the `IMAGES` volume label, but Step 4 is the
xcopy step — the label is set in Step 3.

### B. Diagram completeness

When prose describes a flow with N steps, every diagram in the same doc
that summarizes that flow must include all N. Grep can find the keyword
in the file but cannot tell you it's missing from a specific ASCII box.

Action: for each ASCII diagram in `docs/ARCHITECTURE.md`, `README.md`,
and the deploy script header, compare its bullets against the
corresponding prose section. If the prose lists a step the diagram
doesn't, fix the diagram.

Concrete misses (Passes 2, 3, 4): the same pattern has now hit three
different diagrams. Phase 1 checks 10 and 11 mechanize the two known
recurring offenders. New diagrams should get their own check.

### C. Release-coverage in KNOWN_ISSUES.md

Every release that adds a feature must have a corresponding entry under
"Recently Fixed" in `docs/KNOWN_ISSUES.md`:

```bash
# Releases in CHANGELOG
grep '^\## \[' CHANGELOG.md | grep -oP '\d+\.\d+\.\d+'

# Versions referenced in KNOWN_ISSUES.md
grep -oP 'v\d+\.\d+\.\d+' docs/KNOWN_ISSUES.md | sort -u

# Every CHANGELOG version should appear at least once in KNOWN_ISSUES.
```

Concrete miss (Pass 2): v4.6.0 added `-DriverPath` and `-UnattendFile`
but `docs/KNOWN_ISSUES.md` had no v4.6.0 entries.

### D. Doc staleness

Any doc with a date header — `DEEP_REVIEW.md`, audit files, anything
in `docs/` that opens with `(YYYY-MM-DD)` — is suspect once more than
~3 months old or once two releases have shipped past it.

```bash
grep -l '^# .*([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\})' docs/
# For each, compare against current CHANGELOG and current scripts list.
```

Concrete miss (Pass 2): `docs/DEEP_REVIEW.md` was dated 2026-03-17 and
predated v4.5.0 and v4.6.0. Its scope only mentioned the deploy script,
missing the other two scripts entirely.

### E. Self-Improvement

If you found an issue this session, ask:

- **Could a future grep catch this?** Yes → add a Phase 1 check.
- **Or is it judgment-only?** Yes → add a Phase 2 entry explaining what
  to read and why.

Then record it in `.claude/masterize-log.md` under "New checks added".

Every masterize pass should leave the process slightly stronger than it
found it. If three sessions catch the same class of bug semantically,
the next session should mechanize the check.

---

## Session Log

`.claude/masterize-log.md` is the durable record. Each entry is one
masterize pass. Future sessions read it before starting a pass.
