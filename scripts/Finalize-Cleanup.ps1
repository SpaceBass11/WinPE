$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\ManualClonezilla'
$logDir = Join-Path $root 'Logs'
$logFile = Join-Path $logDir 'Finalize-Cleanup.log'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Start-Transcript -Path $logFile -Append

try {
    $sensitive = @(
        (Join-Path $root 'Config\dell-config.cctk'),
        (Join-Path $root 'Config\bitlocker-pin.txt')
    )

    foreach ($item in $sensitive) {
        if (Test-Path $item) {
            Remove-Item -Path $item -Force
            Write-Host "Removed $item"
        }
    }

    # State\ is intentionally preserved (BitLocker recovery key file lives
    # there for the operator to grab if needed). Logs\ also preserved for
    # support triage.
    Write-Host 'Cleanup completed.'
}
finally {
    Stop-Transcript
}
