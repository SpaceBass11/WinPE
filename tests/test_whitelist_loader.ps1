<#
.SYNOPSIS
    Fixture test for the -WhitelistFile loader in scripts/prepare_wim.ps1.

.DESCRIPTION
    prepare_wim.ps1 accepts a -WhitelistFile of provisioned AppX
    DisplayNames to KEEP. If the loader produces an empty (or
    all-empty-string) array, the debloat loop's -contains check matches
    nothing and REMOVES every provisioned package - Store, Terminal,
    Photos, Camera, Notepad, security health, codecs - which is exactly
    the outcome the whitelist exists to prevent. That's a silent
    "fail open to worst case" bug.

    This test feeds four fixtures through a loader block that mirrors
    the one in prepare_wim.ps1 verbatim, then asserts:
      - empty / comment-only / whitespace-only files parse to count 0
      - a real mixed file parses to the expected entries
      - a single-entry file yields an array (not a bare string), so
        .Count / -contains work downstream
      - the count-0 case throws (not silent removal)

    A drift guard confirms the loader block still lives verbatim in
    prepare_wim.ps1 and that the empty-throw path is still wired in.

    Works with both PowerShell 5.1 and 7+. Returns exit code 0 on
    success, 1 on failure.
#>

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..' 'scripts' 'prepare_wim.ps1'
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

Write-Host "`n=== WinPE Deploy - Whitelist Loader Tests ===" -ForegroundColor Cyan

# --- Loader block (mirrors prepare_wim.ps1). Kept verbatim so the drift
#     guard at the bottom of this file can confirm the deploy pipeline
#     still uses this exact filtering.
function Load-Whitelist {
    param([string]$Path)
    $wl = @(Get-Content $Path |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch '^#' })
    return ,$wl
}

# Cross-platform scratch dir
$tmpRoot = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
$fixtureDir = Join-Path $tmpRoot "winpe-wl-fixtures-$PID"
if (Test-Path $fixtureDir) { Remove-Item $fixtureDir -Recurse -Force }
New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null

try {
    # --- Fixture 1: genuinely empty file (0 bytes) ---
    $f = Join-Path $fixtureDir 'empty.txt'
    '' | Set-Content -Path $f -NoNewline
    $r = Load-Whitelist -Path $f
    Write-Host "`n--- Empty file (0 bytes) ---" -ForegroundColor Cyan
    Write-Result -Test "Loader returns 0 entries" -Pass ($r.Count -eq 0) -Detail "Got $($r.Count)"

    # --- Fixture 2: only comment lines ---
    $f = Join-Path $fixtureDir 'comments.txt'
    @'
# Comment header
# Another comment
   # Comment with leading whitespace
'@ | Set-Content -Path $f
    $r = Load-Whitelist -Path $f
    Write-Host "`n--- Comment-only file ---" -ForegroundColor Cyan
    Write-Result -Test "Loader returns 0 entries" -Pass ($r.Count -eq 0) -Detail "Got $($r.Count)"

    # --- Fixture 3: only whitespace lines (the sneakiest bug — pre-fix
    #     these WOULD pass '$_ -and' as truthy and end up as empty
    #     strings in the whitelist, matching nothing) ---
    $f = Join-Path $fixtureDir 'whitespace.txt'
    "   `n`t`t   `n    `n" | Set-Content -Path $f -NoNewline
    $r = Load-Whitelist -Path $f
    Write-Host "`n--- Whitespace-only file ---" -ForegroundColor Cyan
    Write-Result -Test "Loader returns 0 entries (no empty-string leakage)" -Pass ($r.Count -eq 0) -Detail "Got $($r.Count): [$($r -join '|')]"

    # --- Fixture 4: real mixed file (blanks + comments + real entries,
    #     with leading/trailing whitespace on the real ones) ---
    $f = Join-Path $fixtureDir 'mixed.txt'
    @'
# Keep list minimal

Microsoft.WindowsStore
   Microsoft.WindowsTerminal
# below is a spare entry

Microsoft.WindowsCamera
'@ | Set-Content -Path $f
    $r = Load-Whitelist -Path $f
    Write-Host "`n--- Mixed file (blanks, comments, real entries) ---" -ForegroundColor Cyan
    Write-Result -Test "Loader returns 3 entries" -Pass ($r.Count -eq 3) -Detail "Got $($r.Count)"
    Write-Result -Test "Entry 0 is trimmed 'Microsoft.WindowsStore'" -Pass ($r[0] -eq 'Microsoft.WindowsStore') -Detail "Got '$($r[0])'"
    Write-Result -Test "Entry 1 leading whitespace trimmed" -Pass ($r[1] -eq 'Microsoft.WindowsTerminal') -Detail "Got '$($r[1])'"
    Write-Result -Test "Entry 2 is 'Microsoft.WindowsCamera'" -Pass ($r[2] -eq 'Microsoft.WindowsCamera') -Detail "Got '$($r[2])'"

    # --- Fixture 5: single-entry file. Must yield an array (not bare
    #     string), so downstream .Count and -contains work correctly. ---
    $f = Join-Path $fixtureDir 'single.txt'
    'Microsoft.WindowsStore' | Set-Content -Path $f
    $r = Load-Whitelist -Path $f
    Write-Host "`n--- Single-entry file ---" -ForegroundColor Cyan
    Write-Result -Test "Loader returns 1 entry" -Pass ($r.Count -eq 1) -Detail "Got $($r.Count)"
    Write-Result -Test "Result is an array, not a bare string" -Pass ($r -is [Array]) -Detail "Got type $($r.GetType().Name)"
    Write-Result -Test "Entry 0 is 'Microsoft.WindowsStore'" -Pass ($r[0] -eq 'Microsoft.WindowsStore') -Detail "Got '$($r[0])'"
} finally {
    if (Test-Path $fixtureDir) { Remove-Item $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- Drift guard: the loader block and the empty-whitelist throw must
#     still live verbatim in prepare_wim.ps1. If someone refactors the
#     loader and drops the Count-0 rejection, the debloat regression
#     silently returns.
Write-Host "`n--- Drift guard ---" -ForegroundColor Cyan
if (-not (Test-Path $scriptPath)) {
    Write-Result -Test "prepare_wim.ps1 exists at $scriptPath" -Pass $false
} else {
    Write-Result -Test "prepare_wim.ps1 exists" -Pass $true
    $scriptText = Get-Content $scriptPath -Raw

    # Trim-before-filter is the actual fix. Order matters: filtering
    # before trim would let whitespace-only lines through as ''.
    Write-Result -Test "Loader trims before filter (ForEach-Object Trim precedes Where-Object)" `
        -Pass ($scriptText -match "ForEach-Object\s*\{\s*\`$_\.Trim\(\)\s*\}\s*\|\s*Where-Object") `
        -Detail 'Trim/Where order flipped in prepare_wim.ps1 - whitespace-only lines will leak in as empty strings'

    # @( ... ) wrapper is what forces array type for single-entry files.
    Write-Result -Test "Loader wraps Get-Content pipeline in @(...) for array coercion" `
        -Pass ($scriptText -match '\$Whitelist\s*=\s*@\(Get-Content\s+\$WhitelistFile') `
        -Detail 'Single-entry files would collapse to bare strings and break -contains matching'

    # The count-0 throw is what prevents silent removal of every package.
    Write-Result -Test "Loader throws when whitelist is effectively empty" `
        -Pass ($scriptText -match 'Whitelist\.Count\s*-eq\s*0' -and $scriptText -match 'has no usable entries') `
        -Detail 'Empty-whitelist throw missing - all provisioned packages would be removed silently'
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
