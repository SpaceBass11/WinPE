<!--
Thank you for contributing. Because this tool wipes disks, PRs that touch
deployment or safety logic require extra care. Please fill this out fully.
-->

## Summary

<!-- 1-3 sentences on what this PR does and why. -->

## Type of change

- [ ] Bug fix (non-breaking)
- [ ] New feature (non-breaking)
- [ ] Breaking change (behavior or CLI surface changes)
- [ ] Documentation only
- [ ] Build / CI / tooling

## Safety checklist

If this PR touches `unified_winpe_deploy.ps1`, `scripts/build_boot_wim.ps1`,
or the diskpart / DISM / BCDBoot path, confirm the following:

- [ ] The typed-confirmation chain (`ERASE`, `DESTROY SYSTEM`,
      `WIPE ALL`, `WIPE DATA`, `CONTINUE ANYWAY`) is preserved.
- [ ] `-Force` still does **not** bypass system-disk `DESTROY SYSTEM`.
- [ ] `-Silent` still fails fast when required inputs are missing.
- [ ] Drive-letter manipulation (`mountvol /d`) still refuses to unmount
      `$env:SystemDrive`.
- [ ] USB disks are still excluded from the target-disk list.
- [ ] `$Script:Config.ScriptVersion` and the `.VERSION` header are bumped
      together if this is a release-worthy change.

## Test plan

- [ ] `pwsh -NoProfile -File ./tests/test_parse.ps1` passes locally
- [ ] CI is green (syntax, PSSA, lychee, actionlint, masterize)
- [ ] Manually tested the affected code path in WinPE (describe below)

### Manual test notes

<!--
Describe the environment and exact command(s) you ran. E.g.:
"Built boot.wim with `build_boot_wim.ps1 -Clean -UsbDrive P:`, booted on
Dell Optiplex 7090 (UEFI), deployed Win11_Pro_24H2.wim to disk 0, verified
first boot succeeded."
-->

## Changelog

<!-- One line for CHANGELOG.md under [Unreleased]. Mark section: Added / Changed / Fixed / Removed. -->

## Related issues

<!-- Closes #123, refs #456 -->
