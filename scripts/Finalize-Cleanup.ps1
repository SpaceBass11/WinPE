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

    # Reclaim the staged Docker data disk (potentially many GB) once it has
    # been copied into Level 1's profile. Only delete the source if staging
    # succeeded (the State marker exists); a failed stage keeps the source so
    # the payload can be recovered for triage. Not a secret -- just bulk.
    $dockerPayload = Join-Path $root 'Payload\docker_data.vhdx'
    $dockerMarker  = Join-Path $root 'State\docker-data.staged.sha256'
    if ((Test-Path $dockerMarker) -and (Test-Path $dockerPayload)) {
        Remove-Item -Path $dockerPayload -Force
        Write-Host "Removed staged Docker payload $dockerPayload (already seeded into Level 1)."
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
