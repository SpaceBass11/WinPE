# Harden-Administrator.ps1
# STIG hardening of the built-in local Administrator account:
#   1. Set a long random password (the audit-mode password must not survive).
#   2. Disable the account.
#   3. Rename it away from "Administrator".
#
# The built-in account is identified by its well-known RID (SID ends in
# -500), never by name -- so this stays correct even if a prior run already
# renamed it. Idempotent: re-running re-asserts disabled state and leaves an
# already-renamed account alone.
#
# IT_Admin (created by New-LocalAccounts.ps1) is the human admin going
# forward; the built-in account is retired.

$ErrorActionPreference = 'Stop'

$root    = 'C:\ProgramData\ManualClonezilla'
$logDir  = Join-Path $root 'Logs'
$logFile = Join-Path $logDir 'Harden-Administrator.log'

# STIG requires the built-in Administrator not be named "Administrator".
# A predictable rename (e.g. "DisabledAdmin") is weak, so we generate a
# non-obvious name: a fixed letter prefix + random alphanumeric suffix
# (e.g. "xK7v9QpL2mTz"). The prefix keeps the name starting with a letter
# and gives you something greppable; edit it to suit your SOP. The account
# is found by RID 500, not by name, so the randomness costs nothing.
$renamePrefix = 'x'
$renameSuffixLength = 12

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
try { Start-Transcript -Path $logFile -Append | Out-Null }
catch { Write-Warning "Could not start transcript: $($_.Exception.Message)" }

function New-RandomName {
    param([int]$Length = 12)
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $sb = New-Object System.Text.StringBuilder
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object 'System.Byte[]' 1
    for ($i = 0; $i -lt $Length; $i++) {
        $rng.GetBytes($bytes)
        [void]$sb.Append($chars[[int]($bytes[0] % $chars.Length)])
    }
    return $sb.ToString()
}

function New-RandomPassword {
    param([int]$Length = 32)
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    try {
        return [System.Web.Security.Membership]::GeneratePassword($Length, 8)
    } catch {
        # Fallback if System.Web is unavailable.
        $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+'
        $sb = New-Object System.Text.StringBuilder
        $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
        $bytes = New-Object 'System.Byte[]' 1
        for ($i = 0; $i -lt $Length; $i++) {
            $rng.GetBytes($bytes)
            [void]$sb.Append($chars[[int]($bytes[0] % $chars.Length)])
        }
        return $sb.ToString()
    }
}

try {
    $builtin = Get-LocalUser | Where-Object { $_.SID.Value -like 'S-1-5-*-500' } | Select-Object -First 1
    if (-not $builtin) {
        throw 'Could not locate the built-in Administrator account (RID 500).'
    }
    # Log by SID only -- never write the account name to the transcript. The
    # log lives in a Users-readable dir; printing the (random) renamed name
    # would undo the point of randomizing it.
    Write-Host "Built-in admin account located by RID 500 (SID $($builtin.SID.Value))."

    # 1. Disable FIRST, so that if the password rotation below throws (e.g. a
    #    complexity-policy edge case) the account is still left disabled
    #    rather than enabled with the audit-mode password.
    Disable-LocalUser -Name $builtin.Name
    Write-Host 'Built-in admin account disabled.'

    # 2. Rotate the password off the audit-mode value.
    $pw = New-RandomPassword -Length 32
    $secure = ConvertTo-SecureString -String $pw -AsPlainText -Force
    Set-LocalUser -Name $builtin.Name -Password $secure
    Remove-Variable pw -ErrorAction SilentlyContinue
    Write-Host 'Built-in admin password rotated to a random value.'

    # 3. Rename off "Administrator" (skip if a prior run already did it).
    if ($builtin.Name -eq 'Administrator') {
        $newName = $renamePrefix + (New-RandomName -Length $renameSuffixLength)
        Rename-LocalUser -Name $builtin.Name -NewName $newName
        Write-Host 'Built-in admin renamed off "Administrator".'
    } else {
        Write-Host 'Built-in admin already renamed (not default); leaving as-is.'
    }

    Write-Host 'Built-in Administrator hardening completed.'
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
