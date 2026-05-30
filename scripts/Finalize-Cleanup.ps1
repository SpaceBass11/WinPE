$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\ManualClonezilla'
$logDir = Join-Path $root 'Logs'
$logFile = Join-Path $logDir 'Finalize-Cleanup.log'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
try { Start-Transcript -Path $logFile -Append | Out-Null }
catch { Write-Warning "Could not start transcript: $($_.Exception.Message)" }

try {
    $sensitive = @(
        (Join-Path $root 'Config\dell-config.cctk'),
        (Join-Path $root 'Config\bitlocker-pin.txt'),
        (Join-Path $root 'Config\accounts.csv')
    )

    foreach ($item in $sensitive) {
        if (Test-Path $item) {
            Remove-Item -Path $item -Force
            Write-Host "Removed $item"
        }
    }

    # State\ is intentionally preserved (it holds the Dell config SHA256
    # idempotency marker, not secrets). The BitLocker recovery keys live in
    # C:\ProgramData\BitLockers\ (ACL-locked, outside this tree) and are also
    # preserved for the operator. Logs\ is preserved for support triage.
    Write-Host 'Cleanup completed.'
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
