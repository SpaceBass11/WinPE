# Unattend.xml — First-Boot Auto-Configuration

Step-by-step for turning [`configs/unattend.example.xml`](../configs/unattend.example.xml)
into a real, deployable answer file. With this in place, Windows skips
OOBE, creates your accounts, sets the time zone and computer name, and
optionally auto-logs in once on first boot.

**Skip this whole document** if you're OK clicking through Windows OOBE
manually after each deploy. The deploy procedure (README.md) works
either way.

---

## 1. Copy the template

Don't edit `configs/unattend.example.xml` directly — keep it clean as
a reference. Copy it somewhere else and edit the copy:

```
copy configs\unattend.example.xml C:\work\unattend.xml
notepad C:\work\unattend.xml
```

---

## 2. Encode each account password

Every `<Password><Value>` slot in the unattend file expects a base64
encoding of the UTF-16LE bytes of `<plaintext> + "Password"`. (The
literal word `Password` — not the account name.) Microsoft documents
this quirk; you can't pass plaintext.

The easiest way is a PowerShell one-liner. On your admin workstation,
open PowerShell and paste:

```powershell
function Get-UnattendPassword {
    param([Parameter(Mandatory)][string]$Plaintext)
    $bytes = [Text.Encoding]::Unicode.GetBytes($Plaintext + 'Password')
    [Convert]::ToBase64String($bytes)
}

# Then run once per account, replacing the strings with real passwords:
Get-UnattendPassword -Plaintext 'L0-Tech-P@ss!'
Get-UnattendPassword -Plaintext 'L1-Tech-P@ss!'
Get-UnattendPassword -Plaintext 'Admin-P@ss-2025!'
```

Each call prints one long base64 string. Copy each one into the matching
`BASE64_*_PASSWORD` slot in your unattend.xml.

---

## 3. Fill in the account block

The template has four example accounts (`LocalAdmin` + 3 standard
users). For each, set `<Name>`, `<DisplayName>`, and paste the base64
you computed in step 2:

```xml
<LocalAccount wcm:action="add">
  <Name>SiteAdmin</Name>
  <Group>Administrators</Group>
  <DisplayName>Site Admin</DisplayName>
  <Password>
    <Value>PASTE_BASE64_HERE</Value>
    <PlainText>false</PlainText>
  </Password>
</LocalAccount>
```

Two rules:

- Exactly one account should be in the `Administrators` group; put the
  rest in `Users`.
- The Administrator-group account is the one you'll use for AutoLogon
  in the next step.

You can add or remove `<LocalAccount>` blocks. Match the surrounding
indentation.

---

## 4. Set AutoLogon

AutoLogon is **required** for truly unattended OOBE. Without it,
Windows creates the accounts and then sits at the lock screen waiting
for a password. With it, the admin auto-logs in once so first-logon
commands can run, then reverts to normal lock-screen behavior.

```xml
<AutoLogon>
  <Username>SiteAdmin</Username>
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
- `<Password><Value>` must be the **exact same** encoded value as
  that account. Windows treats a mismatch as a bad password and OOBE
  stalls.

---

## 5. TimeZone

The template ships with `Central Standard Time`. To change it, edit the
`<TimeZone>` element in the `specialize` pass.

To list valid zone names, run on any Windows machine:

```
tzutil /l
```

Common values: `Eastern Standard Time`, `Mountain Standard Time`,
`Pacific Standard Time`, `UTC`.

---

## 6. Verify it parses

Quick sanity check before deploying. In PowerShell:

```powershell
[xml](Get-Content C:\work\unattend.xml)
```

If that throws, you have a syntax error (usually an unclosed tag or a
bad attribute). Fix it before going further. Windows Setup will reject
a malformed unattend silently and fall through to the normal OOBE flow
— so you won't always know it failed until you're staring at a regular
OOBE screen.

---

## 7. Put it on the IMAGES partition

Once the file parses, copy it to the USB's IMAGES data partition:

```
mkdir I:\configs
copy C:\work\unattend.xml I:\configs\unattend.xml
```

---

## 8. Use it during deploy

At [README.md step 8](../README.md#8-optional-stage-an-unattendxml),
copy the file onto the target after `dism /Apply-Image` finishes:

```
mkdir C:\Windows\Panther
copy I:\configs\unattend.xml C:\Windows\Panther\unattend.xml
```

Windows Setup picks this up automatically on first boot.

---

## Troubleshooting

### OOBE prompted me for an account / lock screen at first boot

Either AutoLogon is missing/wrong, or a password encoding is bad.

Boot the machine in safe mode (or back into WinPE and inspect the
target disk). Open `C:\Windows\Panther\setupact.log` — search for
`unattend` and look for parse errors or "password did not match".

### I can't log in as one of the accounts after first boot

The most common failure is forgetting the literal `Password` suffix
when encoding. Confirm by re-encoding:

```powershell
$expected = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('YourPass' + 'Password'))
# Compare $expected against the value in unattend.xml
```

If they don't match, re-encode and re-deploy (or boot a recovery USB
and overwrite `C:\Windows\Panther\unattend.xml` plus the on-disk SAM —
easier to just redeploy).

### ComputerName / TimeZone didn't apply

These settings live in the `specialize` pass, which only runs on a
sysprepped image. If your WIM wasn't sysprepped (i.e. you captured a
fully-set-up machine without running `sysprep /generalize` first),
`specialize` never fires. Re-capture with sysprep, or apply these
settings post-deploy with a different mechanism (GPO, manual config).

---

## Reference

- Microsoft's full unattend schema:
  https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/
- Account-creation specifics:
  https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-useraccounts
