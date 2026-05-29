# Set-Level0ACL.ps1
# Locks the 'Level 0' account out of the restricted folders. Applies an
# inherited Deny (Full) ACE so Level 0 can neither see (list/read) nor
# modify the targets. Other accounts are unaffected (Deny is scoped to the
# Level 0 principal only).
#
# Idempotent: removes any prior Deny ACE for the account before re-adding,
# so re-running does not stack duplicate ACEs.
#
# A missing target folder is a staging warning, not a hard failure -- the
# folder may legitimately not exist on every hardware family. The account
# itself must exist (New-LocalAccounts.ps1 runs first); if it does not we
# hard-fail, because a silently un-applied lockdown is a security gap.

$ErrorActionPreference = 'Stop'

$root    = 'C:\ProgramData\ManualClonezilla'
$logDir  = Join-Path $root 'Logs'
$logFile = Join-Path $logDir 'Set-Level0ACL.log'

$account = 'Level 0'
$targets = @(
    'C:\Programs',
    'C:\Users\Public\Desktop\Quick Links'
)

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
try { Start-Transcript -Path $logFile -Append | Out-Null }
catch { Write-Warning "Could not start transcript: $($_.Exception.Message)" }

try {
    if (-not (Get-LocalUser -Name $account -ErrorAction SilentlyContinue)) {
        throw "Account '$account' does not exist; cannot apply lockdown ACLs. New-LocalAccounts.ps1 must run first."
    }

    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target)) {
            Write-Warning "Target not found, skipping: $target (folder is not present on this image)."
            continue
        }

        Write-Host "Applying Deny (Full) for '$account' on: $target"

        # Drop any existing Deny ACE for this account first (idempotency).
        & icacls.exe "$target" /remove:d "$account" | Out-Null

        # (OI)(CI)F = Object + Container inherit, Full control, Denied.
        & icacls.exe "$target" /deny "${account}:(OI)(CI)F" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "icacls failed to set Deny ACE on '$target' (exit $LASTEXITCODE)."
        }
    }

    Write-Host 'Level 0 lockdown ACLs applied.'
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
