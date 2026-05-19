Run a comprehensive review of all scripts in scripts/mdt/. Check ALL of the following:

## 1. PowerShell Syntax

Run `pwsh -NoProfile -File ./tests/test_parse.ps1` and confirm it passes for all four scripts (Initialize-MDTDeploymentShare.ps1, Import-WimImages.ps1, New-MDTMedia.ps1, Enable-BitLocker.ps1). Also confirm that test_parse.ps1 covers Start-MDT.ps1 (the interactive launcher at the repo root) — it should appear in the file list parsed by the test script.

## 2. MDT Cmdlet Accuracy

- Confirm `Import-MDTOperatingSystem` is called with `-SourceFile` (not `-SourcePath`) when importing a single WIM
- Confirm `Import-MDTTaskSequence` parameters match what MDT 8456 accepts
- Confirm `New-Item` is used to create the media object (not a dedicated MDT cmdlet)
- Confirm `Update-MDTMedia` is called with the correct deployment share path

## 3. Set-UEFIPartitionScheme

- Confirm it patches individual indexed `<variable>` nodes (`OSDPartitions0Type`, `OSDPartitions0Size`, `OSDPartitions0FileSystem`, `OSDPartitions0Bootable`, `OSDPartitions1Type`, `OSDPartitions1Size`) in `ts.xml`
- Confirm it does NOT look for or write an `OSDPartitions` array node
- Confirm each partition property is a separate `<variable>` node, not a blob

## 4. Add-BitLockerTsStep

- Confirm the injected step targets the State Restore group in `ts.xml`
- Confirm the step has a condition checking `BDEPin notEquals ""`
- Confirm the step references `%SCRIPTROOT%\Enable-BitLocker.ps1`

## 5. Win11 ADK Fixes

- Confirm `Invoke-MDTWin11AdkFixes` applies all three fixes:
  1. Creates the x86 WinPE placeholder folder
  2. Patches the WSIM path in `DeploymentTools.xml` to the amd64 binary
  3. Sets `SupportX86=False` in the deployment share
- Confirm the function is called at both required call sites: before share creation and after

## 6. CustomSettings.ini

- Confirm `SkipFinalSummary=YES` is present
- Confirm `SkipSummary=YES` is present alongside it
- Confirm `BDEPin=` is present (triggers BitLocker PIN prompt)
- Confirm `FinishAction=REBOOT` is present

## 7. Bootstrap.ini

- Confirm `DeployRoot=.` is present (standalone USB mode — no UNC path)

## 8. Enable-BitLocker.ps1

- Confirm recovery keys are saved BEFORE data drives are encrypted (not after)
- Confirm enhanced PIN policy is configured
- Confirm auto-unlock is enabled for data drives
- Confirm an empty `$Pin` value causes a clean exit, not an error

## 9. CI Masterize Checks (Phase 1A)

Run each active grep from `.github/workflows/ci.yml` locally and report PASS or FAIL:

- Check 3: No stray `E:\images` references in docs/ and scripts/
- Check 4: Volume labels are only `IMAGES`, `WinPE`, or `Windows`
- Check 5: Three-programs diagram in `docs/ARCHITECTURE.md` covers `driver`, `unattend`, `cctk`
- Checks 1, 2, 7: Confirm these are skipped (they referenced WinPE scripts not present on this branch)

## 10. CLAUDE.md Accuracy

Confirm these key facts in CLAUDE.md match the actual code:

- `Set-UEFIPartitionScheme` patches individual indexed `<variable>` nodes (not a blob)
- `SkipFinalSummary=YES` is required and present in `CustomSettings.ini`
- `Invoke-MDTWin11AdkFixes` applies all three Win11 ADK fixes

Report findings as: PASS, WARN, or FAIL for each item with details.
