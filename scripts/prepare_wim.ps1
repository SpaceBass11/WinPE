#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prepare a customized Windows install.wim for deployment.

.DESCRIPTION
    Companion to unified_winpe_deploy.ps1. Takes either:
      - a stock Windows ISO (via -SourceIso, the original use case), or
      - an already-captured WIM (via -SourceWim, e.g. one you made with
        `Dism /Capture-Image` from a reference machine)
    and produces a debloated, customized WIM ready to drop on the USB
    IMAGES partition. The post-source flow is identical in both modes:
    pick the index, mount the WIM, remove non-whitelisted provisioned
    AppX packages, optionally apply registry tweaks, optionally inject
    drivers, and re-export with /Compress:max + /CheckIntegrity.

    Whitelist-based debloat is intentional - blacklist approaches miss new
    bloat that Microsoft adds in each release. Edit -Whitelist (or pass
    -WhitelistFile) to suit your environment.

    All mounts wrap in try/finally and discard on mid-script failure rather
    than leaving an orphaned mount.

.PARAMETER SourceIso
    Path to the Windows installation ISO (the one with sources\install.wim
    or sources\install.esd). Use this OR -SourceWim, not both.

.PARAMETER SourceWim
    Path to an already-captured `.wim` file. Use this when your starting
    point is a captured reference image (e.g. you ran
    `Dism /Capture-Image /CaptureDir:C:\ /ImageFile:golden.wim ...`).
    Use this OR -SourceIso, not both. The source file is copied to a
    working location, never modified in place.

.PARAMETER OutputWim
    Where to write the customized WIM. Required.

.PARAMETER Edition
    Edition name to pick from the source — as DISM reports it, e.g.
    'Windows 11 Enterprise', 'Windows 11 Pro'. Default:
    'Windows 11 Enterprise'. Only relevant if the source has multiple
    indexes with named editions. Run `Get-WindowsImage -ImagePath <wim>`
    to see available names. Ignored if -Index is given.

.PARAMETER Index
    Numeric index to pick from the source (overrides -Edition).
    Useful for captured WIMs that don't use standard edition names, or
    when you want to be explicit. Honored for ISOs containing either
    install.wim or install.esd, and for -SourceWim. If neither -Edition
    nor -Index is given and the source is a captured WIM, defaults to
    index 1.

.PARAMETER WorkDir
    Temporary working directory for ISO mount, WIM mount, and scratch.
    Default: C:\WimPrep. Created if missing, NOT deleted afterwards
    (re-runnable, easier to debug failures).

.PARAMETER Whitelist
    Array of provisioned AppX package DisplayNames to KEEP. Anything not
    in this list gets removed. Default is a sane Microsoft set (Photos,
    Calculator, Notepad, Store, Terminal, Camera, security health, codecs).

.PARAMETER WhitelistFile
    Path to a text file with one DisplayName per line. Overrides -Whitelist.
    Lines starting with # are treated as comments. Useful for keeping the
    whitelist in source control separately from this script.

.PARAMETER DriverPath
    Path to a folder containing driver packages (.inf files) to inject into
    the offline image. Searched recursively. Use this to pre-bake chipset,
    NIC, storage, or vendor drivers into the WIM so no post-deploy injection
    step is needed at deploy time.

    Folder layout suggestion (one sub-folder per driver package):
        C:\Drivers\
          Dell_OptiPlex7090\
            chipset\  (Intel chipset .inf files)
            nvme\     (vendor NVMe .inf files)
            nic\      (NIC .inf files)

    Drivers are injected via Add-WindowsDriver with -Recurse -ForceUnsigned.
    Non-zero injection failures abort the script before saving the WIM.

.PARAMETER DisableCopilot
    Apply the offline registry tweak to disable Windows Copilot via policy
    (`HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot\TurnOffWindowsCopilot=1`).

