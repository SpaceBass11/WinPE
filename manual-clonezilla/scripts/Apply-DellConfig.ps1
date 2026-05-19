$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\ManualClonezilla'
$logDir = Join-Path $root 'Logs'
$stateDir = Join-Path $root 'State'
$logFile = Join-Path $logDir 'Apply-DellConfig.log'
$cfgPath = Join-Path $root 'Config\dell-config.cctk'
$cctkExe = 'C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe'
$stateFile = Join-Path $stateDir 'dell-config.applied.sha256'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
Start-Transcript -Path $logFile -Append

try {
    if (-not (Test-Path $cfgPath)) {
        throw "Missing config package: $cfgPath"
    }

    if (-not (Test-Path $cctkExe)) {
        throw "Missing Dell Command Configure executable: $cctkExe"
    }

    $cfgHash = (Get-FileHash -Path $cfgPath -Algorithm SHA256).Hash
    if ((Test-Path $stateFile) -and ((Get-Content -Path $stateFile -Raw).Trim() -eq $cfgHash)) {
        Write-Host 'Dell BIOS configuration for current file hash already applied; skipping.'
        return
    }

    & $cctkExe --import="$cfgPath"
    if ($LASTEXITCODE -ne 0) {
        throw "Dell config import failed with exit code $LASTEXITCODE"
    }

    Set-Content -Path $stateFile -Value $cfgHash -Encoding Ascii
    Write-Host 'Dell BIOS configuration import completed.'
}
finally {
    Stop-Transcript
}
