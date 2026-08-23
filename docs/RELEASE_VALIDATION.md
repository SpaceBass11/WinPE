# Release Validation Checklist

Manual pre-distribution checklist for the WinPE deployment tool. CI
catches syntax and doc drift; this catches the rest.

> [!IMPORTANT]
> **CI passing does not prove WinPE or hardware behavior.** CI verifies
> PowerShell syntax, doc-code consistency, and static-analysis greps
> against `unified_winpe_deploy.ps1`. It does *not* exercise real
> diskpart, real DISM apply, real CCTK BIOS writes, real TPM+PIN
> escrow, real UEFI boot, or real first-boot `SetupComplete.cmd`
> execution. Treat a green CI as necessary but not sufficient.

## When to run

This checklist is a **distribution gate, not a merge gate.** `main`
may carry unvalidated WIP — that's fine for a solo-maintained public
repo. The contract is with the build, not the branch.

Run before:

- **Tagging a release** intended for distribution
- **Flashing a build onto an operator USB** destined for the field
- **Running a build on a real laptop you care about** (yours or a
  customer's)
- **Any change to** diskpart / BCDBoot / DISM / CCTK / BitLocker /
  deploy.args / unattend code paths
- **Any change to** `scripts/build_boot_wim.ps1` (it gates everything
  downstream — a broken `boot.wim` invalidates every other test)

## Environments

| Env | Use | Notes |
|-----|-----|-------|
| Hyper-V Gen2 VM | Disk-layout, unattend, deploy.args, BitLocker (with vTPM) | UEFI; enable **virtual TPM** in VM settings to exercise `Enable-BitLocker`. Free, fast iteration. |
| Dell physical hardware (one model) | CCTK + real TPM + real BIOS write + real UEFI boot | Required for authoritative validation. CCTK cannot be tested in Hyper-V. |

You don't need every environment for every change. Pick the smallest
matrix that exercises what changed — see [When to run](#when-to-run)
above.

## Scenario matrix

Each row's **Pass criteria** is observable behavior (log presence,
file presence, boot result) — not exact-string log assertions, which
can drift as logging gets refined.

### Disk layout

| # | Scenario | Setup | Expected | Pass criteria |
|---|----------|-------|----------|---------------|
| 1 | Hyper-V single-disk | One virtual disk, no `-WipeDisks` | Clean GPT layout, EFI + MSR + NTFS, OOBE reaches first boot | Diskpart succeeds; S: and C: exist post-partition; UEFI boots from internal disk into Windows |
| 2 | Hyper-V multi-disk | Two+ virtual disks, `-WipeDisks "1"` (or interactive selection) | Primary disk partitioned; extra disk(s) cleaned (not partitioned) | Diskpart log shows `clean` on extra disks but no `create partition` for them; deploy completes |
| 3 | Dell physical single-disk | Real Dell, one NVMe/SSD | Same as #1 plus real UEFI firmware boot path | Machine boots into Windows from internal disk without USB present |
| 4 | Dell physical dual-disk | Real Dell, two internal disks, `-DataDiskNumber 1` | Primary partitioned for Windows; second disk wiped + formatted NTFS as `D:` | `D:` appears in Windows post-boot, NTFS, empty |

### CCTK (Dell BIOS pre-apply)

| # | Scenario | Setup | Expected | Pass criteria |
|---|----------|-------|----------|---------------|
| 5 | CCTK absent | `boot.wim` built without `-CctkSource` (no `X:\cctk\cctk.exe`) | **No BIOS config attempted, no abort, deploy continues normally** | Deploy completes; no BIOS change made; no abort. (The script silently skips this path — `Invoke-CctkConfig` returns early when `cctk.exe` is missing.) |
| 6 | CCTK present + valid config | `boot.wim` built with `-CctkSource`; matching config file under `<IMAGES>\cctk\` | `cctk --infile=` runs, exits 0, BIOS setting applied | Deploy log shows the CCTK invocation; on real Dell hardware, BIOS reflects the change post-reboot (e.g. RAID→AHCI) |

Edge cases worth noting but not separate matrix rows (the script
handles all four gracefully — verify behavior by inspecting the log):

- CCTK embedded but `DEPLOY_IMAGE_DRIVE` unset → warning + skip
- CCTK embedded but no `<IMAGES>\cctk\` directory → info-level log + skip
- `<IMAGES>\cctk\` present but no matching `<SERVICETAG>.ini`,
  `<MODEL>.ini`, or `default.ini` → info-level log + skip (operator
  set up the directory but forgot a catch-all; deploy continues)
- CCTK runs but exits non-zero → deploy aborts (loud failure)

### Unattend

| # | Scenario | Setup | Expected | Pass criteria |
|---|----------|-------|----------|---------------|
| 7 | Malformed XML (not well-formed) | `-UnattendFile` points at a file with broken XML (missing tag, bad encoding) | Script fails fast at the `[xml](Get-Content ...)` validation **before disk selection, diskpart, or image apply** | Deploy exits non-zero with an XML parse error in the log; no `clean` issued; no DISM invoked; target disk untouched |
| 8 | Schema-valid but Windows-Setup-invalid | XML parses fine but contains invalid `<unattend>` directives (bad `<settings pass="...">`, unknown component) | Script accepts the file (well-formedness check passes), copies to `C:\Windows\Panther\unattend.xml`; **Windows Setup** may log errors and fall through to manual OOBE | Deploy completes; first boot reaches OOBE prompts (or falls through to manual setup) rather than silent autologon. Windows Setup's own `C:\Windows\Panther\setupact.log` will show the schema rejections. |

### Multi-index WIM with -Silent

| # | Scenario | Setup | Expected | Pass criteria |
|---|----------|-------|----------|---------------|
| 9 | Multi-index WIM in silent mode | `-WimFile` points at a WIM with 2+ indexes; `-Silent -Force -TargetDisk N` | Silent-mode validation rejects this fail-fast — silent mode can't prompt for index selection | Deploy exits non-zero before any disk touch; log explains the multi-index restriction |

### BitLocker

| # | Scenario | Setup | Expected | Pass criteria |
|---|----------|-------|----------|---------------|
| 10 | BitLocker disabled (default) | No `-EnableBitLocker` | No first-boot BitLocker staging | `C:\Windows\Setup\Scripts\bitlocker-setup.ps1` and `SetupComplete.cmd` absent after deploy |
| 11 | TUI PIN prompt (non-silent) | `-EnableBitLocker` only (no `-BitLockerPin`), no `-Silent`; script prompts via `Read-Host` at the WinPE console | Operator types PIN at keyboard at deploy time; PIN is visible on screen (so operator can verify the typed value) | Deploy log shows `"prompting at WinPE console"`, then escrow path + source; first-boot log shows recovery key saved; recovery key file exists at the chosen path; staged scripts self-delete; machine reboots cleanly into encrypted OS. Verify: re-run silent (`-Silent -Force`) with the same missing-PIN combo and confirm it hard-fails instead of prompting |
| 12 | Pre-staged PIN (air-gapped operator USB) | `-EnableBitLocker -BitLockerPin '<test-pin>' -Force -Silent` via `deploy.args` | Fully unattended; PIN comes from USB | Same observable conditions as #11; see [Air-gapped operator USB](#air-gapped-operator-usb--advanced) below for the security trade-off |

For all BitLocker scenarios, the four observables are:

1. Deploy log line: `"BitLocker recovery key escrow: <path> (<source>)"`
   — confirms which escrow path was chosen (parameter override,
   IMAGES partition, or fallback)
2. First-boot `C:\Windows\Setup\Scripts\bitlocker-setup.log`: shows the
   recovery key was saved to a real directory
3. Recovery key file: a `.txt` file actually exists in the escrow
   directory after first boot
4. Self-cleanup: `bitlocker-setup.ps1` and `SetupComplete.cmd` are
   gone from `C:\Windows\Setup\Scripts\` after the run

### deploy.args

| # | Scenario | Setup | Expected | Pass criteria |
|---|----------|-------|----------|---------------|
| 13 | `deploy.args` missing | No file at `<IMAGES>\deploy.args` | `startnet.cmd` launches script with no args; interactive TUI | TUI prompts appear for image / disk / confirmations |
| 14 | `deploy.args` present, well-formed | One-line args file with valid params | `startnet.cmd` reads it, passes params, script runs unattended | Deploy completes with no prompts |
| 15 | `deploy.args` malformed | Bad PowerShell args (typo'd parameter, unclosed quote, invalid type) | `startnet.cmd` passes args verbatim; PowerShell parameter-binding fails loudly before any destructive work | Deploy exits before disk touch; the WinPE console shows the PowerShell binding error |

## Air-gapped operator USB — advanced

The real deployment model for many users of this tool is offline,
non-endpoint-managed, non-IT operator USB sticks: flash, hand to a
field operator, they boot a laptop, the deploy runs unattended. This
section documents that workflow and its security trade-offs so the
release validation matrix exercises both paths.

> [!CAUTION]
> Pre-staged PIN means the BitLocker startup PIN sits in plaintext on
> the USB inside `deploy.args` until the deploy runs. This is a real
> trade-off — not a bug — and it's the same trust model as CCTK
> passwords on the IMAGES partition.

**Both PIN models are supported. Pick per threat model:**

| Mode | Use when | Trade-off |
|------|----------|-----------|
| **TUI PIN prompt** (`-EnableBitLocker` without `-BitLockerPin`, non-silent) | Manual-technician workflows. The script prompts via `Read-Host`; PIN is visible on screen so the operator can verify their typing. | Requires an operator who knows the PIN and is physically present. Not suitable for hand-off to a non-IT field operator. PIN is also plaintext in the staged `bitlocker-setup.ps1` on `C:` until first-boot self-cleanup — hiding at the prompt would not change that. |
| **Pre-staged PIN** (`-BitLockerPin '...'` in `deploy.args`, plus `-Force -Silent`) | Offline, non-endpoint-managed, non-IT operator workflows. The USB *is* the credential. | Plaintext PIN on removable media until first boot. The USB/ISO must be treated as a credential — physical custody is the only protection. |

**Hardening recommendations for the pre-staged path:**

- **Treat the USB and its ISO source as credentials.** Physical
  custody and inventory are the only controls. If a USB is lost,
  rotate the PIN on the next batch.
- **Unique PIN per deployment batch where practical.** Don't ship a
  single PIN across every USB in the field. Even per-batch rotation
  meaningfully limits blast radius if one USB is compromised.
- **Don't reuse PINs from production systems.** The PIN on the USB
  is the PIN that gets baked into the deployed machine — anyone with
  the USB can boot the machine they deployed.
- **Recovery keys still escrow off-volume by default** (to the IMAGES
  partition by volume-label lookup, or to a UNC share via
  `-BitLockerKeyPath`). The USB stays plugged in through first boot
  when default escrow is used; see
  [BITLOCKER.md](BITLOCKER.md#recovery-key-escrow).

When running release validation, exercise both #11 (TUI PIN prompt)
and #12 (pre-staged PIN) so both supported credential paths stay
covered as the code evolves.

## Recording results

Copy this block into the PR description, release notes, or your own
release log when you run the matrix. It's not stored in the repo.

```text
## Release Validation: vX.Y.Z

Environment(s) exercised:
- [ ] Hyper-V Gen2 (UEFI, vTPM on / off)
- [ ] Dell physical: <model> / <BIOS rev>

Matrix:
- [ ] 1.  Hyper-V single-disk
- [ ] 2.  Hyper-V multi-disk (-WipeDisks)
- [ ] 3.  Dell single-disk
- [ ] 4.  Dell dual-disk (-DataDiskNumber)
- [ ] 5.  CCTK absent (no abort, deploy continues)
- [ ] 6.  CCTK present + valid config
- [ ] 7.  Malformed unattend XML (fails fast, no disk touch)
- [ ] 8.  Schema-valid unattend (stages; first-boot behavior verified)
- [ ] 9.  Multi-index WIM + -Silent (fails fast)
- [ ] 10. BitLocker disabled (no staged scripts left)
- [ ] 11. BitLocker + TUI PIN prompt (non-silent)
- [ ] 12. BitLocker + pre-staged PIN (air-gapped operator path)
- [ ] 13. deploy.args missing (TUI)
- [ ] 14. deploy.args present (unattended)
- [ ] 15. deploy.args malformed (loud failure, no disk touch)

Notes / regressions found:
-

Sign-off: <name>, <date>
```

## Known limitations of this checklist

- **Hyper-V can't validate CCTK.** CCTK requires real Dell hardware.
  Scenarios 5 and 6 must be exercised on a physical Dell.
- **No-vTPM Hyper-V can't validate BitLocker.** `Enable-BitLocker
  -TpmAndPinProtector` requires a TPM. Enable virtual TPM in the
  VM's Security settings or skip the BitLocker rows on that env.
- **Long-tail failures aren't reproducible in one pass.** Drive-letter
  reassignment under load, TPM-reset recovery flows, firmware updates
  changing the boot path — these require field observation, not
  pre-release testing. Document any field findings in
  [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Related docs

- [BITLOCKER.md](BITLOCKER.md) — BitLocker design, escrow precedence,
  the v4.7.1 label-lookup behavior
- [CCTK.md](CCTK.md) — CCTK setup, config precedence, exit codes
- [DEPLOY_ARGS.md](DEPLOY_ARGS.md) — `deploy.args` format and
  precedence rules
- [UNATTEND.md](UNATTEND.md) — unattend.xml authoring and sanity checks
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — reactive debugging when
  validation fails
- [SCRIPT_REFERENCE.md](SCRIPT_REFERENCE.md) — full parameter and
  function reference
