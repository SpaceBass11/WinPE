Run a multi-angle deep review of scripts/mdt/ and docs. Use parallel agents for each analysis pass, then fix everything found.

## Phase 1: Research (run ALL of these in parallel as separate agents)

### Agent 1: Script Correctness — Execution Path Trace

For each function in `Initialize-MDTDeploymentShare.ps1`, trace what happens with:
- Missing or invalid WIM path (file does not exist, wrong extension)
- MDT not installed (module path absent, PSDrive creation fails)
- PSDrive `DS001` already mounted from a previous run
- `ts.xml` not found after task sequence creation
- `Enable-BitLocker.ps1` not found at `$PSScriptRoot`

Also check `Start-MDT.ps1` (interactive launcher) and `START.bat` (UAC elevation shim):
- Config persistence: does `configs/launcher-config.json` load and save correctly across menu re-entries?
- PIN validation: does the PIN input path reject invalid values cleanly before passing to Initialize?
- Output path writability: is the ISO output path checked for write access before kicking off `New-MDTMedia.ps1`?
- Elevation handling: does `START.bat` correctly detect non-elevated context and re-launch elevated via `runas`/`Start-Process`?
- Unattend.xml handoff: after step 3 (ISO build), is the unattend.xml path correctly communicated or staged for the operator?

Only list things that would cause wrong behavior, silent failure, or data loss — no style issues.

### Agent 2: Doc/Code Consistency

Compare every claim in `CLAUDE.md`, `docs/MDT.md`, and `docs/SCRIPT_REFERENCE.md` against the actual code in `scripts/mdt/`. List every mismatch: parameters documented but absent from code, behaviors described differently than implemented, incorrect file paths, version numbers, or MDT cmdlet signatures.

### Agent 3: CI Simulation

Run every active Phase 1A check from `.github/workflows/ci.yml` locally (checks 3, 4, 5). Report PASS or FAIL for each with the exact grep output. Confirm checks 1, 2, and 7 are correctly skipped.

### Agent 4: MDT XML Correctness

Read `Initialize-MDTDeploymentShare.ps1`. Verify that `Set-UEFIPartitionScheme` and `Add-BitLockerTsStep` produce valid MDT `ts.xml` structures. Check:
- Variable node format matches MDT 8456's indexed scalar convention (`OSDPartitions0Type`, etc.)
- BitLocker step type attribute is correct for a Run Command Line step
- Condition expression format matches MDT's XML condition schema
- No array-node format (`OSDPartitions`) is introduced

## Phase 2: Fix

After all agents report back:

1. Compile findings into a single prioritized list (bugs first, then correctness, then doc drift)
2. Remove duplicates across agents
3. Discard style-only issues
4. Fix every real bug and correctness issue found
5. Update any stale docs
6. Run `pwsh -NoProfile -File ./tests/test_parse.ps1` after all changes to confirm syntax is clean
7. Summarize what was fixed and which agent found it
