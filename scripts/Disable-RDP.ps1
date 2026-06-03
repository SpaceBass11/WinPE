# Disable-RDP.ps1
# Fail-safe disable of Remote Desktop via the Local Group Policy registry
# values. RDP is expected to be off already (it was only on for Hyper-V
# enhanced session during build), but this re-asserts the posture on every
# deploy.
#
# Controls applied under the Terminal Services *policy* hive -- the same
# values gpedit writes for "Allow users to connect remotely by using Remote
# Desktop Services = Disabled" and the NLA policy. Writing the policy hive
# (rather than the System Properties preference under
# HKLM\SYSTEM\...\Control\Terminal Server) means the setting takes precedence
# and shows as managed in gpedit:
#   1. fDenyTSConnections = 1  (master "deny RDP connections" policy)
#   2. UserAuthentication = 1  (require NLA, defense-in-depth if ever re-enabled)
#   3. Set TermService / UmRdpService startup to Disabled (fail-safe)
#
# These policy values are written directly rather than imported from a
# registry.pol via LGPO.exe, so there is no external tool to stage. A domain
# gpupdate could in theory clobber local policy, but these are offline,
# unmanaged machines, so nothing refreshes it.
#
# Deliberately does NOT touch the Windows Firewall: blocking the "Remote
# Desktop" rule group is redundant once the service is disabled and the
# policy denies connections, and the firewall posture is managed separately.

$ErrorActionPreference = 'Stop'

$root    = 'C:\ProgramData\ManualClonezilla'
$logDir  = Join-Path $root 'Logs'
$logFile = Join-Path $logDir 'Disable-RDP.log'

# Terminal Services policy key (the gpedit-managed location). Note the value
# semantics: fDenyTSConnections = 1 means RDP is DENIED.
$policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
try { Start-Transcript -Path $logFile -Append | Out-Null }
catch { Write-Warning "Could not start transcript: $($_.Exception.Message)" }

try {
    # The policy key is not guaranteed to exist on a clean image; create it.
    if (-not (Test-Path -LiteralPath $policyKey)) {
        New-Item -Path $policyKey -Force | Out-Null
    }

    Set-ItemProperty -Path $policyKey -Name 'fDenyTSConnections' -Value 1 -Type DWord
    # Read back and hard-fail if the master policy did not take -- this is the
    # primary RDP control, so a silent failure is not acceptable.
    $deny = (Get-ItemProperty -Path $policyKey -Name 'fDenyTSConnections').fDenyTSConnections
    if ($deny -ne 1) {
        throw "fDenyTSConnections policy did not apply (read back '$deny')."
    }
    Write-Host 'Set fDenyTSConnections = 1 policy (verified).'

    Set-ItemProperty -Path $policyKey -Name 'UserAuthentication' -Value 1 -Type DWord
    Write-Host 'Set UserAuthentication = 1 policy (NLA required).'

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

    Write-Host 'RDP disabled (policy + service state).'
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
