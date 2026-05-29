$ErrorActionPreference = 'Stop'

$root      = 'C:\ProgramData\ManualClonezilla'
$logDir    = Join-Path $root 'Logs'
$configDir = Join-Path $root 'Config'
$logFile   = Join-Path $logDir 'Enable-BitLocker.log'
$pinFile   = Join-Path $configDir 'bitlocker-pin.txt'

# Recovery keys are written here for manual off-machine export by the
# operator. Outside the ManualClonezilla tree so Finalize-Cleanup never
# touches it. The directory is ACL-locked to SYSTEM + Administrators (see
# Set-KeyDirAcl) so a standard user cannot read a recovery password -- a
# recovery password bypasses TPM+PIN entirely.
$keyDir    = 'C:\ProgramData\BitLockers'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

try { Start-Transcript -Path $logFile -Append | Out-Null }
catch { Write-Warning "Could not start transcript: $($_.Exception.Message)" }

# Shared helpers (New-RecoveryKeyFileName).
. (Join-Path $PSScriptRoot 'Common.ps1')

function Set-KeyDirAcl {
    param([Parameter(Mandatory)] [string]$Path)
    # Replace inherited permissions with an explicit allow-list: SYSTEM and
    # the local Administrators group get Full; everyone else (Users,
    # Authenticated Users) is removed. Resolved by well-known SID.
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $rights  = [System.Security.AccessControl.FileSystemRights]::FullControl
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $prop    = [System.Security.AccessControl.PropagationFlags]::None
    $allow   = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $idref = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule  = New-Object System.Security.AccessControl.FileSystemAccessRule($idref, $rights, $inherit, $prop, $allow)
        $acl.AddAccessRule($rule)
    }
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $Path -AclObject $acl
    Write-Host "Locked recovery key directory ACL to SYSTEM + Administrators: $Path"
}

function Export-RecoveryKey {
    param(
        [Parameter(Mandatory)] $RecoveryProtector,
        [Parameter(Mandatory)] [string]$KeyDir
    )
    $machineName = $env:COMPUTERNAME
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $outFile = Join-Path $KeyDir (New-RecoveryKeyFileName -ComputerName $machineName -Stamp $stamp)
    $body = @"
BitLocker Recovery Key
======================
Computer:          $machineName
Generated:         $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
Mount Point:       C:
Key Protector Id:  $($RecoveryProtector.KeyProtectorId)

Recovery Password (48 digits):
$($RecoveryProtector.RecoveryPassword)

To unlock from the BitLocker recovery prompt, type the 48-digit
password above. Store this file off-machine before discarding.
"@
    Set-Content -Path $outFile -Value $body -Encoding ASCII
    Write-Host "Recovery key exported to $outFile"
    return $outFile
}

function Test-RecoveryKeyFileExists {
    param([Parameter(Mandatory)] [string]$KeyDir)
    $pattern = "BitLocker-RecoveryKey-$($env:COMPUTERNAME)-*.txt"
    $hit = Get-ChildItem -LiteralPath $KeyDir -Filter $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
    return [bool]$hit
}

function Get-OrAddRecoveryProtector {
    param([Parameter(Mandatory)] [string]$MountPoint)
    $vol = Get-BitLockerVolume -MountPoint $MountPoint
    $rec = $vol.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword' | Select-Object -First 1
    if (-not $rec) {
        Write-Host 'No RecoveryPassword protector found; adding one.'
        Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector | Out-Null
        $vol = Get-BitLockerVolume -MountPoint $MountPoint
        $rec = $vol.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword' | Select-Object -First 1
    }
    if (-not $rec) {
        throw 'RecoveryPassword protector missing after add. Refusing to leave volume with no recovery path.'
    }
    return $rec
}

try {
    # Lock the recovery-key directory ACL first, every run, so the keys are
    # never briefly world-readable even if a prior run created the folder.
    Set-KeyDirAcl -Path $keyDir

    $osVol = Get-BitLockerVolume -MountPoint 'C:'

    # Idempotent skip path: BitLocker already on (or encrypting). Do NOT just
    # return -- a prior run may have enabled the TpmPin protector but crashed
    # before adding/exporting the recovery protector. Guarantee a recovery
    # protector exists and a key file is present before returning.
    if (($osVol.ProtectionStatus -eq 'On') -or ($osVol.VolumeStatus -eq 'EncryptionInProgress')) {
        Write-Host 'BitLocker already enabled/encrypting; verifying recovery protector and key export.'
        $recovery = Get-OrAddRecoveryProtector -MountPoint 'C:'
        if (-not (Test-RecoveryKeyFileExists -KeyDir $keyDir)) {
            Export-RecoveryKey -RecoveryProtector $recovery -KeyDir $keyDir | Out-Null
        } else {
            Write-Host 'Recovery key file already present for this host.'
        }
        return
    }

    $tpm = Get-Tpm
    if (-not $tpm.TpmPresent -or -not $tpm.TpmReady) {
        throw 'TPM is not present/ready; refusing to enable BitLocker.'
    }

    if (-not (Test-Path -LiteralPath $pinFile)) {
        throw "PIN file not found: $pinFile. Stage the gold image with a single-line PIN at this path before sysprep."
    }
    $pinPlain = (Get-Content -LiteralPath $pinFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($pinPlain)) {
        throw "PIN file $pinFile is empty."
    }
    # Enhanced PIN policy is set in the gold image; PowerShell does not
    # validate length/charset against the active policy. The Enable-BitLocker
    # call below will fail if the PIN violates the policy in effect.
    $pin = ConvertTo-SecureString -String $pinPlain -AsPlainText -Force
    Remove-Variable pinPlain -ErrorAction SilentlyContinue

    Enable-BitLocker -MountPoint 'C:' `
                     -EncryptionMethod XtsAes256 `
                     -UsedSpaceOnly `
                     -TpmAndPinProtector `
                     -Pin $pin `
                     -SkipHardwareTest | Out-Null

    Add-BitLockerKeyProtector -MountPoint 'C:' -RecoveryPasswordProtector | Out-Null

    $verify = Get-BitLockerVolume -MountPoint 'C:'
    if (($verify.ProtectionStatus -ne 'On') -and ($verify.VolumeStatus -ne 'EncryptionInProgress')) {
        throw 'BitLocker enable command completed but protection/encryption did not start.'
    }

    $protectorTypes = $verify.KeyProtector | ForEach-Object { $_.KeyProtectorType }
    if ($protectorTypes -notcontains 'TpmPin') {
        throw "Expected TpmPin protector missing after enable; found: $($protectorTypes -join ', ')"
    }
    $recovery = $verify.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword' | Select-Object -First 1
    if (-not $recovery) {
        throw 'RecoveryPassword protector missing after Add-BitLockerKeyProtector. Refusing to leave volume with no recovery path.'
    }

    Export-RecoveryKey -RecoveryProtector $recovery -KeyDir $keyDir | Out-Null

    Write-Host 'BitLocker enabled on C: with TpmPin + RecoveryPassword protectors.'
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
