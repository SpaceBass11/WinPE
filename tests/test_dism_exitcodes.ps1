<#
.SYNOPSIS
    Fixture test for the DISM exit-code recovery-guidance switch in
    Apply-WindowsImage (unified_winpe_deploy.ps1).
.DESCRIPTION
    Apply-WindowsImage's switch on $process.ExitCode carries bespoke
    Write-Log recovery guidance per known DISM failure mode. Removing
    or renumbering an arm silently degrades operator experience at
    the exact moment they need it - a wiped target and a generic
    "exit code N" line with no "what do I try next" hint.

    This test asserts the recovery-guidance switch still contains a
    dedicated arm for each documented DISM exit code (1, 2, 11, 50,
    87, 112, 1168, 1392), that each specific arm still carries at
    least one bespoke Write-Log line, and that a default catch-all
    remains so unknown exit codes still point the operator at
    TROUBLESHOOTING.md. A drift guard also confirms the switch still
    dispatches on $process.ExitCode - a rename of the process
    variable is caught here instead of by an operator staring at a
    silent switch fall-through.

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

function Find-BalancedBraceEnd {
    param(
        [Parameter(Mandatory)] [string]$Text,
        [Parameter(Mandatory)] [int]$StartIndex
    )
    # $StartIndex points at the character AFTER the opening '{'.
    # Returns the index of the matching '}', or $null if unbalanced.
    $depth = 1
    for ($i = $StartIndex; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }
    return $null
}

Write-Host "`n=== WinPE Deploy - DISM Exit-Code Guidance Tests ===" -ForegroundColor Cyan

if (-not (Test-Path $scriptPath)) {
    Write-Result -Test "Deploy script exists" -Pass $false -Detail "Not found at $scriptPath"
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "Passed: $passed" -ForegroundColor Green
    Write-Host "Failed: $failed" -ForegroundColor Red
    exit 1
}
Write-Result -Test "Deploy script exists" -Pass $true

$content = Get-Content $scriptPath -Raw

# --- Drift guard: locate the DISM exit-code switch by its dispatch expression ---
# There is exactly one switch on $process.ExitCode in the script (Apply-WindowsImage).
# If that call site moves, this test tells the refactorer, not the operator.
$switchMatch = [regex]::Match($content, 'switch\s*\(\s*\$process\.ExitCode\s*\)\s*\{')
Write-Result -Test 'switch ($process.ExitCode) block present' -Pass $switchMatch.Success `
    -Detail 'Apply-WindowsImage no longer dispatches on $process.ExitCode - update this test if intentional'
if (-not $switchMatch.Success) {
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "Passed: $passed" -ForegroundColor Green
    Write-Host "Failed: $failed" -ForegroundColor Red
    exit 1
}

$switchBodyStart = $switchMatch.Index + $switchMatch.Length
$switchBodyEnd = Find-BalancedBraceEnd -Text $content -StartIndex $switchBodyStart
Write-Result -Test 'switch body brace-balanced' -Pass ($null -ne $switchBodyEnd)
if ($null -eq $switchBodyEnd) {
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "Passed: $passed" -ForegroundColor Green
    Write-Host "Failed: $failed" -ForegroundColor Red
    exit 1
}
$switchBody = $content.Substring($switchBodyStart, $switchBodyEnd - $switchBodyStart)

# --- Every documented DISM exit code needs a dedicated switch arm ---
# Keep this list in sync with the "DISM fails with error code" table in
# docs/TROUBLESHOOTING.md. Adding an arm to the script but not the docs
# (or vice versa) is a documentation drift, not a test failure - both
# sides serve the operator.
$expectedCodes = @(1, 2, 11, 50, 87, 112, 1168, 1392)

foreach ($code in $expectedCodes) {
    $armMatch = [regex]::Match($switchBody, "(?m)^\s*$code\s*\{")
    Write-Result -Test "Exit-code arm $code present" -Pass $armMatch.Success
    if (-not $armMatch.Success) { continue }

    # Each specific arm must still carry at least one bespoke Write-Log line.
    # An empty arm would silently swallow the failure with no operator
    # guidance - worse than the default catch-all which at least points at
    # TROUBLESHOOTING.md.
    $armBodyStart = $armMatch.Index + $armMatch.Length
    $armBodyEnd = Find-BalancedBraceEnd -Text $switchBody -StartIndex $armBodyStart
    if ($null -eq $armBodyEnd) {
        Write-Result -Test "Exit-code arm $code body brace-balanced" -Pass $false
        continue
    }
    $armBody = $switchBody.Substring($armBodyStart, $armBodyEnd - $armBodyStart)
    Write-Result -Test "Exit-code arm $code has bespoke Write-Log guidance" -Pass ($armBody -match 'Write-Log')
}

# --- Default arm is required so unknown codes still get the docs pointer ---
$defaultMatch = [regex]::Match($switchBody, '(?m)^\s*default\s*\{')
Write-Result -Test 'Default catch-all arm present' -Pass $defaultMatch.Success `
    -Detail 'Unknown exit codes need a pointer to docs/TROUBLESHOOTING.md - do not remove the default arm'

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
