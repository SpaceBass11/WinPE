$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\ManualClonezilla'
$logDir = Join-Path $root 'Logs'
$logFile = Join-Path $logDir 'Enable-BitLocker.log'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Start-Transcript -Path $logFile -Append

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

    Enable-BitLocker -MountPoint 'C:' -UsedSpaceOnly -TpmProtector -SkipHardwareTest

    $verify = Get-BitLockerVolume -MountPoint 'C:'
    if (($verify.ProtectionStatus -ne 'On') -and ($verify.VolumeStatus -ne 'EncryptionInProgress')) {
        throw 'BitLocker enable command completed but protection/encryption did not start.'
    }

    Write-Host 'BitLocker enablement started successfully on C:.'
}
finally {
    Stop-Transcript
}
