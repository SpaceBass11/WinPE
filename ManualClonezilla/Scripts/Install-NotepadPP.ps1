# Install-NotepadPP.ps1
# RUNS IN THE GOLD PRE-SYSPREP (not at first boot). Notepad++ is a machine-
# wide Win32/NSIS install, NOT a provisioned Appx package -- sysprep
# /generalize only strips Appx, so a Win32 install done in the gold is
# captured into the image and survives generalize. There is therefore no
# reason to re-install it on every deploy. Invoke via Apply-GoldHardening.ps1.
#
# Best-effort by design (logs and exits 0 on failure) so a missing or failing
# installer cannot abort the gold-hardening run.

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
try { Start-Transcript -Path $logFile -Append | Out-Null }
catch { Write-Warning "Could not start transcript: $($_.Exception.Message)" }

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
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}

# Always succeed: app install is best-effort.
exit 0
