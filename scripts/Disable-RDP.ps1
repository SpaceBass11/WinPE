# Disable-RDP.ps1
# Fail-safe disable of Remote Desktop. RDP is expected to be off already
# (disabled during gold-image seal; it was only on for Hyper-V enhanced
# session during build), but this re-asserts the posture on every deploy.
#
# Controls applied:
#   1. fDenyTSConnections = 1  (the master "deny RDP connections" switch)
#   2. UserAuthentication = 1  (require NLA, defense-in-depth if ever re-enabled)
#   3. Disable the "Remote Desktop" firewall rule group
#   4. Set TermService / UmRdpService startup to Disabled (fail-safe)

$ErrorActionPreference = 'Stop'

$root    = 'C:\ProgramData\ManualClonezilla'
$logDir  = Join-Path $root 'Logs'
$logFile = Join-Path $logDir 'Disable-RDP.log'

$tsKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$rdpKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
try { Start-Transcript -Path $logFile -Append | Out-Null }
catch { Write-Warning "Could not start transcript: $($_.Exception.Message)" }

try {
    Set-ItemProperty -Path $tsKey -Name 'fDenyTSConnections' -Value 1 -Type DWord
    # Read back and hard-fail if the master switch did not take -- this is the
    # primary RDP control, so a silent failure is not acceptable.
    $deny = (Get-ItemProperty -Path $tsKey -Name 'fDenyTSConnections').fDenyTSConnections
    if ($deny -ne 1) {
        throw "fDenyTSConnections did not apply (read back '$deny')."
    }
    Write-Host 'Set fDenyTSConnections = 1 (verified).'

    if (Test-Path -LiteralPath $rdpKey) {
        Set-ItemProperty -Path $rdpKey -Name 'UserAuthentication' -Value 1 -Type DWord
        Write-Host 'Set UserAuthentication = 1 (NLA required).'
    }

    # Disable the Remote Desktop firewall rule group (best-effort).
    try {
        Disable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction Stop
        Write-Host 'Disabled "Remote Desktop" firewall rule group.'
    } catch {
        Write-Warning "Could not disable Remote Desktop firewall group: $($_.Exception.Message)"
    }

    foreach ($svc in 'TermService', 'UmRdpService') {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if (-not $s) {
            Write-Host "Service '$svc' not present; skipping."
            continue
        }
        if ($s.Status -eq 'Running') {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        }
        Set-Service -Name $svc -StartupType Disabled
        Write-Host "Service '$svc' set to Disabled."
    }

    Write-Host 'RDP disabled.'
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
