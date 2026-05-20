$ErrorActionPreference = 'Stop'

$root      = 'C:\ProgramData\ManualClonezilla'
$logDir    = Join-Path $root 'Logs'
$stateDir  = Join-Path $root 'State'
$configDir = Join-Path $root 'Config'
$logFile   = Join-Path $logDir 'Enable-BitLocker.log'
$pinFile   = Join-Path $configDir 'bitlocker-pin.txt'

New-Item -ItemType Directory -Path $logDir   -Force | Out-Null
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
Start-Transcript -Path $logFile -Append

function Export-RecoveryKey {
    param(
        [Parameter(Mandatory)] $RecoveryProtector,
        [Parameter(Mandatory)] [string]$StateDir
    )
    $machineName = $env:COMPUTERNAME
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $outFile = Join-Path $StateDir ("BitLocker-RecoveryKey-{0}-{1}.txt" -f $machineName, $stamp)
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

try {
    $osVol = Get-BitLockerVolume -MountPoint 'C:'
    if ($osVol.ProtectionStatus -eq 'On') {
        Write-Host 'BitLocker already enabled; skipping.'
        return
    }
    if ($osVol.VolumeStatus -eq 'EncryptionInProgress') {
        Write-Host 'BitLocker encryption already in progress; skipping duplicate enable call.'
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

    Export-RecoveryKey -RecoveryProtector $recovery -StateDir $stateDir | Out-Null

    Write-Host 'BitLocker enabled on C: with TpmPin + RecoveryPassword protectors.'
}
finally {
    Stop-Transcript
}
