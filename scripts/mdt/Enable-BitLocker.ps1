#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Enable BitLocker on C: (TPM + enhanced startup PIN) and data drives (password).
.DESCRIPTION
    Runs as an MDT State Restore task sequence step, after Windows is installed.

    C: is encrypted with a TPM + enhanced startup PIN (alphanumeric, XTS-AES-256).
    The PIN is prompted at every boot before Windows loads.

    Data drives (D: by default) are encrypted with the same string as a BitLocker
    password and configured for auto-unlock — they open automatically when C:
    is unlocked at boot. No second PIN entry needed.

    Recovery keys are written to $RecoveryPath BEFORE any data drive is encrypted,
    so the key files are accessible even if a data drive needs manual recovery later.

    Skips silently if -Pin is empty — allows the same ISO to be used on hardware
    without TPM 2.0 or on test VMs.

    Requirements:
      - Windows 11 Pro or Enterprise (BitLocker not available on Home)
      - TPM 2.0 enabled and cleared in BIOS (CCTK can automate this)
      - UEFI boot mode (enforced by the MDT task sequence GPT layout)

    MDT task sequence wiring (State Restore group):
      Command: powershell.exe -ExecutionPolicy Bypass -NonInteractive
               -File "%SCRIPTROOT%\Enable-BitLocker.ps1" -Pin "%BDEPin%"
      Condition: Variable BDEPin not equals ""
.PARAMETER Pin
    Enhanced startup PIN for C: and password for data drives. Alphanumeric.
    If empty or whitespace, the script exits without configuring BitLocker.
    Set via CustomSettings.ini: BDEPin=YourPinHere
.PARAMETER RecoveryPath
    Folder where .txt recovery key files are saved before encryption starts.
    Default: D:\BitLocker
    The folder is created if it does not exist. Recovery keys are saved here
    BEFORE D: is encrypted, so they remain accessible at the D:\BitLocker path
    once auto-unlock is active.
.PARAMETER DataDrives
    Data drive letters to encrypt with password protector + auto-unlock.
    Same PIN string is used as the BitLocker password.
    Drives that do not exist are silently skipped.
    Default: @('D:')
.EXAMPLE
    # From MDT task sequence — pin comes from CustomSettings.ini BDEPin=
    .\Enable-BitLocker.ps1 -Pin "%BDEPin%"
.EXAMPLE
    # Manual run for a specific drive set
    .\Enable-BitLocker.ps1 -Pin 'Alpha1PIN' -DataDrives 'D:','E:'
#>
[CmdletBinding()]
param(
    [string]   $Pin          = '',
    [string]   $RecoveryPath = 'D:\BitLocker',
    [string[]] $DataDrives   = @('D:')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Pin)) {
    Write-Host 'BDEPin is empty — BitLocker configuration skipped.'
    exit 0
}

#region Enhanced PIN policy

# Allow alphanumeric (enhanced) startup PINs.
# Must be applied before Enable-BitLocker so Windows accepts the PIN string.
$fveKey = 'HKLM:\SOFTWARE\Policies\Microsoft\FVE'
if (-not (Test-Path $fveKey)) {
    New-Item -Path $fveKey -Force | Out-Null
}
Set-ItemProperty -Path $fveKey -Name UseEnhancedPin -Value 1 -Type DWord -Force
Write-Host 'Enhanced PIN policy applied (alphanumeric startup PINs enabled).'

#endregion

#region Helpers

$pinSecure = ConvertTo-SecureString -String $Pin -AsPlainText -Force

function Get-RecoveryPassword {
    param([string]$MountPoint)
    $vol = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction SilentlyContinue
    if (-not $vol) { return $null }
    $protector = $vol.KeyProtector |
        Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } |
        Select-Object -Last 1
    if ($protector) { return $protector.RecoveryPassword }
    return $null
}

#endregion

#region Recovery folder

# Create the recovery folder on D: BEFORE encrypting D:, so the key files
# are written to the plaintext drive and remain accessible after auto-unlock.
if (-not (Test-Path $RecoveryPath)) {
    New-Item -Path $RecoveryPath -ItemType Directory -Force | Out-Null
    Write-Host "Recovery folder created: $RecoveryPath"
}

