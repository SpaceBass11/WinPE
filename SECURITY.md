# Security Policy

## Scope

This project ships a PowerShell tool that **wipes and repartitions disks**
unattended inside a WinPE environment. Security issues in this codebase can
cause irreversible data loss, which makes responsible disclosure important.

## Supported Versions

| Version | Supported          |
|---------|--------------------|
| 4.4.x   | :white_check_mark: |
| < 4.4   | :x:                |

Only the latest minor release receives fixes. Earlier versions are archived
on Git tags for reference but are not patched.

## Reporting a Vulnerability

**Do not open a public GitHub issue for security reports.**

Please report security vulnerabilities through
[GitHub Security Advisories](https://github.com/spacebass11/WinPE/security/advisories/new).

When reporting, include:

- The exact version / commit SHA affected
- A minimal reproduction (command line, environment, sample image if relevant)
- The observed behavior (e.g., wrong disk selected, safety prompt bypassed,
  silent-mode contract broken, log redaction failure)
- The expected behavior
- Any mitigations you've already identified

You should get an initial acknowledgement within **72 hours**. A fix timeline
will be proposed once the scope is understood. Critical issues (arbitrary
disk wipe, silent-mode bypass, confirmation bypass) are prioritized.

## In Scope

- Bypasses of the typed-confirmation safety chain
  (`ERASE`, `DESTROY SYSTEM`, `CONTINUE ANYWAY`)
- `-Silent` / `-Force` contract violations that make the tool act without
  required inputs
- Disk-selection logic that could target a USB, system, or unintended disk
- Unsafe drive-letter handling that could unmount the running OS
- Registry tweaks in `scripts/build_boot_wim.ps1` that weaken the offline
  boot image
- Path/parameter handling that allows arbitrary command execution

## Out of Scope

- Issues that require already having Administrator + physical access
  (WinPE itself is inherently a privileged environment)
- Crashes in non-WinPE environments when the environment check is bypassed
  with `CONTINUE ANYWAY` — running outside WinPE is documented as unsupported
- Missing hardening for threats outside the tool's stated use case
  (e.g., not a forensics tool, not a secure erase tool)
- Third-party WinPE components shipped via the ADK — report those to Microsoft

## Disclosure

After a fix ships, the advisory is published on the GitHub Security tab with
credit to the reporter (unless anonymity is requested).
