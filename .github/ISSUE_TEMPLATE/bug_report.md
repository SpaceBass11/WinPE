---
name: Bug report
about: Something went wrong during build or deployment
title: "[BUG] "
labels: bug
assignees: ''
---

## Summary
A short description of what's broken.

## Environment
- Tool version (from `$Script:Config.ScriptVersion` or the header in
  `unified_winpe_deploy.ps1`):
- WinPE architecture (amd64 / x86 / arm64):
- ADK version (if using `scripts/build_boot_wim.ps1`):
- Target hardware (make / model, BIOS or UEFI, Secure Boot on/off):
- Source image (Win10 / Win11 / Server build, Pro / Ent, captured or MS original):

## How it was invoked
```powershell
# The exact command line, including all parameters
```

## What happened
Actual behavior, including:
- The exit code (if the script exited)
- The last ~20 lines of console output
- The dism exit code, if DISM failed

## What I expected
Expected behavior.

## Logs
Paste the tail of the deploy log (`deploy_YYYYMMDD_HHMMSS.log` in the temp
directory, typically `X:\Windows\Temp` in WinPE). If DISM failed, also
attach the relevant portion of `X:\Windows\Logs\DISM\dism.log`.

```
<paste log excerpt here>
```

## Reproduction
1.
2.
3.

## Additional context
Anything else — Storage Spaces setup, SED drives, unusual controllers,
dual-boot configurations, etc.
