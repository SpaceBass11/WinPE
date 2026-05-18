# Security Policy

## Scope

This project ships PowerShell scripts that configure MDT and build a
self-contained deployment ISO. Security issues in this codebase can
cause irreversible data loss on target machines, which makes responsible
disclosure important.

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

- MDT configuration or task-sequence logic that could cause unintended disk
  wipes or target the wrong machine
- Zero-touch config (`CustomSettings.ini`, `Bootstrap.ini`) settings that
  bypass safety checks in unexpected ways
- Path/parameter handling in the admin scripts that allows arbitrary command
  execution
- Third-party binary inclusion or `.gitignore` gaps that could result in
  inadvertent redistribution of vendor-licensed tools

Note: this branch does not include scripts that modify offline WIM images
or WinPE boot images directly.

## Out of Scope

- Issues that require already having Administrator access on the admin
  workstation (MDT itself is an administrator-only tool)
- Missing hardening for threats outside the tool's stated use case
  (e.g., not a forensics tool, not a secure erase tool)
- Third-party ADK or MDT components — report those to Microsoft

## Disclosure

After a fix ships, the advisory is published on the GitHub Security tab with
credit to the reporter (unless anonymity is requested).