.PARAMETER DisableExtraBloat
    Apply the broader fleet-friendly debloat policies in addition to the
    Copilot tweak. All are offline-registry edits to HKLM\SOFTWARE\Policies
    (or HKLM\SOFTWARE for one) and have no per-user component:

      - Recall (24H2+)  — DisableAIDataAnalysis = 1
      - Widgets / News  — AllowNewsAndInterests = 0
      - Start-menu web search (Bing) — DisableWebSearch = 1 +
                                       ConnectedSearchUseWeb = 0
      - Telemetry — AllowTelemetry = 0 (Enterprise floors at 0; Pro/Home
                    are capped at 1 = "Required" regardless of this value)
      - Consumer feature auto-installs (Spotify/TikTok/etc) — off
      - Edge first-run experience — hidden
      - Teams Consumer Chat auto-install — off

    If `scripts/first-login.ps1` exists in this toolkit, it is also
    staged into the image at `C:\Windows\Setup\Scripts\first-login.ps1`
    so an unattend.xml `FirstLogonCommands` entry can call it for the
    per-user (HKCU) tweaks that can't be done from the offline hive.

.PARAMETER NoCleanup
    Skip dismount-discard on the cleanup paths. Mainly for debugging stuck
    mounts. Default off.

.EXAMPLE
    # Prep a Win11 Enterprise WIM with the default whitelist + Copilot off
    .\scripts\prepare_wim.ps1 `
        -SourceIso 'D:\iso\Win11_24H2_English_x64.iso' `
        -OutputWim 'I:\images\Win11_24h2_Enterprise_Custom.wim' `
        -DisableCopilot

.EXAMPLE
    # Prep a captured WIM (e.g. from `Dism /Capture-Image` on a reference box)
    .\scripts\prepare_wim.ps1 `
        -SourceWim 'C:\captures\golden-image.wim' `
        -OutputWim 'I:\images\Win11_Golden.wim' `
        -Index 1 `
        -DisableExtraBloat

.EXAMPLE
    # Prep with custom whitelist file
    .\scripts\prepare_wim.ps1 `
        -SourceIso 'D:\iso\Win11.iso' `
        -OutputWim 'I:\images\Win11_Custom.wim' `
        -WhitelistFile 'C:\configs\my_whitelist.txt'

.EXAMPLE
    # Inject drivers + disable Copilot
    .\scripts\prepare_wim.ps1 `
        -SourceIso 'D:\iso\Win11_24H2_English_x64.iso' `
        -OutputWim 'I:\images\Win11_24H2_Enterprise_Custom.wim' `
        -DriverPath 'C:\Drivers\Dell_OptiPlex7090' `
        -DisableCopilot
#>
[CmdletBinding(DefaultParameterSetName='FromIso')]
param(
    [Parameter(Mandatory, ParameterSetName='FromIso')] [string]$SourceIso,
    [Parameter(Mandatory, ParameterSetName='FromWim')] [string]$SourceWim,
    [Parameter(Mandatory)] [string]$OutputWim,
    [string]$Edition = 'Windows 11 Enterprise',
    [int]$Index,
    [string]$WorkDir = 'C:\WimPrep',
    [string[]]$Whitelist = @(
        # Codecs and image/video extensions (apps without these break on consumer hardware)
        'Microsoft.AV1VideoExtension'
        'Microsoft.AVCEncoderVideoExtension'
        'Microsoft.HEIFImageExtension'
        'Microsoft.HEVCVideoExtension'
        'Microsoft.MPEG2VideoExtension'
        'Microsoft.RawImageExtension'
        'Microsoft.VP9VideoExtensions'
        'Microsoft.WebMediaExtensions'
        'Microsoft.WebpImageExtension'
        # Core utilities most users actually use
        'Microsoft.DesktopAppInstaller'
        'Microsoft.GetHelp'
        'Microsoft.ScreenSketch'
        'Microsoft.SecHealthUI'
        'Microsoft.StorePurchaseApp'
        'Microsoft.Windows.Photos'
        'Microsoft.WindowsAlarms'
        'Microsoft.WindowsCalculator'
        'Microsoft.WindowsCamera'
        'Microsoft.WindowsNotepad'
        'Microsoft.WindowsSoundRecorder'
        'Microsoft.WindowsStore'
        'Microsoft.WindowsTerminal'
        'Microsoft.ApplicationCompatibilityEnhancements'
        'MicrosoftWindows.Client.WebExperience'
    ),
    [string]$WhitelistFile,
    [string]$DriverPath,
    [switch]$DisableCopilot,
    [switch]$DisableExtraBloat,
    [switch]$NoCleanup
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host "[prep] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[ ok ] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[warn] $m" -ForegroundColor Yellow }

