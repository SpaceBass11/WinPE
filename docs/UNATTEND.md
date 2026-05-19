# Unattend.xml Answer File

Windows Setup reads `unattend.xml` on first boot to skip OOBE prompts, create
the deployment account, set computer name and time zone, configure AutoLogon,
and run first-boot scripts. MDT links the file to the task sequence and stages
it automatically.

---

## MDT Method

Two ways to attach an unattend.xml to an MDT task sequence:

### Option A — MDT Workbench GUI

1. Open MDT Workbench and expand **Task Sequences**.
2. Right-click your task sequence → **Properties** → **OS Info** tab.
3. Click **Edit Unattend.xml** — this opens Windows System Image Manager (SIM).
4. In SIM, import `configs/unattend.example.xml` (File → Open Answer File),
   adjust TimeZone / ComputerName as needed, and save. MDT records the path.
5. Run **Update Deployment Share** to rebuild the boot media.

MDT stages the linked unattend.xml to `C:\Windows\Panther\unattend.xml`
automatically during the Apply OS step.

> **No Windows SIM?** Use Option B — SIM is only required for the GUI workflow.

### Option B — File-drop method

1. Copy and edit the template (see [Template](#template) below).
2. Save the finished file to:
   ```
   DeploymentShare\Control\<TaskSequenceID>\unattend.xml
   ```
3. Run **Update Deployment Share**. MDT auto-discovers any `unattend.xml`
   placed here and uses it for that task sequence — no Workbench GUI needed.

---

## WinPE Tool Method

The WinPE deploy script (`unified_winpe_deploy.ps1`) and its `-UnattendFile` parameter live on the `main` branch of this repo — see the main branch docs for that workflow.

---

## Template

Start from [`configs/unattend.example.xml`](../configs/unattend.example.xml).
Never edit it in place — keep the example clean for future reference.

### What to change

| Field | Default | Notes |
|---|---|---|
| `<ComputerName>` | `*` | `*` = random name. `%SerialNumber%` = service tag. Fixed string = same name on every machine (test only). |
| `<TimeZone>` | `Coordinated Universal Time` | Run `tzutil /l` on any Windows box to list valid names. |

That's it. No passwords to encode — `LocalAdmin` is created with no password
intentionally (deployment-only account). Set a password or disable it
post-deploy per your hardening baseline.

### Accounts and passwords

The template creates one account (`LocalAdmin`, no password) for the sole
purpose of giving MDT's `LTIBootstrap.vbs` a session to run under.

All other accounts (tech tiers, end-user accounts) belong in the MDT task
sequence — State Restore group, `net user` / PowerShell steps. Passwords
for those accounts can be stored as variables in `CustomSettings.ini` and
passed as MDT task sequence variables, keeping them out of the XML entirely.

The built-in Administrator account is disabled automatically by a State Restore
step injected by `Initialize-MDTDeploymentShare.ps1` (`net user Administrator
/active:no`). It runs last in State Restore so it is available for the full
task sequence and then locked down per STIG without any manual step.

---

## Passes

The template uses two Windows Setup passes:

**`specialize`** — runs after the OS is laid down (and after any Sysprep
generalize pass), before the first user login. This is where `ComputerName`
and `TimeZone` are set. These settings require a sysprepped (generalized) WIM;
if you captured an already-configured machine without running
`sysprep /generalize`, the specialize pass never fires.

**`oobeSystem`** — runs during OOBE on first boot. This is where locale,
account creation, AutoLogon, and FirstLogonCommands are processed. These
settings apply regardless of whether the WIM was sysprepped.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Lock screen at first boot instead of AutoLogon | AutoLogon block missing or `LocalAdmin` account not created | Check `C:\Windows\Panther\setupact.log` for `unattend` errors |
| FirstLogonCommands didn't run | `first-login.ps1` not present on target | Bake it into the WIM offline or add it as an MDT Application (State Restore, before first reboot) |
| ComputerName / TimeZone didn't apply | WIM wasn't sysprepped; specialize pass skipped | Recapture with `sysprep /generalize /oobe /shutdown` |
| MDT ignored the unattend.xml | File not in the right Control subfolder | Path must be `Control\<TaskSequenceID>\unattend.xml`; re-run Update Deployment Share |
| Windows SIM validation errors | Schema mismatch or typo | Quick check: `[xml](Get-Content unattend.xml)` in PowerShell — throws on bad XML |

---

## Reference

- Microsoft's full unattend schema:
  https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/
- Account-creation specifics:
  https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-useraccounts
