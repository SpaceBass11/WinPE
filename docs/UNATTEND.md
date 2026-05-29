# unattend.xml Answer File

Windows Setup reads `unattend.xml` on first boot to skip OOBE prompts,
set computer name and time zone, and copy the audit-mode profile
(`CopyProfile`). Account creation in this workflow is done by
`New-LocalAccounts.ps1` at first boot, not by the answer file. You stage
the file at
`C:\Windows\Panther\unattend.xml` on the gold image **before sysprep**;
the captured Clonezilla image carries it along, and Windows
automatically picks it up during specialize + oobeSystem passes after
restore.

---

## Where the file goes

On your reference machine, before running `sysprep`:

```cmd
mkdir C:\Windows\Panther 2>nul
copy /y <your-edited-unattend.xml> C:\Windows\Panther\unattend.xml
```

The skeleton template lives at
[`configs/unattend.example.xml`](../configs/unattend.example.xml).
Don't edit the example in place -- keep it clean for the next image
cut.

---

## Template

The shipped skeleton (`configs/unattend.example.xml`) suppresses OOBE
pages, sets UTC time zone, and sets `<CopyProfile>true</CopyProfile>` in
the `specialize` pass. It is otherwise intentionally minimal.

**Accounts are NOT created by this answer file.** The gold master is built
in **audit mode** under the built-in Administrator, and the named accounts
(`Level 0`-`Level 3`, `IT_Admin`) are provisioned at first boot by
`New-LocalAccounts.ps1`, not by a `UserAccounts` block. See "Adding
accounts" below for why, and the alternative if you want answer-file
accounts instead.

### CopyProfile and audit mode

`CopyProfile=true` tells specialize to copy the current default user's
profile (the customized built-in Administrator profile you built in audit
mode) onto the **Default** profile, so every newly created account inherits
it. It is processed during `specialize`, which runs *before*
`SetupComplete.cmd` -- so the first-boot `Harden-Administrator.ps1`
(disable/rename of the built-in admin) cannot race the profile copy.

Caveat: CopyProfile copies whatever the active local profile is at
generalize time, so seal the gold master from the customized Administrator
session you want propagated.

### What to change

| Field | Default | Notes |
|---|---|---|
| `<TimeZone>` | `UTC` | Run `tzutil /l` on any Windows box to list valid names. Common: `Central Standard Time`, `Pacific Standard Time`. |
| `<HideEULAPage>` etc. | `true` | Leave at `true` for hands-off boot. |
| `<RegisteredOrganization>` | `manual-clonezilla` | Cosmetic. Change to your org. |

The skeleton does **not** set `<ComputerName>`. Omitted = Windows
generates a random `DESKTOP-XXXXXX` name on first specialize. If you
want a stable pattern, add a `<ComputerName>` element to the
`Microsoft-Windows-Shell-Setup` component in the `specialize` pass.
Common values:

- `*` -- random (same as omitting)
- A literal string -- same name on every machine (not recommended; AD
  join will fail on the second machine if you ever domain-join)
- `%SerialNumber%` -- service tag on Dell, MAC-derived elsewhere

---

## Adding accounts

This workflow provisions accounts at first boot via
`New-LocalAccounts.ps1` (reading `Config\accounts.csv`), **not** through the
answer file -- that keeps account passwords out of the baked
`unattend.xml`/Panther copies and lets the role/ACL logic live in one place.
Prefer that path.

The answer-file approach below is the **alternative** if you specifically
want Windows to create an account during OOBE (e.g. a bootstrap admin). Note
that an answer-file password persists in `C:\Windows\Panther\unattend.xml`
until `Scrub-AuditArtifacts.ps1` removes it. To add such an account, add a
`UserAccounts` block to the `oobeSystem` pass:

```xml
<settings pass="oobeSystem">
  <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
             publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
    <UserAccounts>
      <LocalAccounts>
        <LocalAccount wcm:action="add">
          <Name>LocalAdmin</Name>
          <Group>Administrators</Group>
          <Password>
            <Value>BASE64_HERE</Value>
            <PlainText>false</PlainText>
          </Password>
        </LocalAccount>
      </LocalAccounts>
    </UserAccounts>
  </component>
</settings>
```

The password value is **UTF-16LE-encoded `<plaintext><PASSWORD>Password`**
base64. PowerShell helper:

```powershell
$plain = 'YourPassword'
$concat = "${plain}Password"
[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($concat))
```

That base64 string goes inside `<Value>`.

---

## Passes

The template uses two Windows Setup passes:

**`specialize`** -- runs after restore (before the first OOBE prompt
appears). This is where `ComputerName`, `TimeZone`, and `CopyProfile` are
applied. These settings require a sysprepped image. If you captured without
running `sysprep /generalize`, specialize never fires and these
settings silently no-op.

**`oobeSystem`** -- runs during OOBE on first boot. Locale, account
creation, autologon, and `FirstLogonCommands` are processed here.
These settings apply regardless of whether the image was sysprepped.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| OOBE prompts appear (region, keyboard, EULA) | unattend.xml not at `C:\Windows\Panther\` on the captured image | Check the path on the gold reference machine before sysprep. Recapture. |
| Account not created | `UserAccounts` block missing or schema-invalid | `[xml](Get-Content unattend.xml)` in PowerShell -- throws on bad XML. Also check `C:\Windows\Panther\setupact.log` on the deployed machine. |
| ComputerName / TimeZone didn't apply | Image wasn't sysprepped; specialize pass skipped | Recapture with `sysprep /generalize /oobe /shutdown`. |
| FirstLogonCommands didn't run | Script not present at the path in the CommandLine element | Bake the script into the gold image at a stable path before sysprep. |
| `[xml]` parse errors | Schema mismatch or typo | Use Windows SIM on an admin workstation (ADK component) to validate the file before baking into the gold image. |

---

## Reference

- Microsoft's full unattend schema:
  https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/
- Account-creation specifics:
  https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-useraccounts
