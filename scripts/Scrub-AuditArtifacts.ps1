# Scrub-AuditArtifacts.ps1
# Removes secrets that the audit-mode build + sysprep leave behind on the
# deployed machine. These can persist plaintext credentials that any local
# user can read, and would undo Harden-Administrator.ps1.
#
#   1. Winlogon autologon values (AutoAdminLogon / DefaultPassword /
#      DefaultUserName / DefaultDomainName) -- audit mode and Hyper-V
#      enhanced-session builds commonly set these; DefaultPassword is
#      plaintext.
#   2. Processed answer files Windows copies to disk
#      (C:\Windows\Panther\unattend.xml, the Panther\unattend folder, and the
#      Sysprep Panther copy) -- these can contain the AdministratorPassword /
#      AutoLogon blocks an admin added to reach audit mode.
#
# Runs early in the chain so secrets are gone before anything else. Idempotent:
# missing values/files are a no-op.

$ErrorActionPreference = 'Stop'

$root    = 'C:\ProgramData\ManualClonezilla'
$logDir  = Join-Path $root 'Logs'
$logFile = Join-Path $logDir 'Scrub-AuditArtifacts.log'

$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$answerFiles = @(
    'C:\Windows\Panther\unattend.xml',
    'C:\Windows\System32\Sysprep\Panther\unattend.xml',
    'C:\Windows\System32\Sysprep\unattend.xml'
)
$answerDirs = @(
    'C:\Windows\Panther\unattend'
)

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
try { Start-Transcript -Path $logFile -Append | Out-Null }
catch { Write-Warning "Could not start transcript: $($_.Exception.Message)" }

try {
    # 1. Winlogon autologon scrub.
    # Force AutoAdminLogon off, then strip the cleartext credential values.
    if (Test-Path -LiteralPath $winlogon) {
        Set-ItemProperty -LiteralPath $winlogon -Name 'AutoAdminLogon' -Value '0' -Type String
        Write-Host 'Set AutoAdminLogon = 0.'
        foreach ($name in 'DefaultPassword', 'DefaultUserName', 'DefaultDomainName', 'AutoLogonCount') {
            $prop = Get-ItemProperty -LiteralPath $winlogon -Name $name -ErrorAction SilentlyContinue
            if ($null -ne $prop) {
                Remove-ItemProperty -LiteralPath $winlogon -Name $name -ErrorAction SilentlyContinue
                Write-Host "Removed Winlogon value '$name'."
            }
        }
    }

    # 2. Processed answer files.
    foreach ($file in $answerFiles) {
        if (Test-Path -LiteralPath $file) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            Write-Host "Removed answer file $file"
        }
    }
    foreach ($dir in $answerDirs) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Removed answer dir $dir"
        }
    }

    Write-Host 'Audit-mode artifact scrub completed.'
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
