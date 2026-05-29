# New-LocalAccounts.ps1
# First-boot account provisioning. Creates the fleet's named local accounts
# from Config\accounts.csv. Standard users go in the local Users group; the
# admin account goes in local Administrators. Idempotent: existing accounts
# have their password reset and group membership re-asserted.
#
# accounts.csv schema (header row required):
#   Username,Password,Role
#   Level 0,<pw>,Standard
#   IT_Admin,<pw>,Admin
#
# Passwords are plaintext by design (same trust model as bitlocker-pin.txt).
# Finalize-Cleanup.ps1 deletes accounts.csv after this runs.

$ErrorActionPreference = 'Stop'

$root        = 'C:\ProgramData\ManualClonezilla'
$logDir      = Join-Path $root 'Logs'
$configDir   = Join-Path $root 'Config'
$logFile     = Join-Path $logDir 'New-LocalAccounts.log'
$accountsCsv = Join-Path $configDir 'accounts.csv'

# Resolve built-in groups by well-known SID so we are not locale-dependent.
$adminsGroupSid = 'S-1-5-32-544'
$usersGroupSid  = 'S-1-5-32-545'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
try { Start-Transcript -Path $logFile -Append | Out-Null }
catch { Write-Warning "Could not start transcript: $($_.Exception.Message)" }

function Resolve-GroupName {
    param([Parameter(Mandatory)] [string]$Sid)
    $g = Get-LocalGroup -SID $Sid -ErrorAction Stop
    return $g.Name
}

function Set-GroupMembership {
    param(
        [Parameter(Mandatory)] [string]$GroupName,
        [Parameter(Mandatory)] [string]$Member
    )
    # Match on the fully-qualified local name with -eq (not a -like pattern,
    # which would treat brackets/wildcards in $Member as pattern syntax).
    # Get-LocalGroupMember can THROW on an unresolvable/orphaned member SID,
    # so guard it and fall through to the Add (whose "already a member"
    # error we treat as benign for idempotency).
    $qualified = "$env:COMPUTERNAME\$Member"
    try {
        $existing = Get-LocalGroupMember -Group $GroupName -ErrorAction Stop |
            Where-Object { $_.Name -eq $qualified -or $_.Name -eq $Member }
        if ($existing) {
            Write-Host "  '$Member' already in '$GroupName'."
            return
        }
    } catch {
        Write-Warning "  Could not enumerate '$GroupName' membership: $($_.Exception.Message)"
    }
    try {
        Add-LocalGroupMember -Group $GroupName -Member $Member -ErrorAction Stop
        Write-Host "  Added '$Member' to '$GroupName'."
    } catch {
        if ($_.Exception.Message -match 'already a member') {
            Write-Host "  '$Member' already in '$GroupName' (add reported existing)."
        } else {
            throw
        }
    }
}

try {
    if (-not (Test-Path -LiteralPath $accountsCsv)) {
        throw "Accounts file not found: $accountsCsv. Stage the gold image with this CSV (Username,Password,Role) before sysprep."
    }

    $adminsGroup = Resolve-GroupName -Sid $adminsGroupSid
    $usersGroup  = Resolve-GroupName -Sid $usersGroupSid

    $rows = Import-Csv -LiteralPath $accountsCsv
    if (-not $rows) {
        throw "Accounts file $accountsCsv is empty or has no data rows."
    }

    foreach ($row in $rows) {
        $name = ($row.Username).Trim()
        $pw   = $row.Password
        $role = ($row.Role).Trim()

        if ([string]::IsNullOrWhiteSpace($name)) {
            throw 'Encountered a row with an empty Username; refusing to continue.'
        }
        if ([string]::IsNullOrWhiteSpace($pw)) {
            throw "Account '$name' has an empty Password; refusing to create a passwordless account."
        }
        if ($role -ne 'Admin' -and $role -ne 'Standard') {
            throw "Account '$name' has invalid Role '$role'; expected 'Admin' or 'Standard'."
        }

        $secure = ConvertTo-SecureString -String $pw -AsPlainText -Force

        if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) {
            Write-Host "Account '$name' exists; resetting password, re-enabling, re-asserting membership."
            Set-LocalUser -Name $name -Password $secure -PasswordNeverExpires $true
            Enable-LocalUser -Name $name
        } else {
            Write-Host "Creating account '$name' (Role=$role)."
            New-LocalUser -Name $name `
                          -Password $secure `
                          -FullName $name `
                          -PasswordNeverExpires `
                          -AccountNeverExpires `
                          -ErrorAction Stop | Out-Null
        }

        if ($role -eq 'Admin') {
            Set-GroupMembership -GroupName $adminsGroup -Member $name
        } else {
            Set-GroupMembership -GroupName $usersGroup -Member $name
        }
    }

    Write-Host 'Local account provisioning completed.'
}
finally {
    Stop-Transcript
}
