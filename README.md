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
  1. Apply-DellConfig.ps1     -- cctk --import dell-config.cctk
  2. Enable-BitLocker.ps1     -- TPM+PIN protector + recovery key export
  3. Finalize-Cleanup.ps1     -- deletes one-time secrets from disk
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
   reference machine before sysprep:
   - `Scripts\SetupComplete.cmd` (also copied to `C:\Windows\Setup\Scripts\`)
   - `Scripts\Apply-DellConfig.ps1`
   - `Scripts\Enable-BitLocker.ps1`
   - `Scripts\Finalize-Cleanup.ps1`
   - `Config\dell-config.cctk`
   - `Config\bitlocker-pin.txt` (one line, the BitLocker PIN)
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
│   ├── Apply-DellConfig.ps1     Imports the Dell CCTK BIOS config package.
│   ├── Enable-BitLocker.ps1     TPM+PIN on C:, exports recovery key locally.
│   └── Finalize-Cleanup.ps1     Removes one-time secrets from disk.
├── configs/
│   └── unattend.example.xml     Skeleton unattend.xml for the golden image.
├── docs/
│   ├── RUNBOOK.md               End-to-end admin build + release process.
│   ├── OPERATIONS.md            Day-2 ops, rotation, rollback, triage.
│   ├── USB_SETUP.md             Operator USB creation + boot SOP.
│   ├── UNATTEND.md              unattend.xml reference.
│   ├── CCTK.md                  Dell CCTK details.
│   ├── ARCHITECTURE.md          Design rationale and data flow.
│   └── TROUBLESHOOTING.md       Common deploy-time failures.
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

The operator's SOP (your responsibility to define) must include
collecting this file off-machine before handing the laptop to the user.
A USB key, a network share copy, a printed slip — anything. The repo
does not assume a destination.

If you have AD or MDM, replace `Export-RecoveryKey` in
`Enable-BitLocker.ps1` with `manage-bde -protectors -adbackup` or your
MDM's escrow API call instead.

---

## Design constraints (intentional non-goals)

- **Dell-only BIOS automation.** `Apply-DellConfig.ps1` hard-fails on
  non-Dell hardware. Other vendors require a different post-deploy step.
- **No driver injection** — drivers live in the golden image. New
  hardware family → new image.
- **No per-machine variation** — every machine gets the same name pattern
  (random via `ComputerName=*` in unattend), same PIN, same accounts.
  If you need variation, this is the wrong tool.
- **No update or patch automation** post-deploy. Patch the golden image
  and re-cut the ISO.

---

## License

[MIT](LICENSE)
