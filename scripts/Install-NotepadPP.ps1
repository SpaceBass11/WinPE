# Install-NotepadPP.ps1
# Silent-installs Notepad++ from the bundled NSIS installer staged in the
# gold image. Sysprep strips provisioned per-user apps, so this re-installs
# at first boot.
#
# Best-effort by design: a missing or failing app installer must NOT abort
# the security-critical chain (accounts, ACLs, RDP, Administrator hardening,
# BitLocker all run before this). The script logs and exits 0 on failure.

$ErrorActionPreference = 'Stop'

$root      = 'C:\ProgramData\ManualClonezilla'
$logDir    = Join-Path $root 'Logs'
$logFile   = Join-Path $logDir 'Install-NotepadPP.log'
$installer = Join-Path $root 'Installers\npp-installer.exe'
$exePaths  = @(
    'C:\Program Files\Notepad++\notepad++.exe',
    'C:\Program Files (x86)\Notepad++\notepad++.exe'
)

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Start-Transcript -Path $logFile -Append

try {
    if ($exePaths | Where-Object { Test-Path -LiteralPath $_ }) {
        Write-Host 'Notepad++ already installed; skipping.'
        return
    }

    if (-not (Test-Path -LiteralPath $installer)) {
        Write-Warning "Notepad++ installer not found at $installer; skipping (non-fatal)."
        return
    }

    Write-Host "Running silent install: $installer /S"
    $proc = Start-Process -FilePath $installer -ArgumentList '/S' -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Warning "Notepad++ installer returned exit code $($proc.ExitCode) (non-fatal)."
        return
    }

    if ($exePaths | Where-Object { Test-Path -LiteralPath $_ }) {
        Write-Host 'Notepad++ install verified.'
    } else {
        Write-Warning 'Notepad++ installer completed but notepad++.exe was not found (non-fatal).'
    }
}
catch {
    # Never let an app-install hiccup fail the deploy.
    Write-Warning "Notepad++ install error (non-fatal): $($_.Exception.Message)"
}
finally {
    Stop-Transcript
}

# Always succeed: app install is best-effort.
exit 0
