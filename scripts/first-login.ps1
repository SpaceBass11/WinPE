<#
.SYNOPSIS
    Per-user (HKCU) debloat + UX tweaks. Runs once on first sign-in.

.DESCRIPTION
    Companion to `prepare_wim.ps1 -DisableExtraBloat`, which stages this
    file into the image at C:\Windows\Setup\Scripts\first-login.ps1.

    An unattend.xml `FirstLogonCommands` entry should call it:

      <SynchronousCommand wcm:action="add">
        <Order>1</Order>
        <CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\first-login.ps1</CommandLine>
      </SynchronousCommand>

    Applies the tweak list to TWO targets in one pass:

      1. The currently logged-in user (HKCU live hive). This is whoever
         was named in unattend's <AutoLogon> — typically the maintenance
         admin (e.g. DERP_Admin). Their profile gets the tweaks now.

      2. The Default User hive (C:\Users\Default\NTUSER.DAT). This is
         the template Windows clones when ANY new user logs in for the
         first time. So Level0 / Level1 / Level2 / future users all
         inherit the same tweaks when their profile is created on first
         logon — without needing this script to re-run per user.

    OneDrive uninstall and the explorer.exe restart are per-current-user
    only (they need a live profile to act on). The HKCU-style tweaks
    cover the rest.

    Each tweak is idempotent. Logs to C:\Windows\Setup\Scripts\first-login.log.

.NOTES
    Safe to re-run. Failures in individual tweaks are logged but don't
    abort the script — every tweak gets its shot.
#>

$ErrorActionPreference = 'Continue'
$logFile = "$env:WinDir\Setup\Scripts\first-login.log"