# Validate inputs (source is one of -SourceIso or -SourceWim; parameter
# sets guarantee exactly one is bound)
if ($PSCmdlet.ParameterSetName -eq 'FromIso') {
    if (-not (Test-Path $SourceIso -PathType Leaf)) {
        throw "SourceIso not found: $SourceIso"
    }
    $SourceIso = (Resolve-Path $SourceIso).Path
    # Mount-DiskImage accepts .iso / .img / .vhd(x); Windows install media
    # ships as .iso. Reject anything else up front so a mistyped -SourceIso
    # (e.g. a .wim passed to the wrong parameter) fails with a clear error
    # instead of a confusing "The disk image file is corrupted" from
    # Mount-DiskImage. Mirrors the -SourceWim extension check below.
    if ([IO.Path]::GetExtension($SourceIso) -notin '.iso') {
        throw "SourceIso must have a .iso extension (got: $SourceIso). Did you mean -SourceWim?"
    }
} else {
    if (-not (Test-Path $SourceWim -PathType Leaf)) {
        throw "SourceWim not found: $SourceWim"
    }
    $SourceWim = (Resolve-Path $SourceWim).Path
    if ([IO.Path]::GetExtension($SourceWim) -notin '.wim','.esd') {
        throw "SourceWim must have a .wim or .esd extension (got: $SourceWim)"
    }
    # Guard against -OutputWim resolving to the same file as -SourceWim.
    # The export step below deletes $OutputWim before writing the customized
    # copy (Remove-Item + Export-WindowsImage), so an in-place refresh would
    # lose the original if the export fails between the two calls. Reject
    # up front instead of destructively re-using the source path.
    $fsCwd = (Get-Location -PSProvider FileSystem).ProviderPath
    $normalizedOut = if ([IO.Path]::IsPathRooted($OutputWim)) {
        [IO.Path]::GetFullPath($OutputWim)
    } else {
        [IO.Path]::GetFullPath([IO.Path]::Combine($fsCwd, $OutputWim))
    }
    if ($normalizedOut -ieq $SourceWim) {
        throw "OutputWim resolves to the same path as SourceWim ($SourceWim). Refreshing a WIM in place is not supported - the destination is deleted before the customized copy is written, so an aborted run would lose the source. Point -OutputWim at a different path."
    }
}

if ($DriverPath) {
    if (-not (Test-Path $DriverPath -PathType Container)) {
        throw "DriverPath not found or is not a directory: $DriverPath"
    }
    $DriverPath = (Resolve-Path $DriverPath).Path
    $infCount = (Get-ChildItem -Path $DriverPath -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue).Count
    if ($infCount -eq 0) {
        throw "DriverPath '$DriverPath' contains no .inf files (searched recursively)"
    }
    Write-Step "Driver injection: found $infCount .inf file(s) under $DriverPath"
}

# Reject output extensions the deploy script wouldn't recognize.
# unified_winpe_deploy.ps1's Find-ImageFiles filters by *.wim/*.esd and
# its -WimFile gate rejects anything else, so a stray -OutputWim foo.txt
# here would produce a file no downstream step can pick up.
if ([IO.Path]::GetExtension($OutputWim) -notin '.wim','.esd') {
    throw "OutputWim must have a .wim or .esd extension (got: $OutputWim)"
}

$outputDir = Split-Path -Parent $OutputWim
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Load whitelist from file if given
if ($WhitelistFile) {
    if (-not (Test-Path $WhitelistFile -PathType Leaf)) {
        throw "WhitelistFile not found: $WhitelistFile"
    }
    $Whitelist = Get-Content $WhitelistFile |
        Where-Object { $_ -and $_ -notmatch '^\s*#' } |
        ForEach-Object { $_.Trim() }
    Write-Step "Loaded $($Whitelist.Count) whitelist entries from $WhitelistFile"
}

