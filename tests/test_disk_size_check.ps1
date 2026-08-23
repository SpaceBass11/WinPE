<#
.SYNOPSIS
    Fixture test for the disk-size validation math in Start-Deployment
    (unified_winpe_deploy.ps1).

.DESCRIPTION
    Before partitioning, Start-Deployment computes an estimate of how big
    the applied image will be on the target disk, then refuses to wipe a
    disk that's smaller than that estimate. The math has two branches:

      1. DISM /Get-WimInfo gave us an uncompressed Size for the selected
         index (preferred). Use it verbatim, +1.5 GB EFI/MSR/overhead.
      2. No usable DISM size. Multiply the compressed WIM file size by 3
         (typical WIM compression ratio is 2.5-4x), +1.5 GB overhead.

    A regression that silently flips the precedence, drops the 3x
    multiplier on the compressed-only path, or skips the +1.5 GB
    overhead would let the script "pass" the size check on a disk
    that DISM will overflow mid-apply (exit 112) - after the disk
    has already been wiped. That's the failure mode this test
    guards against.

    No real DISM, no real disks. The math is mirrored into a helper
    function exercised by 9 fixtures (compressed-only, uncompressed-
    preferred, malformed DISM size, empty DISM size, boundary disk
    pass/fail, and the uncompressed-not-greater-than-compressed
    corner case). A drift guard at the bottom asserts the
    safety-critical literals and expressions still live in the
    deploy script verbatim; if either side moves without the other,
    the guard fails and forces the test to be updated.

    Works with both PowerShell 5.1 and 7+. Returns exit code 0 on
    success, 1 on failure.
#>

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..' 'unified_winpe_deploy.ps1'
$passed = 0
$failed = 0

