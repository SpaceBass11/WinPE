# Stage-DockerData.ps1
# Pre-seeds the Docker Desktop WSL *data* disk (docker_data.vhdx -- the
# persistent images/volumes/container-layer store) into the Level 1 account's
# profile, so a freshly deployed machine comes up with the gold's Docker data
# already in place.
#
# Why this runs at deploy time (not baked into the gold): the gold is built
# and sysprepped as the built-in Administrator only (one profile -> reliable
# /generalize). The Level accounts are created fresh on first boot by
# New-LocalAccounts.ps1, so Level 1's profile does NOT exist yet when this
# runs. A bare "mkdir C:\Users\Level 1\..." would not work: the Profile
# Service has no ProfileList entry for the SID, so on Level 1's first logon it
# would sidestep the orphaned folder and create "Level 1.000" instead, and
# Docker (running as Level 1) would never see the seeded disk.
#
# Instead we call the Win32 CreateProfile API (userenv.dll) -- the supported
# "create a registered profile for this SID, seeded from Default, before the
# user ever logs in" call that provisioning tools use. That yields a real,
# ProfileList-registered C:\Users\Level 1, into which we drop the data disk.
# Because Level 1 has never logged in, Docker has never started as Level 1, so
# the .vhdx is not locked -- no wsl --shutdown / stop-service dance needed.
#
# NON-FATAL by design (always exits 0): a missing or failed Docker payload
# must never abort the security chain (BitLocker etc.). Same posture as
# Install-NotepadPP.ps1.
#
# OPEN VALIDATION (see RUNBOOK "Docker data disk"): this PRE-SEEDS the disk
# before Docker's first run for Level 1. The confirmed-working behavior is
# OVERWRITING an already-present disk; whether Docker ADOPTS a pre-placed disk
# on first launch (vs. recreating an empty one) must be bench-tested. If Docker
# stomps the pre-seed, fall back to a Level-1 first-logon overwrite task.

$ErrorActionPreference = 'Stop'

$root      = 'C:\ProgramData\ManualClonezilla'
$logDir    = Join-Path $root 'Logs'
$stateDir  = Join-Path $root 'State'
$logFile   = Join-Path $logDir 'Stage-DockerData.log'
$srcVhdx   = Join-Path $root 'Payload\docker_data.vhdx'
$stateFile = Join-Path $stateDir 'docker-data.staged.sha256'

# Account whose profile receives the data disk, and the data-disk location
# relative to that profile (Docker Desktop WSL2 backend default path).
$targetUser   = 'Level 1'
$relTargetDir = 'AppData\Local\Docker\wsl\disk'
$vhdxName     = 'docker_data.vhdx'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
try { Start-Transcript -Path $logFile -Append | Out-Null }
catch { Write-Warning "Could not start transcript: $($_.Exception.Message)" }

try {
    if (-not (Test-Path -LiteralPath $srcVhdx)) {
        Write-Host "No Docker payload staged at $srcVhdx; nothing to do."
        return
    }

    # Idempotent: skip if the current payload is already staged.
    $srcHash = (Get-FileHash -Path $srcVhdx -Algorithm SHA256).Hash
    if ((Test-Path $stateFile) -and ((Get-Content -Path $stateFile -Raw).Trim() -eq $srcHash)) {
        Write-Host 'Docker data disk for current payload hash already staged; skipping.'
        return
    }

    $user = Get-LocalUser -Name $targetUser -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Warning "Account '$targetUser' not found; skipping Docker data staging."
        return
    }
    $sid = $user.SID.Value

    # Win32 CreateProfile (userenv.dll): create a real, ProfileList-registered
    # profile for this SID (seeded from Default) if one does not already exist.
    if (-not ([System.Management.Automation.PSTypeName]'ManualClonezilla.ProfileApi').Type) {
        Add-Type -Namespace 'ManualClonezilla' -Name 'ProfileApi' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("userenv.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, ExactSpelling = true)]
public static extern int CreateProfile(
    [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string pszUserSid,
    [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string pszUserName,
    [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] System.Text.StringBuilder pszProfilePath,
    uint cchProfilePath);
'@
    }

    $profileListKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
    $profilePath = $null

    $sb = New-Object System.Text.StringBuilder 260
    $hr = [ManualClonezilla.ProfileApi]::CreateProfile($sid, $targetUser, $sb, $sb.Capacity)

    # S_OK (0) -> created. 0x800700B7 (HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS),
    # i.e. -2147024713 as a signed int) -> profile already registered; resolve
    # its path from ProfileList instead.
    if ($hr -eq 0) {
        $profilePath = $sb.ToString()
        Write-Host "Created registered profile for '$targetUser' at $profilePath."
    } elseif ($hr -eq -2147024713) {
        if (Test-Path -LiteralPath $profileListKey) {
            $raw = (Get-ItemProperty -Path $profileListKey -Name 'ProfileImagePath').ProfileImagePath
            $profilePath = [Environment]::ExpandEnvironmentVariables($raw)
            Write-Host "Profile for '$targetUser' already exists at $profilePath."
        } else {
            throw "CreateProfile reported an existing profile, but ProfileList entry for $sid is missing."
        }
    } else {
        throw ("CreateProfile failed (HRESULT 0x{0:X8})." -f $hr)
    }

    if ((-not $profilePath) -or (-not (Test-Path -LiteralPath $profilePath))) {
        throw "Resolved profile path is missing: '$profilePath'."
    }

    $destDir  = Join-Path $profilePath $relTargetDir
    $destVhdx = Join-Path $destDir $vhdxName
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null

    Copy-Item -LiteralPath $srcVhdx -Destination $destVhdx -Force
    Write-Host "Staged Docker data disk to $destVhdx."

    Set-Content -Path $stateFile -Value $srcHash -Encoding Ascii
    Write-Host 'Docker data staging completed.'
}
catch {
    # Non-fatal: log and swallow so the security chain continues regardless.
    Write-Warning "Docker data staging failed (non-fatal): $($_.Exception.Message)"
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}

# Non-fatal contract: never surface a failure exit code to SetupComplete.
exit 0