# Working paths
$mountDir   = Join-Path $WorkDir 'wimmount'
$scratchDir = Join-Path $WorkDir 'scratch'
$baseWim    = Join-Path $WorkDir 'install_base.wim'
foreach ($d in @($WorkDir, $mountDir, $scratchDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# Re-entrancy: a prior failed run can leave a stale WIM mount at $mountDir
# which blocks Mount-WindowsImage with a confusing error. Detect and discard
# before we start (no -Save - we don't trust whatever state was left behind).
try {
    $stale = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -ieq $mountDir }
    if ($stale) {
        Write-Warn "Stale WIM mount detected at $mountDir - discarding before continuing"
        Dismount-WindowsImage -Path $mountDir -Discard | Out-Null
    }
} catch {
    Write-Warn "Could not check for stale mounts ($($_.Exception.Message)) - continuing anyway"
}

# Step 1: produce $baseWim — either by extracting it from an ISO or by
# copying a captured WIM. From here on, the workflow is identical.
if ($PSCmdlet.ParameterSetName -eq 'FromIso') {
    Write-Step "Mounting ISO: $SourceIso"
    $isoMounted = $false
    try {
        Mount-DiskImage -ImagePath $SourceIso | Out-Null
        $isoMounted = $true
        Start-Sleep -Seconds 2  # Give the volume time to surface
        $isoVolume = Get-DiskImage -ImagePath $SourceIso | Get-Volume
        if (-not $isoVolume.DriveLetter) {
            throw "ISO mounted but no drive letter assigned"
        }
        $isoDrive = "$($isoVolume.DriveLetter):"
        Write-Ok "ISO mounted at $isoDrive"

        $isoWim = Join-Path $isoDrive 'sources\install.wim'
        $isoEsd = Join-Path $isoDrive 'sources\install.esd'

        if (Test-Path $isoWim) {
            Copy-Item -Path $isoWim -Destination $baseWim -Force
            Write-Ok "Copied install.wim to $baseWim"
        } elseif (Test-Path $isoEsd) {
            # Some retail ISOs ship an ESD - export the requested edition out.
            # ESDs collapse to one image per Export-WindowsImage call, so the
            # caller's -Index/-Edition gets honored HERE rather than in step 2
            # (after export there's only one image to pick from, and its index
            # would no longer match the caller's intent).
            Write-Step "ISO has install.esd (not .wim) - converting via Export-WindowsImage"
            $esdImages = Get-WindowsImage -ImagePath $isoEsd
            if ($PSBoundParameters.ContainsKey('Index')) {
                # -Index overrides -Edition per the .PARAMETER Index docstring.
                $esdMatch = $esdImages | Where-Object { $_.ImageIndex -eq $Index } | Select-Object -First 1
                if (-not $esdMatch) {
                    $available = ($esdImages | ForEach-Object { "  $($_.ImageIndex): $($_.ImageName)" }) -join "`n"
                    throw "Index $Index not found in install.esd. Available:`n$available"
                }
            } else {
                $esdMatch = $esdImages | Where-Object { $_.ImageName -eq $Edition } | Select-Object -First 1
                if (-not $esdMatch) {
                    $available = ($esdImages.ImageName -join ', ')
                    throw "Edition '$Edition' not found in install.esd. Available: $available"
                }
            }
            # Label the exported WIM by its actual image name so an -Index 3
            # export of 'Windows 11 Pro' isn't mislabeled as the $Edition default.
            Export-WindowsImage -SourceImagePath $isoEsd -SourceIndex $esdMatch.ImageIndex `
                -DestinationImagePath $baseWim -DestinationName $esdMatch.ImageName `
                -ScratchDirectory $scratchDir -CheckIntegrity | Out-Null
            Write-Ok "Exported '$($esdMatch.ImageName)' (ESD index $($esdMatch.ImageIndex)) from install.esd"
            # The exported WIM has exactly one image at index 1. Tell step 2 to
            # use it directly rather than re-resolving via -Index/-Edition - the
            # caller's -Index N referred to the ESD, not the resulting baseWim.
            $esdPreselected = $true
        } else {
            throw "Neither sources\install.wim nor install.esd found on ISO"
        }
    } finally {
        if ($isoMounted) {
            try {
                Dismount-DiskImage -ImagePath $SourceIso | Out-Null
                Write-Ok "ISO dismounted"
            } catch {
                Write-Warn "ISO dismount failed (non-fatal): $($_.Exception.Message)"
            }
        }
    }
} else {
    # FromWim: copy the user's WIM to the working location. We never modify
    # the source in place — keeps re-runs cheap and the original safe.
    Write-Step "Copying source WIM to working location"
    Write-Step "  source: $SourceWim"
    Write-Step "  dest:   $baseWim"
    Copy-Item -Path $SourceWim -Destination $baseWim -Force
    Write-Ok "Source WIM copied (size: $([math]::Round((Get-Item $baseWim).Length / 1GB, 1)) GB)"
}

# Step 2: identify which index in the base WIM to customize. Precedence:
#   1. ESD source already pinned a single image at step 1 - use it
#   2. -Index, if given (overrides everything else)
#   3. -Edition name match, if explicit or the source is an ISO
#   4. For captured WIMs without explicit selection: default to index 1
Write-Step "Inspecting $baseWim"
$baseImages = Get-WindowsImage -ImagePath $baseWim
$indexGiven   = $PSBoundParameters.ContainsKey('Index')
$editionGiven = $PSBoundParameters.ContainsKey('Edition')

if ($esdPreselected) {
    # The ESD branch in step 1 already picked the right image and
    # collapsed the export down to it; re-resolving here would mismatch
    # because $Index referred to the ESD, not the resulting baseWim.
    $target = $baseImages | Select-Object -First 1
    Write-Ok "Using '$($target.ImageName)' (single image extracted from ESD)"
} elseif ($indexGiven) {
    $target = $baseImages | Where-Object { $_.ImageIndex -eq $Index } | Select-Object -First 1
    if (-not $target) {
        $available = ($baseImages | ForEach-Object { "  $($_.ImageIndex): $($_.ImageName)" }) -join "`n"
        throw "Index $Index not found in $baseWim. Available:`n$available"
    }
    Write-Ok "Selected index $($target.ImageIndex): '$($target.ImageName)'"
} elseif ($editionGiven -or $PSCmdlet.ParameterSetName -eq 'FromIso') {
    $target = $baseImages | Where-Object { $_.ImageName -eq $Edition } | Select-Object -First 1
    if (-not $target) {
        $available = ($baseImages.ImageName -join ', ')
        throw "Edition '$Edition' not found in $baseWim. Available: $available"
    }
    Write-Ok "Found '$Edition' at index $($target.ImageIndex)"
} else {
    # FromWim, neither -Index nor -Edition explicitly given — most captures
    # are single-image, default to index 1.
    $target = $baseImages | Select-Object -First 1
    Write-Ok "Using first index: $($target.ImageIndex) ($($target.ImageName))"
}

# Step 3: mount the WIM, debloat, optionally tweak registry, dismount /save (try/finally)
Write-Step "Mounting WIM index $($target.ImageIndex) at $mountDir"
$wimMounted = $false
$saveMount = $false  # only set true after successful customization
try {
    Mount-WindowsImage -ImagePath $baseWim -Index $target.ImageIndex -Path $mountDir | Out-Null
    $wimMounted = $true
    Write-Ok "WIM mounted"

    Write-Step "Debloating provisioned AppX packages"
    $packages = Get-AppxProvisionedPackage -Path $mountDir
    # Normalize whitelist to lower-case once so the per-package check is
    # case-insensitive without paying the .ToLower() cost in the loop.
    # PowerShell 5.1 doesn't have -icontains, so this is the portable form.
    $whitelistLower = @($Whitelist | ForEach-Object { $_.Trim().ToLowerInvariant() })
    $kept = 0
    $removed = 0
    foreach ($pkg in $packages) {
        if ($whitelistLower -contains $pkg.DisplayName.ToLowerInvariant()) {
            $kept++
            continue
        }
        try {
            Remove-AppxProvisionedPackage -Path $mountDir -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
            $removed++
            Write-Host "  removed: $($pkg.DisplayName)" -ForegroundColor DarkGray
        } catch {
            # Fail loud - if a package can't be removed we want to know.
            # The deploy script's whole philosophy is "fail loud" and this script honors that.
            throw "Failed to remove $($pkg.DisplayName): $($_.Exception.Message)"
        }
    }
    Write-Ok "Debloat complete: $kept kept, $removed removed"

    if ($DisableCopilot -or $DisableExtraBloat) {
        Write-Step "Applying offline-registry policy tweaks"
        $softwareHive = Join-Path $mountDir 'Windows\System32\config\SOFTWARE'
        if (-not (Test-Path $softwareHive)) {
            throw "Offline SOFTWARE hive not found at $softwareHive"
        }
        $hiveKey = 'HKLM\WimPrepSoftware'
        # Capture reg.exe output so a non-zero exit code can be paired with
        # the actual diagnostic (file locked, access denied, hive corrupt,
        # wrong format). reg.exe's exit codes are undocumented — the bare
        # integer alone is opaque. Matches the pattern in first-login.ps1.
        $loadOutput = & reg.exe load $hiveKey $softwareHive 2>&1
        if ($LASTEXITCODE -ne 0) {
            $loadMsg = ($loadOutput | Out-String).Trim()
            if ($loadMsg) {
                throw "reg load failed (exit $LASTEXITCODE): $loadMsg"
            } else {
                throw "reg load failed (exit $LASTEXITCODE)"
            }
        }
        try {
            # Each entry: <subkey under hiveKey>, <value name>, <DWORD>, <human label>
            $tweaks = @()

            if ($DisableCopilot -or $DisableExtraBloat) {
                $tweaks += ,@('Policies\Microsoft\Windows\WindowsCopilot', 'TurnOffWindowsCopilot', 1, 'Copilot (policy)')
            }

            if ($DisableExtraBloat) {
                # Recall (24H2+) — AI screenshot / recall feature
                $tweaks += ,@('Policies\Microsoft\Windows\WindowsAI', 'DisableAIDataAnalysis', 1, 'Recall')
                # Widgets / News & Interests on the taskbar
                $tweaks += ,@('Policies\Microsoft\Dsh', 'AllowNewsAndInterests', 0, 'Widgets / News & Interests')
                # Bing / web results in Start-menu search (two values both required)
                $tweaks += ,@('Policies\Microsoft\Windows\Windows Search', 'DisableWebSearch',      1, 'Start-menu web search (DisableWebSearch)')
                $tweaks += ,@('Policies\Microsoft\Windows\Windows Search', 'ConnectedSearchUseWeb', 0, 'Start-menu web search (ConnectedSearchUseWeb)')
                # Telemetry — Enterprise floors at 0, Pro/Home cap at 1 (Required) regardless
                $tweaks += ,@('Policies\Microsoft\Windows\DataCollection', 'AllowTelemetry', 0, 'Telemetry (Enterprise: off; Pro/Home: capped at Required)')
                # Consumer features — stops the "Get Microsoft 365 / Spotify / TikTok" auto-installs
                $tweaks += ,@('Policies\Microsoft\Windows\CloudContent', 'DisableWindowsConsumerFeatures', 1, 'Consumer feature auto-installs')
                # Edge first-run experience nag
                $tweaks += ,@('Policies\Microsoft\Edge', 'HideFirstRunExperience', 1, 'Edge first-run experience')
                # Teams Consumer Chat auto-install
                $tweaks += ,@('Microsoft\Windows\CurrentVersion\Communications', 'ConfigureChatAutoInstall', 0, 'Teams Consumer Chat auto-install')
            }

            foreach ($t in $tweaks) {
                $subkey, $name, $value, $label = $t
                $full = "$hiveKey\$subkey"
                & reg.exe add $full /f | Out-Null
                $addOutput = & reg.exe add $full /v $name /t REG_DWORD /d $value /f 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $addMsg = ($addOutput | Out-String).Trim()
                    if ($addMsg) {
                        throw "reg add $name failed (exit $LASTEXITCODE): $addMsg"
                    } else {
                        throw "reg add $name failed (exit $LASTEXITCODE)"
                    }
                }
                Write-Ok "  $label"
            }
        } finally {
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            $unloadOutput = & reg.exe unload $hiveKey 2>&1
            if ($LASTEXITCODE -ne 0) {
                $unloadMsg = ($unloadOutput | Out-String).Trim()
                if ($unloadMsg) {
                    Write-Warn "reg unload returned $LASTEXITCODE - may need a reboot: $unloadMsg"
                } else {
                    Write-Warn "reg unload returned $LASTEXITCODE - may need a reboot"
                }
            }
        }
    }

    # Stage first-login.ps1 into the image if -DisableExtraBloat is set and
    # the toolkit ships one. Lands at C:\Windows\Setup\Scripts\ — a standard
    # Microsoft path. An unattend.xml `FirstLogonCommands` entry can then
    # call it to apply per-user (HKCU) tweaks at first sign-in.
    if ($DisableExtraBloat) {
        $firstLoginSrc = Join-Path $PSScriptRoot 'first-login.ps1'
        if (Test-Path $firstLoginSrc -PathType Leaf) {
            $setupScriptsDir = Join-Path $mountDir 'Windows\Setup\Scripts'
            if (-not (Test-Path $setupScriptsDir)) {
                New-Item -ItemType Directory -Path $setupScriptsDir -Force | Out-Null
            }
            Copy-Item -Path $firstLoginSrc -Destination (Join-Path $setupScriptsDir 'first-login.ps1') -Force
            Write-Ok "Staged first-login.ps1 -> C:\Windows\Setup\Scripts\first-login.ps1"
        } else {
            Write-Warn "scripts/first-login.ps1 not found — skipping per-user tweaks staging"
        }
    }

    if ($DriverPath) {
        Write-Step "Injecting drivers from $DriverPath"
        $driverResult = Add-WindowsDriver -Path $mountDir -Driver $DriverPath -Recurse -ForceUnsigned
        $injected = @($driverResult).Count
        Write-Ok "Injected $injected driver package(s)"
    }

    $saveMount = $true
} finally {
    if ($wimMounted) {
        if ($saveMount) {
            Write-Step "Committing WIM (save + verify)"
            Dismount-WindowsImage -Path $mountDir -Save -CheckIntegrity | Out-Null
            Write-Ok "WIM committed"
        } elseif (-not $NoCleanup) {
            Write-Warn "Customization failed - discarding WIM mount"
            Dismount-WindowsImage -Path $mountDir -Discard | Out-Null
        }
    }
}

