# Apply-GoldHardening.ps1
# Gold-image (pre-sysprep) hardening runner. Run this ONCE in the gold, in
# audit mode under the built-in Administrator, as the last step before
# sysprep /generalize. It applies the SID-independent, image-state hardening
# that survives generalize -- so it is baked into the captured image instead
# of re-run on every deploy.
#
# Order (RDP is disabled LAST, because it is intentionally left ON during the
# build for the Hyper-V enhanced session):
#   1. Install-NotepadPP.ps1    (Win32 install; survives generalize)
#   2. Apply-StigHardening.ps1  (Guest, secpol, UAC, firewall, banner)
#   3. Disable-RDP.ps1          (Terminal Services policy + service disable)
#
# What is NOT here (stays at first boot, post-sysprep, driven by
# SetupComplete.cmd) because it is per-machine or binds post-generalize SIDs:
# Apply-DellConfig, Scrub-AuditArtifacts, New-LocalAccounts, Stage-DockerData,
# Set-Level0ACL, Harden-Administrator, Assert-AdminGroup, Enable-BitLocker,
# Finalize-Cleanup.
#
# STIG and RDP steps are fatal (they throw on failure -- do NOT sysprep a gold
# that failed to harden). Notepad++ is best-effort (exits 0 on its own).

$ErrorActionPreference = 'Stop'

$root    = 'C:\ProgramData\ManualClonezilla'
$logDir  = Join-Path $root 'Logs'
$logFile = Join-Path $logDir 'Apply-GoldHardening.log'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
try { Start-Transcript -Path $logFile -Append | Out-Null }
catch { Write-Warning "Could not start transcript: $($_.Exception.Message)" }

try {
    # Each child is launched as a SEPARATE powershell.exe process (same as
    # SetupComplete.cmd). Critical: Install-NotepadPP.ps1 ends with `exit 0`,
    # and `exit` in a dot-sourced / call-operator child would terminate THIS
    # runner -- a separate process contains it. STIG and RDP are fatal (their
    # unhandled throw makes powershell.exe return non-zero); Notepad++ is
    # best-effort.
    $steps = @(
        @{ Script = 'Install-NotepadPP.ps1';   Fatal = $false },
        @{ Script = 'Apply-StigHardening.ps1'; Fatal = $true },
        @{ Script = 'Disable-RDP.ps1';         Fatal = $true }
    )
    foreach ($step in $steps) {
        $path = Join-Path $PSScriptRoot $step.Script
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Gold-hardening step not found: $path"
        }
        Write-Host "=== Running $($step.Script) ==="
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            if ($step.Fatal) {
                throw "$($step.Script) failed with exit code $code. Do NOT sysprep this gold; fix and re-run."
            }
            Write-Warning "$($step.Script) exited $code (non-fatal); continuing."
        }
        Write-Host "=== Completed $($step.Script) (exit $code) ==="
    }
    Write-Host 'Gold hardening completed. The image is ready to sysprep /generalize.'
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
