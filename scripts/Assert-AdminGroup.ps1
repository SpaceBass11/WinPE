# Assert-AdminGroup.ps1
# First-boot (post-sysprep) safety assertion: only IT_Admin and the
# (disabled) built-in Administrator may be members of the local
# Administrators group. Hard-fails the deploy otherwise -- the whole Level
# 0-3 posture depends on the role accounts being standard users.
#
# This must run at FIRST BOOT (not in the gold) because it inspects the
# post-generalize accounts: IT_Admin and Level 0-3 are created by
# New-LocalAccounts.ps1, and the built-in admin is disabled by
# Harden-Administrator.ps1 -- none of which exist in the gold. The rest of
# the STIG baseline (SID-independent image state) is baked into the gold by
# Apply-StigHardening.ps1 instead.
#
# Built-in admin is matched by RID 500 (SID), IT_Admin by name, groups by
# well-known SID -- all locale- and rename-independent.

$ErrorActionPreference = 'Stop'

$root      = 'C:\ProgramData\ManualClonezilla'
$logDir    = Join-Path $root 'Logs'
$logFile   = Join-Path $logDir 'Assert-AdminGroup.log'
$adminUser = 'IT_Admin'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
try { Start-Transcript -Path $logFile -Append | Out-Null }
catch { Write-Warning "Could not start transcript: $($_.Exception.Message)" }

try {
    $adminsGroup = (Get-LocalGroup -SID 'S-1-5-32-544').Name

    $allowed = @()
    $builtinAdmin = Get-LocalUser | Where-Object { $_.SID.Value -like 'S-1-5-*-500' } | Select-Object -First 1
    if ($builtinAdmin) { $allowed += $builtinAdmin.SID.Value }
    $itAdmin = Get-LocalUser -Name $adminUser -ErrorAction SilentlyContinue
    if ($itAdmin) { $allowed += $itAdmin.SID.Value }

    $members = Get-LocalGroupMember -Group $adminsGroup -ErrorAction Stop
    $violations = @()
    foreach ($m in $members) {
        if ($allowed -notcontains $m.SID.Value) {
            $violations += ("{0} ({1})" -f $m.Name, $m.SID.Value)
        }
    }
    if ($violations.Count -gt 0) {
        throw ("Unexpected member(s) in '{0}': {1}. Only {2} and the built-in admin (disabled) are permitted." -f $adminsGroup, ($violations -join '; '), $adminUser)
    }
    Write-Host "Administrators group membership verified (only $adminUser + disabled built-in)."
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
