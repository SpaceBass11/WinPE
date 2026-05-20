# Security Policy

## Scope

This project ships PowerShell scripts and documentation for building a
self-deploying Clonezilla ISO that restores a golden Windows 11 image
and runs first-boot automation (Dell BIOS config + BitLocker TPM+PIN
enable + cleanup). Security issues here can cause data loss on target
machines or leak BitLocker PINs / BIOS passwords baked into the ISO,
which makes responsible disclosure important.

## Reporting a Vulnerability

**Do not open a public GitHub issue for security reports.**

Please report security vulnerabilities through
[GitHub Security Advisories](https://github.com/spacebass11/WinPE/security/advisories/new).

When reporting, include:

- The exact commit SHA affected
- A minimal reproduction (golden-image steps, captured ISO context if
  relevant)
- The observed behavior (e.g. BitLocker enables without a recovery
  protector, PIN file leaks past cleanup, recovery key written to the
  wrong location, CCTK silently succeeds with a bad config)
- The expected behavior
- Any mitigations you've already identified

You should get an initial acknowledgement within **72 hours**. A fix
timeline will be proposed once the scope is understood. Critical
issues (BitLocker enables without recovery, secrets leak past cleanup)
are prioritized.

## In Scope

- BitLocker enablement logic that could leave a volume encrypted with
  no recovery protector
- Cleanup logic gaps that leave the PIN file, recovery key, or BIOS
  config package on the deployed machine when they should be removed
- Idempotency or staging-path errors that cause `SetupComplete.cmd` to
  succeed silently when it should fail
- `.gitignore` gaps or doc patterns that could result in inadvertent
  commit of vendor-licensed CCTK binaries

## Accepted Risk (Not Vulnerabilities)

The following are documented design decisions and accepted risks; do
**not** report them as vulnerabilities:

- **Same BitLocker PIN across the fleet.** The PIN file is baked into
  the captured Clonezilla image. See the [BitLocker PIN trust
  model](README.md#bitlocker-pin-trust-model) in the README.
- **CCTK BIOS passwords plaintext in the ISO.** See [docs/CCTK.md](docs/CCTK.md).
- **Recovery keys are local-only.** This is an offline, unmanaged
  workflow; keys land on the deployed machine for operator pickup
  rather than being escrowed to AD/MDM.

## Out of Scope

- Issues that require already having Administrator access on the gold
  reference machine (image building is an admin-only operation)
- Threats outside the tool's stated use case (not a forensics tool,
  not a secure-erase tool, not a per-machine deployment tool)
- Third-party Clonezilla / Dell DCC / Windows components -- report
  those upstream

## Disclosure

After a fix ships, the advisory is published on the GitHub Security tab
with credit to the reporter (unless anonymity is requested).
