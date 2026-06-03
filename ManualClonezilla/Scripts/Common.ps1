# Common.ps1
# Pure, cross-platform helper functions shared by the first-boot scripts.
# Dot-sourced at the top of the scripts that use them
# (. (Join-Path $PSScriptRoot 'Common.ps1')). Defines functions only -- no
# top-level side effects -- so it is safe to dot-source from a runtime script
# or from a Pester test on any platform.

function New-RandomName {
    # Random alphanumeric string (letters + digits). Used to rename the
    # built-in Administrator/Guest off their default names.
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
    # Strong random password. Prefers System.Web's generator (Windows
    # PowerShell), falls back to an RNG-built string if System.Web is absent.
    param([int]$Length = 32)
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    try {
        return [System.Web.Security.Membership]::GeneratePassword($Length, 8)
    } catch {
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

function New-RecoveryKeyFileName {
    # Builds the per-host BitLocker recovery key filename.
    param(
        [Parameter(Mandatory)] [string]$ComputerName,
        [Parameter(Mandatory)] [string]$Stamp
    )
    return ("BitLocker-RecoveryKey-{0}-{1}.txt" -f $ComputerName, $Stamp)
}

function Test-AccountRow {
    # Validates one accounts.csv row. Throws on invalid input; returns $true
    # when the row is well-formed. Role must be 'Admin' or 'Standard'.
    param(
        [string]$Username,
        [string]$Password,
        [string]$Role
    )
    if ([string]::IsNullOrWhiteSpace($Username)) {
        throw 'Encountered a row with an empty Username; refusing to continue.'
    }
    if ([string]::IsNullOrWhiteSpace($Password)) {
        throw "Account '$Username' has an empty Password; refusing to create a passwordless account."
    }
    if ($Role -ne 'Admin' -and $Role -ne 'Standard') {
        throw "Account '$Username' has invalid Role '$Role'; expected 'Admin' or 'Standard'."
    }
    return $true
}