#endregion

#region C: — OS drive (TPM + enhanced startup PIN)

Write-Host ''
Write-Host '--- C: (OS drive) ---'

$cVol = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
if ($cVol -and $cVol.VolumeStatus -ne 'FullyDecrypted') {
    Write-Host '  Already configured — skipping.'
} else {
    try {
        Enable-BitLocker -MountPoint 'C:' -EncryptionMethod XtsAes256 `
            -TpmAndPinProtector -Pin $pinSecure -SkipHardwareTest | Out-Null
        Write-Host '  BitLocker enabled (TPM + startup PIN, XTS-AES-256).'
        Write-Host '  Background encryption will complete after reboot — normal behavior.'
    } catch {
        Write-Warning "  Enable-BitLocker C: failed: $_"
        Write-Warning '  Verify: TPM 2.0 enabled and cleared in BIOS, OS drive is NTFS, Windows Pro/Enterprise.'
    }

    try {
        Add-BitLockerKeyProtector -MountPoint 'C:' -RecoveryPasswordProtector | Out-Null
        $rk = Get-RecoveryPassword -MountPoint 'C:'
        if ($rk) {
            $rkFile = Join-Path $RecoveryPath 'C_RecoveryKey.txt'
            $rk | Set-Content -Path $rkFile -Encoding ASCII -Force
            Write-Host "  Recovery key saved: $rkFile"
        }
    } catch {
        Write-Warning "  C: recovery key could not be saved: $_"
    }
}

#endregion

#region Data drives (password + auto-unlock)

foreach ($drive in $DataDrives) {
    Write-Host ''
    Write-Host "--- ${drive} (data drive) ---"

    if (-not (Test-Path $drive)) {
        Write-Host '  Drive not found — skipping.'
        continue
    }

    $dVol = Get-BitLockerVolume -MountPoint $drive -ErrorAction SilentlyContinue
    if ($dVol -and $dVol.VolumeStatus -ne 'FullyDecrypted') {
        Write-Host '  Already configured — skipping.'
        continue
    }

    # Save recovery key to RecoveryPath BEFORE encrypting this drive.
    # The folder is on D:, which is still plaintext at this point.
    try {
        Add-BitLockerKeyProtector -MountPoint $drive -RecoveryPasswordProtector | Out-Null
        $rk = Get-RecoveryPassword -MountPoint $drive
        if ($rk) {
            $letter  = $drive.TrimEnd(':').ToUpper()
            $rkFile  = Join-Path $RecoveryPath "${letter}_RecoveryKey.txt"
            $rk | Set-Content -Path $rkFile -Encoding ASCII -Force
            Write-Host "  Recovery key saved: $rkFile"
        }
    } catch {
        Write-Warning "  ${drive} recovery key could not be saved: $_"
    }

    try {
        Enable-BitLocker -MountPoint $drive -EncryptionMethod XtsAes256 `
            -PasswordProtector -Password $pinSecure | Out-Null
        Write-Host "  BitLocker enabled (password, XTS-AES-256)."
    } catch {
        Write-Warning "  Enable-BitLocker ${drive}: failed: $_"
        continue
    }

    try {
        # Auto-unlock: D: opens automatically when C: unlocks at boot.
        # Operator never needs to type the data drive password manually.
        Enable-BitLockerAutoUnlock -MountPoint $drive | Out-Null
        Write-Host '  Auto-unlock enabled (unlocks when C: unlocks at boot).'
    } catch {
        Write-Warning "  Auto-unlock for ${drive}: failed — enable manually: Enable-BitLockerAutoUnlock -MountPoint '${drive}'"
    }
}

#endregion

Write-Host ''
Write-Host '=========================================='
Write-Host ' BitLocker configuration complete.'
Write-Host "  Recovery keys : $RecoveryPath"
Write-Host '  C: startup PIN takes effect on next boot.'
Write-Host '  Data drives auto-unlock with C: — no second PIN needed.'
Write-Host '=========================================='