function Write-Result {
    param([string]$Test, [bool]$Pass, [string]$Detail = '')
    if ($Pass) {
        Write-Host "  [PASS] $Test" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $Test - $Detail" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host "`n=== WinPE Deploy - Disk Size Validation Tests ===" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Math mirror (matches the block under "Validate disk size using uncompressed
# image size when available" in Start-Deployment)
# ---------------------------------------------------------------------------
function Get-DiskSizeEstimate {
    param(
        # Compressed WIM file size in bytes (matches $selectedImage.Size)
        [Parameter(Mandatory)] [double]$CompressedBytes,
        # Raw DISM Size string for the selected index, e.g. '16,134,221,478 bytes'
        # Pass $null or '' when DISM didn't provide a size for the chosen index.
        [string]$DismSizeRaw
    )

    $estimatedSizeGB = [Math]::Round($CompressedBytes / 1GB, 2)
    $sizeSource = 'compressed WIM ~3x'
    $usedUncompressed = $false

    if ($DismSizeRaw) {
        try {
            $sizeStr = $DismSizeRaw -replace '[^\d]', ''
            if ($sizeStr) {
                $uncompressedGB = [Math]::Round([double]$sizeStr / 1GB, 2)
                if ($uncompressedGB -gt $estimatedSizeGB) {
                    $estimatedSizeGB = $uncompressedGB
                    $sizeSource = 'uncompressed'
                    $usedUncompressed = $true
                }
            }
        } catch {
            # Mirrors the script's swallow: malformed string -> fall through
            # to the 3x compressed multiplier.
        }
    }

    if (-not $usedUncompressed) {
        $estimatedSizeGB = [Math]::Round($estimatedSizeGB * 3, 2)
    }

    $minRequiredGB = $estimatedSizeGB + 1.5

    return [PSCustomObject]@{
        EstimatedGB      = $estimatedSizeGB
        MinRequiredGB    = $minRequiredGB
        SizeSource       = $sizeSource
        UsedUncompressed = $usedUncompressed
    }
}

# ---------------------------------------------------------------------------
# Compressed-only path (DISM returned no usable size)
# ---------------------------------------------------------------------------

Write-Host "`n--- Compressed-only path (no DISM size) ---" -ForegroundColor Cyan

# 5 GB compressed -> 15 GB estimated -> 16.5 GB required
$r = Get-DiskSizeEstimate -CompressedBytes 5GB -DismSizeRaw $null
Write-Result -Test "5 GB compressed, no DISM size: estimated = 15 GB (3x multiplier)" `
    -Pass ($r.EstimatedGB -eq 15.0) -Detail "got $($r.EstimatedGB)"
Write-Result -Test "5 GB compressed, no DISM size: minRequired = 16.5 GB (+1.5 GB overhead)" `
    -Pass ($r.MinRequiredGB -eq 16.5) -Detail "got $($r.MinRequiredGB)"
Write-Result -Test "5 GB compressed, no DISM size: sizeSource = 'compressed WIM ~3x'" `
    -Pass ($r.SizeSource -eq 'compressed WIM ~3x') -Detail "got '$($r.SizeSource)'"
Write-Result -Test "5 GB compressed, no DISM size: UsedUncompressed = false" `
    -Pass ($r.UsedUncompressed -eq $false)

# Empty string (DISM Size field literally empty)
$r = Get-DiskSizeEstimate -CompressedBytes 5GB -DismSizeRaw ''
Write-Result -Test "Empty DISM size string falls back to 3x compressed (estimated = 15 GB)" `
    -Pass ($r.EstimatedGB -eq 15.0 -and $r.UsedUncompressed -eq $false) `
    -Detail "EstimatedGB=$($r.EstimatedGB) UsedUncompressed=$($r.UsedUncompressed)"

# Malformed DISM size that strips to empty (e.g. '   bytes', no digits)
$r = Get-DiskSizeEstimate -CompressedBytes 5GB -DismSizeRaw 'bytes'
Write-Result -Test "Malformed DISM size (no digits) falls back to 3x compressed" `
    -Pass ($r.EstimatedGB -eq 15.0 -and $r.UsedUncompressed -eq $false) `
    -Detail "EstimatedGB=$($r.EstimatedGB) UsedUncompressed=$($r.UsedUncompressed)"

# ---------------------------------------------------------------------------
# DISM-preferred path (uncompressed > compressed)
# ---------------------------------------------------------------------------

Write-Host "`n--- DISM-preferred path (uncompressed Size present) ---" -ForegroundColor Cyan

# 5 GB compressed + DISM '16,134,221,478 bytes' (~15.02 GB) -> use uncompressed.
# Critical: NO 3x multiplier applied. minRequired = 15.02 + 1.5 = 16.52 GB.
$r = Get-DiskSizeEstimate -CompressedBytes 5GB -DismSizeRaw '16,134,221,478 bytes'
$expectedGB = [Math]::Round(16134221478 / 1GB, 2)   # ~15.03
Write-Result -Test "Uncompressed DISM size (15 GB) is preferred over compressed (5 GB)" `
    -Pass ($r.EstimatedGB -eq $expectedGB -and $r.UsedUncompressed -eq $true) `
    -Detail "EstimatedGB=$($r.EstimatedGB), expected $expectedGB, UsedUncompressed=$($r.UsedUncompressed)"
Write-Result -Test "Uncompressed path: 3x multiplier is NOT applied (no double-count)" `
    -Pass ($r.EstimatedGB -lt 30) -Detail "EstimatedGB=$($r.EstimatedGB) - if > 30 the 3x multiplier crept in"
Write-Result -Test "Uncompressed path: sizeSource = 'uncompressed'" `
    -Pass ($r.SizeSource -eq 'uncompressed') -Detail "got '$($r.SizeSource)'"
Write-Result -Test "Uncompressed path: +1.5 GB overhead still applied" `
    -Pass ([Math]::Abs($r.MinRequiredGB - ($r.EstimatedGB + 1.5)) -lt 0.001) `
    -Detail "MinRequiredGB=$($r.MinRequiredGB) EstimatedGB=$($r.EstimatedGB)"

# Whitespace / mixed separators (DISM in some locales / mock fixtures may use spaces)
$r = Get-DiskSizeEstimate -CompressedBytes 5GB -DismSizeRaw '14 632 927 856'
Write-Result -Test "Space-separated DISM size still parses (uncompressed path)" `
    -Pass ($r.UsedUncompressed -eq $true -and $r.SizeSource -eq 'uncompressed') `
    -Detail "UsedUncompressed=$($r.UsedUncompressed) SizeSource='$($r.SizeSource)'"

# ---------------------------------------------------------------------------
# Corner case: uncompressed not greater than compressed
# (Real WIMs always uncompressed > compressed; this guards against a fixture
# or refactor where the comparison flips.)
# ---------------------------------------------------------------------------

Write-Host "`n--- Corner case: uncompressed <= compressed ---" -ForegroundColor Cyan

# 10 GB compressed, DISM reports same 10 GB. Comparison is '-gt' (strict),
# so the 3x branch fires: estimated = 30 GB, source = compressed.
$r = Get-DiskSizeEstimate -CompressedBytes 10GB -DismSizeRaw '10737418240 bytes'   # exactly 10 GB
Write-Result -Test "When uncompressed == compressed, falls back to 3x multiplier (strict -gt)" `
    -Pass ($r.UsedUncompressed -eq $false -and $r.EstimatedGB -eq 30.0) `
    -Detail "UsedUncompressed=$($r.UsedUncompressed) EstimatedGB=$($r.EstimatedGB)"

# ---------------------------------------------------------------------------
# Disk pass/fail boundary
# ---------------------------------------------------------------------------

Write-Host "`n--- Disk capacity check (boundary) ---" -ForegroundColor Cyan

# Compressed 5 GB -> minRequired 16.5 GB. A 16 GB disk must FAIL; 20 GB must PASS.
$r = Get-DiskSizeEstimate -CompressedBytes 5GB -DismSizeRaw $null
$diskSmall = 16   # GB
$diskLarge = 20   # GB
Write-Result -Test "16 GB disk vs 16.5 GB requirement: rejected ('-lt' check)" `
    -Pass ($diskSmall -lt $r.MinRequiredGB)
Write-Result -Test "20 GB disk vs 16.5 GB requirement: accepted" `
    -Pass ($diskLarge -ge $r.MinRequiredGB)
# Exactly at boundary: 16.5 GB disk vs 16.5 GB required. The script uses
# '-lt', so equal disk size passes. Keeps the test in sync with that
# boundary semantics; flipping to '-le' would fail this assertion.
$diskExact = 16.5
Write-Result -Test "Disk size exactly equal to minRequired: accepted (-lt, not -le)" `
    -Pass (-not ($diskExact -lt $r.MinRequiredGB)) -Detail "disk=$diskExact required=$($r.MinRequiredGB)"

# ---------------------------------------------------------------------------
# Drift guard: safety-critical code shapes must still live in the deploy script
# ---------------------------------------------------------------------------

Write-Host "`n--- Drift guard ---" -ForegroundColor Cyan

if (-not (Test-Path $scriptPath)) {
    Write-Result -Test "Deploy script exists at $scriptPath" -Pass $false
} else {
    Write-Result -Test "Deploy script exists" -Pass $true
    $scriptText = Get-Content $scriptPath -Raw

    Write-Result -Test "Initial compressed estimate '/ 1GB' still present" `
        -Pass ($scriptText -match '\[Math\]::Round\(\$selectedImage\.Size / 1GB, 2\)') `
        -Detail 'expected [Math]::Round($selectedImage.Size / 1GB, 2)'

    Write-Result -Test "'compressed WIM ~3x' sizeSource label still present" `
        -Pass ($scriptText -match '"compressed WIM ~3x"') `
        -Detail "expected the literal '\"compressed WIM ~3x\"'"

    Write-Result -Test "'uncompressed' sizeSource label still present" `
        -Pass ($scriptText -match '\$sizeSource\s*=\s*"uncompressed"') `
        -Detail "expected `$sizeSource = `"uncompressed`""

    Write-Result -Test "DISM Size '[^\\d]' digit-strip parser still present" `
        -Pass ($scriptText -match 'selectedWimInfo\.Size -replace ''\[\^\\d\]'', ''''') `
        -Detail "expected `$selectedWimInfo.Size -replace '[^\d]', ''"

    Write-Result -Test "Uncompressed-greater-than comparison still '-gt' (strict)" `
        -Pass ($scriptText -match '\$uncompressedGB -gt \$estimatedSizeGB') `
        -Detail 'expected $uncompressedGB -gt $estimatedSizeGB (NOT -ge or reversed)'

    Write-Result -Test "3x safety multiplier still present on compressed path" `
        -Pass ($scriptText -match '\[Math\]::Round\(\$estimatedSizeGB \* 3, 2\)') `
        -Detail 'expected [Math]::Round($estimatedSizeGB * 3, 2)'

    Write-Result -Test "+1.5 GB overhead still applied to minRequiredGB" `
        -Pass ($scriptText -match '\$minRequiredGB = \$estimatedSizeGB \+ 1\.5') `
        -Detail 'expected $minRequiredGB = $estimatedSizeGB + 1.5'

    Write-Result -Test "Target-disk capacity check still uses '-lt' (strict; equal passes)" `
        -Pass ($scriptText -match '\$targetDisk\.Size -lt \$minRequiredGB') `
        -Detail 'expected $targetDisk.Size -lt $minRequiredGB'

    Write-Result -Test "'usedUncompressed' guard still gates the 3x multiplier" `
        -Pass ($scriptText -match 'if \(-not \$usedUncompressed\)') `
        -Detail 'expected if (-not $usedUncompressed) before the *3 line'
}

# --- Summary ---
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "Passed: $passed" -ForegroundColor Green
Write-Host "Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })

if ($failed -gt 0) {
    exit 1
} else {
    Write-Host "`nAll checks passed!" -ForegroundColor Green
    exit 0
}
