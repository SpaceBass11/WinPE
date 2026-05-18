# Unattend.xml Answer File

Windows Setup reads `unattend.xml` on first boot to skip OOBE prompts, create
local accounts, set the computer name and time zone, configure AutoLogon, and
run first-boot scripts. MDT links the file to the task sequence; the WinPE tool
stages it at deploy time. The file format is identical — only how it gets there
differs.

---

## MDT Method (primary)

Two ways to attach an unattend.xml to an MDT task sequence:

### Option A — MDT Workbench GUI

1. Open MDT Workbench and expand **Task Sequences**.
2. Right-click your task sequence → **Properties** → **OS Info** tab.
3. Click **Edit Unattend.xml** — this opens Windows System Image Manager (SIM).
4. In SIM, import `configs/unattend.example.xml` (File → Open Answer File),
   fill in your values, and save. MDT records the path.
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

## WinPE Tool Method (alternative)

When using `unified_winpe_deploy.ps1` directly (without MDT), pass the file
via `-UnattendFile`:

```powershell
.\unified_winpe_deploy.ps1 `
    -WimFile  D:\images\Win11_Enterprise.wim `
    -TargetDisk 0 `
    -UnattendFile D:\configs\unattend.xml `
    -Force -Silent
```

The script copies the file to `C:\Windows\Panther\unattend.xml` on the target.
Windows Setup picks it up on the very next boot.

If you don't need truly unattended OOBE (it's OK to click through a couple of
screens at first boot), skip this — just omit `-UnattendFile`.

---

## Template

Start from [`configs/unattend.example.xml`](../configs/unattend.example.xml).
Never edit it in place — keep the example clean for future reference.

```powershell
Copy-Item configs/unattend.example.xml I:\configs\unattend.xml
```

### Placeholders to fill in

| Placeholder | What to put there |
|---|---|
| `BASE64_LOCALADMIN_PASSWORD` | Encoded admin account password (see below) |
| `BASE64_TECHL0_PASSWORD` | Encoded TechL0 password |
| `BASE64_TECHL1_PASSWORD` | Encoded TechL1 password |
| `BASE64_TECHL2_PASSWORD` | Encoded TechL2 password |
| `WIN-*` | Fixed hostname, or leave as-is for a random suffix |
| `Central Standard Time` | Your time zone (`tzutil /l` to list valid names) |
| Account `<Name>` / `<DisplayName>` | Rename the four example accounts as needed |

---

## Password Encoding

Each `<Password><Value>` field expects a base64 of the UTF-16LE bytes of
`<plaintext> + "Password"`. Run this in PowerShell once per account:

```powershell
function Get-UnattendPassword {
    param([Parameter(Mandatory)][string]$Plaintext)
    $bytes = [Text.Encoding]::Unicode.GetBytes($Plaintext + 'Password')
    [Convert]::ToBase64String($bytes)
}

# Examples — replace with your real passwords
Get-UnattendPassword -Plaintext 'L0-Tech-P@ss!'      # TechL0
Get-UnattendPassword -Plaintext 'L1-Tech-P@ss!'      # TechL1
Get-UnattendPassword -Plaintext 'L2-Tech-P@ss!'      # TechL2
Get-UnattendPassword -Plaintext 'Admin-P@ss-2025!'   # LocalAdmin
```

Each call prints one base64 string. Paste each output into the matching
`BASE64_*_PASSWORD` slot in your `unattend.xml`.

**Important:** the suffix is literally the string `Password` — not the account
name. The same suffix applies to all `<LocalAccount>` entries **and** to the
`<AutoLogon>` block. The `<AutoLogon><Password>` value must be the **same**
encoded value as the matching `<LocalAccount>` — a mismatch causes OOBE to stall
at the lock screen.

Set `<PlainText>false</PlainText>` if encoded (recommended),
`<PlainText>true</PlainText>` if you accept the security trade-off of
inlining plaintext.

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
| OOBE prompted for account / lock screen at first boot | AutoLogon missing or password mismatch | Check `C:\Windows\Panther\setupact.log` for `unattend` errors; re-encode passwords |
| FirstLogonCommands didn't run | `first-login.ps1` not present on target | Prep the WIM with `-DisableExtraBloat`, or add the script as an MDT Application |
| Can't log in after first boot | Password encoding is wrong | Re-run `Get-UnattendPassword`; confirm the `Password` suffix is included |
| ComputerName / TimeZone didn't apply | WIM wasn't sysprepped; specialize pass skipped | Recapture with `sysprep /generalize /oobe /shutdown` |
| MDT ignored the unattend.xml | File not in the right Control subfolder | Path must be `Control\<TaskSequenceID>\unattend.xml`; re-run Update Deployment Share |
| Windows SIM validation errors | Schema mismatch or typo | Quick check: `[xml](Get-Content unattend.xml)` in PowerShell — throws on bad XML |

---

## Reference

- Microsoft's full unattend schema:
  https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/
- Account-creation specifics:
  https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-useraccounts
