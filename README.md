# Manual Clonezilla — Self-Deploying Windows 11 ISO

[![CI](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml/badge.svg)](https://github.com/spacebass11/WinPE/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Admin builds one golden image. Operator downloads ISO, flashes a USB with
Rufus, boots the laptop, walks away.**

Offline, unmanaged Windows 11 reimaging for small homogeneous fleets where
every machine wants the same OS, the same accounts, the same BIOS posture,
and the same BitLocker policy.

```
Admin workstation (one-time per release)
  |
  +-- Build golden Windows 11 install on reference VM/hardware
  +-- Stage post-deploy scripts + dell-config.cctk + bitlocker-pin.txt
  +-- sysprep /generalize /oobe /shutdown
  +-- Capture disk with Clonezilla Live
  +-- Generate self-restoring Clonezilla ISO
                                         |
Operator: download ISO --> Rufus --> USB --> boot target --> walk away
                                                              |
On first boot, SetupComplete.cmd runs in order:
  1. Apply-DellConfig.ps1      -- cctk --import dell-config.cctk
  2. Scrub-AuditArtifacts.ps1  -- clear autologon + Panther unattend secrets
  3. New-LocalAccounts.ps1     -- Level 0-3 + IT_Admin from accounts.csv
  4. Set-Level0ACL.ps1         -- lock Level 0 out of restricted folders
  5. Disable-RDP.ps1           -- fail-safe RDP off
  6. Harden-Administrator.ps1  -- STIG: disable/rotate/rename built-in admin
  7. Apply-StigHardening.ps1   -- Guest, password/lockout, UAC, firewall, banner
  8. Enable-BitLocker.ps1      -- TPM+PIN protector + recovery key export
  9. Install-NotepadPP.ps1     -- silent install (non-fatal)
 10. Finalize-Cleanup.ps1      -- deletes one-time secrets from disk
```

---

## Who this is for

Use this if:

- You deploy **the same image** to **the same hardware** with **the same
  policy** every time.
- You want **zero network dependency at deploy time** (no MDT server,
  no PXE, no MDM, no AD).
- You're OK with **one BitLocker PIN across the fleet** as an accepted
  risk (the [BitLocker PIN trust model](#bitlocker-pin-trust-model) below
  spells it out).
- Your operators can run Rufus but not much else.

Don't use this if:

- You need **per-machine variation** (different PIN, different image,
  different accounts) — you want the WinPE workflow from `main` instead.
- You have **AD / MDM / Intune** infrastructure and want keys escrowed there.
- You deploy to **mixed hardware models** that need different driver sets
  or different BIOS config packages.

---

## Quick start (admin)

1. Read [docs/RUNBOOK.md](docs/RUNBOOK.md) end-to-end before the first
   build. It is the source of truth for the build process.
2. Stage these files in `C:\ProgramData\ManualClonezilla\` on your
   reference machine before sysprep (build it in **audit mode** under the
   built-in Administrator):
   - `Scripts\SetupComplete.cmd` (also copied to `C:\Windows\Setup\Scripts\`)
   - `Scripts\Common.ps1` (shared helpers; dot-sourced by the others)
   - `Scripts\` -- all nine PS1s (Apply-DellConfig, Scrub-AuditArtifacts,
     New-LocalAccounts, Set-Level0ACL, Disable-RDP, Harden-Administrator,
     Apply-StigHardening, Enable-BitLocker, Install-NotepadPP, Finalize-Cleanup)
   - `Config\dell-config.cctk`
   - `Config\bitlocker-pin.txt` (one line, the BitLocker PIN)
   - `Config\accounts.csv` (named accounts; see `configs/accounts.example.csv`)
   - `Installers\npp-installer.exe` (Notepad++ silent installer)
3. Sysprep + Clonezilla capture + ISO generation per the runbook.

---

## Quick start (operator)

1. Download the ISO from your administrator's link.
2. Open Rufus → select the ISO → select the USB → click Start. Choose
   **DD mode** if Rufus prompts.
3. Boot the target laptop from the USB (typically F12 → "UEFI: USB …").
4. Walk away. The machine restores the image, boots into Windows,
   runs the post-deploy scripts, and reboots to the login screen.

See [docs/USB_SETUP.md](docs/USB_SETUP.md) for the operator's full SOP.

---

## What's in the repo

```
.
├── scripts/
│   ├── SetupComplete.cmd        Orchestrator. Auto-runs after first OOBE pass.
│   ├── Common.ps1               Shared helper functions (dot-sourced).
│   ├── Apply-DellConfig.ps1     Imports the Dell CCTK BIOS config package.
│   ├── Scrub-AuditArtifacts.ps1 Clears autologon + Panther unattend secrets.
│   ├── New-LocalAccounts.ps1    Creates Level 0-3 + IT_Admin from accounts.csv.
│   ├── Set-Level0ACL.ps1        Deny ACLs locking Level 0 out of folders.
│   ├── Disable-RDP.ps1          Fail-safe RDP disable.
│   ├── Harden-Administrator.ps1 STIG disable/rotate/rename of built-in admin.
│   ├── Apply-StigHardening.ps1  Guest, password/lockout, UAC, firewall, banner.
│   ├── Enable-BitLocker.ps1     TPM+PIN on C:, exports recovery key locally.
│   ├── Install-NotepadPP.ps1    Silent Notepad++ install (non-fatal).
│   └── Finalize-Cleanup.ps1     Removes one-time secrets from disk.
├── configs/
│   ├── unattend.example.xml     Skeleton unattend.xml for the golden image.
│   └── accounts.example.csv     Template for the staged accounts.csv.
├── docs/
│   ├── RUNBOOK.md               End-to-end admin build + release process.
│   ├── OPERATIONS.md            Day-2 ops, rotation, rollback, triage.
│   ├── USB_SETUP.md             Operator USB creation + boot SOP.
│   ├── UNATTEND.md              unattend.xml reference.
│   ├── CCTK.md                  Dell CCTK details.
│   ├── ARCHITECTURE.md          Design rationale and data flow.
│   └── TROUBLESHOOTING.md       Common deploy-time failures.
├── tests/
│   └── Common.Tests.ps1         Pester unit tests for the shared helpers.
├── CHANGELOG.md
├── CLAUDE.md                    Internal AI-coding guidance.
└── README.md                    (this file)
```

---

## BitLocker PIN trust model

**The PIN file `Config\bitlocker-pin.txt` is baked into the captured
Clonezilla image.** Anyone with read access to the ISO can recover the
PIN. This is intentional for this workflow's target audience:

| Threat | Outcome |
|---|---|
| Attacker steals a deployed laptop | TPM+PIN unaffected by knowing the PIN — they still need the device, and PowerOn POST is what challenges the PIN. The PIN's role is anti-DMA / anti-cold-boot, not anti-skilled-attacker. |
| Attacker steals the deployment ISO | Reads PIN, but still needs physical access to a target laptop. Treat the ISO as sensitive media; rotate per `docs/OPERATIONS.md`. |
| Attacker compromises one laptop's PIN | Same PIN is on every laptop in the fleet (accepted risk). If this matters for your environment, **do not use this workflow** — use the per-USB PIN model on the `main` branch. |

`Finalize-Cleanup.ps1` deletes `bitlocker-pin.txt` from the deployed
machine after `Enable-BitLocker.ps1` completes, so the deployed
endpoint itself does not carry the file post-OOBE.

---

## Recovery key handling

`Enable-BitLocker.ps1` writes the recovery key to
`C:\ProgramData\BitLockers\BitLocker-RecoveryKey-<hostname>-<timestamp>.txt`
on the deployed machine. It is **not** uploaded anywhere automatically.
The folder is ACL-locked to SYSTEM + Administrators, so a standard user
(`Level 0`-`Level 3`) cannot read it; collect it as `IT_Admin`.

The operator's SOP (your responsibility to define) must include
collecting this file off-machine before handing the laptop to the user.
A USB key, a network share copy, a printed slip — anything. The repo
does not assume a destination.

If you have AD or MDM, replace `Export-RecoveryKey` in
`Enable-BitLocker.ps1` with `manage-bde -protectors -adbackup` or your
MDM's escrow API call instead.

---

## Account password trust model

The named accounts (`Level 0`-`Level 3`, `IT_Admin`) are created at first
boot from `Config\accounts.csv`, which holds **plaintext passwords** baked
into the captured image -- the same accepted-risk trust model as the
BitLocker PIN file. `Finalize-Cleanup.ps1` deletes `accounts.csv` after the
accounts are created, so the deployed endpoint does not retain it.

Two consequences to accept (or change before you ship):

- **`IT_Admin` is the same password fleet-wide.** A single compromised
  laptop yields local-admin credentials valid on every identical machine.
  This is deliberate (matches the same-PIN-fleet-wide posture); if your
  threat model can't accept it, rotate `IT_Admin` per machine and escrow
  it the way the recovery key is handled.
- **Role accounts never expire.** They are created `PasswordNeverExpires`
  so a static fleet image doesn't lock its users out on a timer. This is an
  intentional deviation from the password-age policy that
  `Apply-StigHardening.ps1` otherwise enforces; a STIG scanner will flag it.

---

## Design constraints (intentional non-goals)

- **Dell-only BIOS automation.** `Apply-DellConfig.ps1` hard-fails on
  non-Dell hardware. Other vendors require a different post-deploy step.
- **No driver injection** — drivers live in the golden image. New
  hardware family → new image.
- **No per-machine variation** — every machine gets a random computer name
  (Windows default; `ComputerName` is not set in unattend) and the same PIN
  and same accounts. Accounts are provisioned at first boot by
  `New-LocalAccounts.ps1`, not by the answer file. If you need variation,
  this is the wrong tool.
- **No update or patch automation** post-deploy. Patch the golden image
  and re-cut the ISO.

---

## License

[MIT](LICENSE)
