---
name: Bug report
about: Something went wrong during the gold-image build or after deployment
title: "[BUG] "
labels: bug
assignees: ''
---

## Summary
A short description of what's broken.

## Environment
- Which script and the commit SHA (e.g., `scripts/Enable-BitLocker.ps1 @ abc1234`):
- Reference / target hardware (make, model, BIOS version, TPM type):
- Windows build (Win11 24H2, etc.):
- Dell Command | Configure version (if CCTK related):
- Clonezilla Live version (if capture/restore related):

## When it happened
- [ ] During admin gold-image build (sysprep / capture)
- [ ] During operator deploy (Clonezilla restore)
- [ ] During SetupComplete post-deploy (Apply-DellConfig, Enable-BitLocker, Finalize-Cleanup)
- [ ] After deploy (BitLocker, BIOS state, recovery key missing)

## What happened
Actual behavior, including:
- The exit code (if a script exited)
- The last ~20 lines of relevant log output

## What I expected
Expected behavior.

## Logs
From `C:\ProgramData\ManualClonezilla\Logs\` on the deployed machine
(if applicable):

```
<paste log excerpt here>
```

For BitLocker reports, include:

```
manage-bde -status C:
manage-bde -protectors -get C:
```

## Reproduction
1.
2.
3.

## Additional context
Anything else.
