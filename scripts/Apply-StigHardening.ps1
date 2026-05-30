# Apply-StigHardening.ps1
# STIG-leaning baseline that the account/BitLocker scripts don't cover.
# Runs after New-LocalAccounts and Harden-Administrator so the final
# Administrators-group assertion sees the real post-hardening membership.
#
#   1. Built-in Guest (RID 501): disable + rename off "Guest".
#   2. Password + account-lockout policy via secedit (length/complexity/age/
#      history + lockout threshold/duration/window).
#   3. UAC: EnableLUA, admin consent on secure desktop, FilterAdministratorToken.
#   4. Windows Firewall: all three profiles on, default inbound block
#      (best-effort -- logged, not fatal, in case the firewall module is
#      stripped from the image).
#   5. Logon banner + DontDisplayLastUserName.
#   6. Assertion: only IT_Admin and the (disabled) built-in admin may be in
#      local Administrators. Hard-fail otherwise -- the whole posture depends
#      on Level 0-3 being standard users.
#
# Edit $bannerCaption/$bannerText and the policy values to match your SOP.

$ErrorActionPreference = 'Stop'

$root    = 'C:\ProgramData\ManualClonezilla'
$logDir  = Join-Path $root 'Logs'
$logFile = Join-Path $logDir 'Apply-StigHardening.log'

$policyKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$adminUser  = 'IT_Admin'
$guestNewName = 'xGuestDisabled'

$bannerCaption = 'Authorized Use Only'
$bannerText    = 'This system is for authorized users only. Activity may be monitored and recorded. Use of this system constitutes consent to monitoring.'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
try { Start-Transcript -Path $logFile -Append | Out-Null }
catch { Write-Warning "Could not start transcript: $($_.Exception.Message)" }

function Set-PolicyDword {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Value)
    if (-not (Test-Path -LiteralPath $policyKey)) {
        New-Item -Path $policyKey -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $policyKey -Name $Name -Value $Value -Type DWord
}

function Set-PolicyString {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    Set-ItemProperty -LiteralPath $policyKey -Name $Name -Value $Value -Type String
}

try {
    # --- 1. Built-in Guest (RID 501) -------------------------------------
    $guest = Get-LocalUser | Where-Object { $_.SID.Value -like 'S-1-5-*-501' } | Select-Object -First 1
    if ($guest) {
        Disable-LocalUser -Name $guest.Name
        Write-Host 'Built-in Guest account disabled.'
        if ($guest.Name -eq 'Guest') {
            Rename-LocalUser -Name $guest.Name -NewName $guestNewName
            Write-Host 'Built-in Guest account renamed.'
        } else {
            Write-Host 'Built-in Guest already renamed; leaving as-is.'
        }
    } else {
        Write-Warning 'Built-in Guest account (RID 501) not found.'
    }

    # --- 2. Password + lockout policy (secedit) --------------------------
    $inf = Join-Path $logDir 'stig-secpol.inf'
    $sdb = Join-Path $logDir 'stig-secpol.sdb'
    $infBody = @"
[Unicode]
Unicode=yes
[System Access]
MinimumPasswordLength = 14
PasswordComplexity = 1
MaximumPasswordAge = 60
MinimumPasswordAge = 1
PasswordHistorySize = 24
LockoutBadCount = 3
ResetLockoutCount = 15
LockoutDuration = 15
[Version]
signature="`$CHICAGO`$"
Revision=1
"@
    Set-Content -LiteralPath $inf -Value $infBody -Encoding Unicode
    & secedit.exe /configure /db "$sdb" /cfg "$inf" /areas SECURITYPOLICY | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "secedit failed to apply password/lockout policy (exit $LASTEXITCODE)."
    }
    Remove-Item -LiteralPath $inf, $sdb -Force -ErrorAction SilentlyContinue
    Write-Host 'Password and account-lockout policy applied.'

    # --- 3. UAC ----------------------------------------------------------
    Set-PolicyDword -Name 'EnableLUA' -Value 1
    Set-PolicyDword -Name 'ConsentPromptBehaviorAdmin' -Value 2
    Set-PolicyDword -Name 'PromptOnSecureDesktop' -Value 1
    Set-PolicyDword -Name 'FilterAdministratorToken' -Value 1
    Write-Host 'UAC policy applied (EnableLUA, secure-desktop consent, FilterAdministratorToken).'

    # --- 4. Windows Firewall (best-effort) -------------------------------
    try {
        Set-NetFirewallProfile -All -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Allow -ErrorAction Stop
        Write-Host 'Firewall: all profiles enabled, default inbound block.'
    } catch {
        Write-Warning "Could not set firewall profiles: $($_.Exception.Message)"
    }

    # --- 5. Logon banner + last-user-name --------------------------------
    Set-PolicyString -Name 'LegalNoticeCaption' -Value $bannerCaption
    Set-PolicyString -Name 'LegalNoticeText' -Value $bannerText
    Set-PolicyDword  -Name 'DontDisplayLastUserName' -Value 1
    Write-Host 'Logon banner and DontDisplayLastUserName applied.'

    # --- 6. Administrators-group assertion -------------------------------
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

    Write-Host 'STIG hardening completed.'
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