function Log {
    param([string]$msg)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------
# Tweak list — applied to both current HKCU and Default User hive.
# 'Path' uses '{root}' which gets substituted at apply time:
#   - 'HKCU:'            for the currently logged-in user
#   - 'HKLM:\WimDefault' for the mounted Default User hive
# ---------------------------------------------------------------------
$tweaks = @(
    # ── Explorer / file UI ─────────────────────────────────────────
    @{ Path='{root}\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='HideFileExt';    Value=0; Type='DWord'; Label='Show file extensions' },
    @{ Path='{root}\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='UseCompactMode'; Value=1; Type='DWord'; Label='Compact view in File Explorer' },
    @{ Path='{root}\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='TaskbarDa';      Value=0; Type='DWord'; Label='Hide taskbar Widgets icon' },
    @{ Path='{root}\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='TaskbarMn';      Value=0; Type='DWord'; Label='Hide taskbar Chat icon' },
    @{ Path='{root}\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='TaskbarEndTask'; Value=1; Type='DWord'; Label='Enable "End task" in taskbar right-click' },

    # ── Taskbar search → icon only ────────────────────────────────
    @{ Path='{root}\Software\Microsoft\Windows\CurrentVersion\Search'; Name='SearchboxTaskbarMode'; Value=1; Type='DWord'; Label='Taskbar search: icon only (no big box)' },
    @{ Path='{root}\Software\Microsoft\Windows\CurrentVersion\Search'; Name='BingSearchEnabled';    Value=0; Type='DWord'; Label='Start-menu Bing search off (per-user)' },

    # ── Suggested apps / promoted content (ContentDeliveryManager) ─
    @{ Path='{root}\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338388Enabled'; Value=0; Type='DWord'; Label='Start: suggested apps off' },
    @{ Path='{root}\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338389Enabled'; Value=0; Type='DWord'; Label='Settings: suggestions off' },
    @{ Path='{root}\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338393Enabled'; Value=0; Type='DWord'; Label='Settings → System: suggestions off' },
    @{ Path='{root}\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-353694Enabled'; Value=0; Type='DWord'; Label='Settings → Devices: suggestions off' },
    @{ Path='{root}\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-353696Enabled'; Value=0; Type='DWord'; Label='Settings → Network: suggestions off' },
    @{ Path='{root}\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SilentInstalledAppsEnabled';      Value=0; Type='DWord'; Label='Silent app auto-install off' },
    @{ Path='{root}\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SystemPaneSuggestionsEnabled';    Value=0; Type='DWord'; Label='System pane suggestions off' },

    # ── Windows 11 classic right-click menu (no "Show more options") ─
    # The trick is to set an EMPTY (Default) string value on the
    # InprocServer32 subkey of the "new-shell-menu" CLSID — that
    # causes Explorer to fall through to the classic menu.
    @{ Path='{root}\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'; Name='(Default)'; Value=''; Type='String'; Label='Classic right-click menu (no "Show more options")' }
)

function Apply-Tweak {
    param(
        [string]$Root,
        [hashtable]$Tweak
    )
    $path = $Tweak.Path -replace '\{root\}', $Root
    try {
        if (-not (Test-Path $path)) {
            New-Item -Path $path -Force | Out-Null
        }
        if ($Tweak.Name -eq '(Default)') {
            # (Default) value is set differently than named values
            Set-ItemProperty -Path $path -Name '(Default)' -Value $Tweak.Value -Force
        } else {
            New-ItemProperty -Path $path -Name $Tweak.Name -Value $Tweak.Value -PropertyType $Tweak.Type -Force | Out-Null
        }
        Log "  OK  $($Tweak.Label)"
    } catch {
        Log "  ERR $($Tweak.Label) - $($_.Exception.Message)"
    }
}

Log "first-login.ps1 starting for user '$env:USERNAME'"

# ---------------------------------------------------------------------
# Pass 1 — current user (HKCU)
# ---------------------------------------------------------------------
Log "Applying tweaks to current user (HKCU)..."
foreach ($t in $tweaks) {
    Apply-Tweak -Root 'HKCU:' -Tweak $t
}

# ---------------------------------------------------------------------
# Pass 2 — Default User hive, so future logins inherit the tweaks
# ---------------------------------------------------------------------
$defaultHive = "$env:SystemDrive\Users\Default\NTUSER.DAT"
$mountKey    = 'WimDefault'
$mountPath   = "HKLM\$mountKey"

if (Test-Path $defaultHive) {
    Log "Mounting Default User hive ($defaultHive)..."
    & reg.exe load $mountPath $defaultHive 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        try {
            Log "Applying tweaks to Default User hive..."
            foreach ($t in $tweaks) {
                Apply-Tweak -Root "HKLM:\$mountKey" -Tweak $t
            }
        } finally {
            # PowerShell holds onto registry handles past the last property
            # access — force a collect before unload or reg.exe complains.
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            & reg.exe unload $mountPath 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Log "Default User hive unmounted cleanly."
            } else {
                Log "  WARN Default User hive unload returned $LASTEXITCODE (handles still open). Tweaks were applied but the hive file may not flush until reboot."
            }
        }
    } else {
        Log "  ERR Default User hive load failed (exit $LASTEXITCODE) — future users won't inherit tweaks"
    }
} else {
    Log "  WARN Default User hive not found at $defaultHive — skipping Default User pass"
}

# ---------------------------------------------------------------------
# OneDrive: uninstall the per-user setup that runs on first sign-in.
# This is current-user only — Default User can't run an installer.
# ---------------------------------------------------------------------
$oneDriveUninstaller = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
if (-not (Test-Path $oneDriveUninstaller)) {
    $oneDriveUninstaller = "$env:SystemRoot\System32\OneDriveSetup.exe"
}
if (Test-Path $oneDriveUninstaller) {
    try {
        Stop-Process -Name 'OneDrive' -Force -ErrorAction SilentlyContinue
        Start-Process -FilePath $oneDriveUninstaller -ArgumentList '/uninstall' -Wait -NoNewWindow
        Log "  OK  OneDrive uninstalled (per-user)"
    } catch {
        Log "  ERR OneDrive uninstall - $($_.Exception.Message)"
    }
} else {
    Log "  --  OneDrive setup not found (already removed or different SKU)"
}

# ---------------------------------------------------------------------
# Restart explorer.exe so taskbar / Explorer changes take effect now.
# ---------------------------------------------------------------------
try {
    Stop-Process -Name 'explorer' -Force -ErrorAction SilentlyContinue
    # Windows auto-relaunches explorer; no Start-Process needed.
    Log "  OK  explorer.exe restarted (taskbar changes applied)"
} catch {
    Log "  ERR explorer restart - $($_.Exception.Message)"
}

Log "first-login.ps1 complete"
