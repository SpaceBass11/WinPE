# Unattend.xml Quick Reference

Step-by-step for turning [`configs/unattend.example.xml`](../configs/unattend.example.xml)
into a real, deployable unattend file. The example template ships with
sensible defaults; this doc walks you through filling in the placeholders.

If you don't need truly unattended OOBE (i.e. it's OK to click through a
couple of screens at first boot), you can skip this whole flow — just
don't pass `-UnattendFile` to the deploy script.

---

## 1. Copy the template

Never edit `configs/unattend.example.xml` directly — keep it clean for
forks and future templates. Copy to your USB IMAGES partition:

```powershell
Copy-Item configs/unattend.example.xml I:\configs\unattend.xml
```

(The deploy script will copy `I:\configs\unattend.xml` to
`C:\Windows\Panther\unattend.xml` on the target during deployment.)

---

## 2. Encode each account password

Every `<Password><Value>` field in the unattend file expects a base64
of the UTF-16LE bytes of `<plaintext> + "Password"`. Run this in
PowerShell once per account:

```powershell
function Get-UnattendPassword {
    param([Parameter(Mandatory)][string]$Plaintext)
    $bytes = [Text.Encoding]::Unicode.GetBytes($Plaintext + 'Password')
    [Convert]::ToBase64String($bytes)
}

# Examples — replace with your real passwords
Get-UnattendPassword -Plaintext 'L0-Tech-P@ss!'      # Level 0
Get-UnattendPassword -Plaintext 'L1-Tech-P@ss!'      # Level 1
Get-UnattendPassword -Plaintext 'L2-Tech-P@ss!'      # Level 2
Get-UnattendPassword -Plaintext 'Admin-P@ss-2025!'   # DERP_Admin
```

Each call prints one base64 string. Copy each output into the matching
`BASE64_*_PASSWORD` slot in your `unattend.xml`.

> [!IMPORTANT]
> The suffix is literally the string `Password` — not the account name.
> The same suffix applies to all `<LocalAccount>` entries **and** to the
> `<AutoLogon>` block.

---

## 3. Fill in the account block

The template has four example accounts (`LocalAdmin` + 3 standard users).
Edit `<Name>` and `<DisplayName>` to match your fleet:

```xml
<LocalAccount wcm:action="add">
  <Name>DERP_Admin</Name>
  <Group>Administrators</Group>
  <DisplayName>DERP Admin</DisplayName>
  <Password>
    <Value>PASTE_BASE64_HERE</Value>
    <PlainText>false</PlainText>
  </Password>
</LocalAccount>
```

Add or remove `<LocalAccount>` blocks as needed. Two rules:
- Exactly one account should be in the `Administrators` group (the
  others go in `Users`).
- The Administrator-group account is the one you'll use for AutoLogon
  in the next step.

---

## 4. Set AutoLogon

AutoLogon is **required** for truly unattended OOBE. Without it,
Windows creates the accounts and then sits at the lock screen waiting
for a password. With it, the admin auto-logs in once so the
FirstLogonCommands can run, then reverts to normal lock-screen prompts.

```xml
<AutoLogon>
  <Username>DERP_Admin</Username>
  <Password>
    <Value>SAME_BASE64_AS_THE_ACCOUNT_ABOVE</Value>
    <PlainText>false</PlainText>
  </Password>
  <Enabled>true</Enabled>
  <LogonCount>1</LogonCount>
</AutoLogon>
```

Two gotchas:
- `<Username>` must match the `<Name>` of a `<LocalAccount>` above.
- `<Password><Value>` must be the **same** encoded value you computed
  for that account. They have to match exactly — Windows treats a
  mismatch as a bad password and OOBE stalls.

---

## 5. TimeZone

The template ships with `Central Standard Time`. To use a different
zone, change the `<TimeZone>` element in the `specialize` pass.

To list valid zone names on a running Windows box:

```cmd
tzutil /l
```

Common values: `Eastern Standard Time`, `Mountain Standard Time`,
`Pacific Standard Time`, `UTC`.

---

## 6. Verify it parses

Quick sanity-check before deploying:

```powershell
[xml](Get-Content I:\configs\unattend.xml)
```

If that throws, you have a syntax error (usually an unclosed tag or a
bad attribute). Fix it before going further — Windows Setup will reject
a malformed unattend silently and fall through to the normal OOBE flow.

---

## 7. Deploy

Boot the target into WinPE and run with the file:

```powershell
.\unified_winpe_deploy.ps1 `
    -WimFile  D:\images\Win11_Enterprise.wim `
    -TargetDisk 0 `
    -UnattendFile D:\configs\unattend.xml `
    -Force -Silent
```

The script copies `unattend.xml` to `C:\Windows\Panther\` during deploy.
Windows Setup picks it up on the very next boot.

---

## Troubleshooting

### "OOBE prompted me for an account / lock screen at first boot"
Either AutoLogon is missing/wrong, or the password encoding is bad.
Boot in safe mode, check `C:\Windows\Panther\setupact.log` — search
for `unattend` and look for parse errors or "password did not match".

### "FirstLogonCommands didn't run"
Confirm `C:\Windows\Setup\Scripts\first-login.ps1` exists on the target.
If not, you forgot `-DisableExtraBloat` when prepping the WIM (that's
the flag that stages the script).

### "I can't log in as Admin / Level0 / etc. after first boot"
Re-encode the password — most common failure is forgetting the
"Password" suffix in the encoding. Confirm:
```powershell
$expected = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('YourPass' + 'Password'))
# Compare $expected with what's in unattend.xml
```

### "ComputerName / TimeZone / locale didn't apply"
These settings live in the `specialize` pass, which only runs on a
sysprepped image. If your WIM wasn't sysprepped (i.e. you captured a
fully-set-up machine without running `sysprep /generalize` first),
specialize never fires. Re-capture with sysprep.

---

## Reference

- Microsoft's full unattend schema:
  https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/
- Account-creation specifics:
  https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-useraccounts
