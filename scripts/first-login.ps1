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

    Why HKCU rather than HKLM/DefaultUser:
      Some Windows settings live in the per-user hive that's only created
      when a real user signs in. Setting them in DefaultUser at WIM-prep
      time works for some keys but is silently ignored for others (the
      "ContentDeliveryManager" SubscribedContent-* values are a common
      example). Running here, in the actual user's session, sidesteps
      that whole class of "I set the key but Windows ignored it" bugs.

    This is a one-shot. It logs to C:\Windows\Setup\Scripts\first-login.log.

.NOTES
    Designed to be safe to re-run. Each tweak is idempotent.
#>

$ErrorActionPreference = 'Continue'   # don't abort the whole login on one bad key
$logFile = "$env:WinDir\Setup\Scripts\first-login.log"

function Log {
    param([string]$msg)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

function Set-HKCU {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [ValidateSet('DWORD','String')] [string]$Type = 'DWORD',
        [string]$Label
    )
    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Log "  OK  $Label"
    } catch {
        Log "  ERR $Label - $($_.Exception.Message)"
    }
}

Log "first-login.ps1 starting for user '$env:USERNAME'"

# ─── Explorer / file UI ─────────────────────────────────────────────
$advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-HKCU -Path $advanced -Name 'HideFileExt'      -Value 0 -Label 'Show file extensions'
Set-HKCU -Path $advanced -Name 'UseCompactMode'   -Value 1 -Label 'Compact view in File Explorer'
Set-HKCU -Path $advanced -Name 'TaskbarDa'        -Value 0 -Label 'Hide taskbar Widgets icon'
Set-HKCU -Path $advanced -Name 'TaskbarMn'        -Value 0 -Label 'Hide taskbar Chat icon'
Set-HKCU -Path $advanced -Name 'TaskbarEndTask'   -Value 1 -Label 'Enable "End task" in taskbar right-click'

# Search box → icon-only (1 = icon, 2 = box, 3 = box+icon)
Set-HKCU -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' `
         -Name 'SearchboxTaskbarMode' -Value 1 -Label 'Taskbar search: icon only (no big box)'

# Bing in Start-menu search (per-user complement to the HKLM policy)
Set-HKCU -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' `
         -Name 'BingSearchEnabled' -Value 0 -Label 'Start-menu Bing search off (per-user)'

# ─── Suggested apps / promoted content in Start menu ──────────────
# Microsoft uses many parallel SubscribedContent-* keys for different ad
# slots. Turning the four most prominent off catches the visible bloat.
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
foreach ($pair in @(
    @('SubscribedContent-338388Enabled', 'Start: suggested apps off'),
    @('SubscribedContent-338389Enabled', 'Settings: suggestions off'),
    @('SubscribedContent-338393Enabled', 'Settings → System: suggestions off'),
    @('SubscribedContent-353694Enabled', 'Settings → Devices: suggestions off'),
    @('SubscribedContent-353696Enabled', 'Settings → Network: suggestions off'),
    @('SilentInstalledAppsEnabled',      'Silent app auto-install off'),
    @('SystemPaneSuggestionsEnabled',    'System pane suggestions off')
)) {
    Set-HKCU -Path $cdm -Name $pair[0] -Value 0 -Label $pair[1]
}

# ─── Windows 11 classic right-click menu (no "Show more options") ──
# Adds an empty InprocServer32 default value for the new-shell-menu CLSID,
# which causes Explorer to fall through to the classic menu.
$clsidPath = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
try {
    New-Item -Path $clsidPath -Force | Out-Null
    Set-ItemProperty -Path $clsidPath -Name '(Default)' -Value '' -Force
    Log "  OK  Classic right-click menu (no 'Show more options')"
} catch {
    Log "  ERR Classic right-click menu - $($_.Exception.Message)"
}

# ─── OneDrive: uninstall the per-user setup that runs on first sign-in ─
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

# ─── Restart explorer.exe so taskbar changes take effect ───────────
try {
    Stop-Process -Name 'explorer' -Force -ErrorAction SilentlyContinue
    # Windows auto-relaunches explorer; no manual Start-Process needed
    Log "  OK  explorer.exe restarted (taskbar changes applied)"
} catch {
    Log "  ERR explorer restart - $($_.Exception.Message)"
}

Log "first-login.ps1 complete"