# Step 4: re-export with /Compress:max so the output is the cleanest version of just the customized index.
# Base the destination name on the selected image's actual name, not $Edition — when -SourceWim is used
# with -Index (or with no explicit edition), $Edition keeps its default ('Windows 11 Enterprise') and
# would mislabel a captured WIM as Enterprise regardless of what it actually is.
$sourceName = if ($target.ImageName) { $target.ImageName } else { $Edition }
$destinationName = "$sourceName (Custom)"
Write-Step "Re-exporting customized WIM to $OutputWim (max compression)"
if (Test-Path $OutputWim) { Remove-Item $OutputWim -Force }
Export-WindowsImage -SourceImagePath $baseWim -SourceIndex $target.ImageIndex `
    -DestinationImagePath $OutputWim -DestinationName $destinationName `
    -ScratchDirectory $scratchDir -CheckIntegrity -CompressionType Max | Out-Null

$finalSizeGB = [Math]::Round((Get-Item $OutputWim).Length / 1GB, 2)
Write-Ok "Wrote $OutputWim ($finalSizeGB GB)"

Write-Host ""
Write-Host "Done." -ForegroundColor Green
$inputPath = if ($PSCmdlet.ParameterSetName -eq 'FromIso') { $SourceIso } else { $SourceWim }
Write-Host "  Input:   $inputPath"
Write-Host "  Output:  $OutputWim"
if ($DriverPath) { Write-Host "  Drivers: $DriverPath" }
Write-Host ""
Write-Host "Next steps:"
Write-Host "  Single-ISO workflow (recommended for end-user distribution):"
Write-Host "    .\scripts\build_iso.ps1 -WimFile '$OutputWim' -OutputIso <path\deploy.iso>"
Write-Host "    Then send the ISO to users — they flash it with Rufus. See docs/END_USER_DEPLOY.md."
Write-Host ""
Write-Host "  Two-partition USB workflow:"
Write-Host "    Copy the WIM to the USB IMAGES partition under \images\"
Write-Host "    then boot a target host with the WinPE USB to deploy."
