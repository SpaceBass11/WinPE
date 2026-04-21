# Code Signing

This project ships unsigned PowerShell scripts. Enterprise environments
that enforce `AllSigned` or `RemoteSigned` execution policy will need
to sign `unified_winpe_deploy.ps1` (and optionally
`scripts/build_boot_wim.ps1`) with a trusted code-signing certificate.

## Why Unsigned by Default

- Maintainer-owned keys shouldn't ship in a public repo.
- WinPE's default execution policy is `Restricted`, but the launch
  command in `startnet.cmd` uses `-ExecutionPolicy Bypass`, so the
  tool runs without signing in its primary use case.
- Manual invocations from WinPE or a dev shell can also use
  `-ExecutionPolicy Bypass`.

If your org requires signed scripts on managed hosts (including WinPE
images used for production deployment), follow the instructions below
to sign with your own cert.

## Signing Requirements

You need a **code-signing certificate** from one of:

- An internal PKI (Active Directory Certificate Services with a
  Code Signing template), trusted by the hosts that will run the
  script.
- A commercial CA (DigiCert, SSL.com, Sectigo, GlobalSign, etc.)
  that chains to a root in the Windows Trusted Root store.
- A self-signed cert — only viable for testing on your own machine,
  because no other host will trust it.

## Signing a Single Script

```powershell
# Locate your code-signing cert
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1

# Sign the deploy script (add a timestamp server for long-term validity)
Set-AuthenticodeSignature `
    -FilePath .\unified_winpe_deploy.ps1 `
    -Certificate $cert `
    -TimestampServer 'http://timestamp.digicert.com' `
    -HashAlgorithm SHA256
```

Verify the signature:

```powershell
Get-AuthenticodeSignature .\unified_winpe_deploy.ps1 | Format-List *
```

The output should show `Status : Valid`.

## Signing the Built boot.wim

If you use `scripts/build_boot_wim.ps1`, sign both the builder and the
deploy script *before* the builder copies the deploy script into the
image:

```powershell
# 1. Sign both scripts
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1
Set-AuthenticodeSignature .\unified_winpe_deploy.ps1   -Certificate $cert `
    -TimestampServer 'http://timestamp.digicert.com' -HashAlgorithm SHA256
Set-AuthenticodeSignature .\scripts\build_boot_wim.ps1 -Certificate $cert `
    -TimestampServer 'http://timestamp.digicert.com' -HashAlgorithm SHA256

# 2. Build the WinPE image — the signed deploy script is embedded
.\scripts\build_boot_wim.ps1 -Clean -UsbDrive P: -ReleaseUsbLetter
```

## Trusting Your Signature Inside WinPE

If you set WinPE's execution policy to `AllSigned`, the image must
trust the cert chain. Import the root / intermediate certs into the
offline image's `Trusted Root Certification Authorities` store during
the build:

```powershell
# Inside build_boot_wim.ps1 customization window (after Mount-WindowsImage),
# before committing the image:
Add-WindowsDriver -Path $MountPath -Driver .\your-root.cer
# (or use reg.exe against the offline SOFTWARE hive to add to the trust store)
```

Exact steps depend on your PKI; consult your CA's guide.

## Execution Policy Notes

| Policy        | Effect on unsigned deploy script           |
|---------------|--------------------------------------------|
| `Restricted`  | Blocked (WinPE default)                    |
| `AllSigned`   | Blocked unless signed + trusted            |
| `RemoteSigned`| Blocked for downloaded copies (Zone.Id)    |
| `Unrestricted`| Runs with a prompt for downloaded copies   |
| `Bypass`      | Runs unconditionally (what `startnet.cmd` uses) |

If you need `AllSigned` end-to-end, remove `-ExecutionPolicy Bypass`
from `startnet.cmd` *and* sign the script, *and* import your trust
chain into the image.

## Verification on the Target Host

After signing, any host can verify the script came from you:

```powershell
$sig = Get-AuthenticodeSignature X:\scripts\unified_winpe_deploy.ps1
$sig.Status        # Valid
$sig.SignerCertificate.Subject
$sig.TimestampCertificate.Subject
```

If `Status` is `NotTrusted` or `HashMismatch`, stop and investigate —
the file has been modified since signing or the trust chain is wrong.
