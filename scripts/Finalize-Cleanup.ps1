$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\ManualClonezilla'
$logDir = Join-Path $root 'Logs'
$logFile = Join-Path $logDir 'Finalize-Cleanup.log'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Start-Transcript -Path $logFile -Append

try {
    $sensitive = @(
        (Join-Path $root 'Config\dell-config.cctk')
    )

    foreach ($item in $sensitive) {
        if (Test-Path $item) {
            Remove-Item -Path $item -Force
            Write-Host "Removed $item"
        }
    }

    Write-Host 'Cleanup completed.'
}
finally {
    Stop-Transcript
}
