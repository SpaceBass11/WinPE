---
name: Feature request
about: Suggest an enhancement to the deploy script or the boot.wim builder
title: "[FEATURE] "
labels: enhancement
assignees: ''
---

## Problem
What's the current pain point? (e.g., "silent mode can't handle multi-index
images", "builder doesn't support BitLocker pre-provisioning")

## Proposed solution
What you'd like to happen. If it's a CLI change, sketch the parameter
signature.

## Safety considerations
This tool wipes disks unattended. If your proposal changes confirmation
prompts, `-Silent` / `-Force` behavior, or disk selection, please explain
how you'd preserve the safety chain (`ERASE`, `DESTROY SYSTEM`,
`CONTINUE ANYWAY`).

## Alternatives considered
Other approaches you ruled out, and why.

## WinPE compatibility
Does this require modules or binaries that aren't in a stock ADK WinPE
build? If so, please note how they'd be added to `scripts/build_boot_wim.ps1`.

## Additional context
Mockups, log excerpts, links to related issues.
