<#
.SYNOPSIS
    Fixture test for Test-FinalWipeConfirmation in unified_winpe_deploy.ps1.

.DESCRIPTION
    Test-FinalWipeConfirmation is the shared parser that decides whether a
    Read-Host value at the primary-target confirmation prompt proceeds with
    the disk wipe. It is called from two paths in Select-TargetDisk:

      - -TargetDisk given, not -Force  (unified_winpe_deploy.ps1 :763)
      - interactive disk selection      (unified_winpe_deploy.ps1 :810)

    Two silent regressions must be guarded:

      1. Accepted set narrows (e.g. ERASE stops matching lowercase input).
         Operators typing 'erase' hit an unexplained loop / cancel — UX
         regression the CI string-grep for 'DELETE ALL DATA' cannot see.

      2. Accepted set widens (e.g. 'YES' or 'Y' slips in). A hurried
         operator's throwaway 'y' now proceeds with a destructive wipe.

    The function is pure (no I/O, no WMI) so it is trivially testable in
    isolation. This file re-declares the parser body and runs it against
    fixtures, then a drift guard confirms the real function still lives
    in the deploy script with the same shape.

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

Write-Host "`n=== WinPE Deploy - Test-FinalWipeConfirmation Tests ===" -ForegroundColor Cyan

# --- Mirror of the parser (kept in sync via the drift guard at the bottom) ---
function Test-FinalWipeConfirmationLocal {
    param([string]$InputText)
    $normalized = if ($null -eq $InputText) { '' } else { $InputText.Trim().ToUpperInvariant() }
    return $normalized -in @('ERASE', 'DELETE ALL DATA')
}

# ---------------------------------------------------------------------------
# Positive cases: every canonical input must proceed with the wipe
# ---------------------------------------------------------------------------

Write-Host "`n--- Accepted inputs (wipe proceeds) ---" -ForegroundColor Cyan

$acceptedCases = @(
    @{ Input = 'ERASE';           Label = "'ERASE' (canonical)" }
    @{ Input = 'erase';           Label = "'erase' (lowercase)" }
    @{ Input = 'Erase';           Label = "'Erase' (mixed case)" }
    @{ Input = '  ERASE  ';       Label = "'  ERASE  ' (surrounding whitespace)" }
    @{ Input = "`tERASE`t";       Label = "tab-wrapped 'ERASE'" }
    @{ Input = 'DELETE ALL DATA'; Label = "'DELETE ALL DATA' (canonical)" }
    @{ Input = 'delete all data'; Label = "'delete all data' (lowercase)" }
    @{ Input = 'Delete All Data'; Label = "'Delete All Data' (title case)" }
    @{ Input = ' DELETE ALL DATA '; Label = "'DELETE ALL DATA' with wrapping spaces" }
)

foreach ($c in $acceptedCases) {
    $got = Test-FinalWipeConfirmationLocal -InputText $c.Input
    Write-Result -Test "Accepts $($c.Label)" -Pass ($got -eq $true) -Detail "got $got"
}

# ---------------------------------------------------------------------------
# Negative cases: everything else must be rejected
# ---------------------------------------------------------------------------

Write-Host "`n--- Rejected inputs (wipe cancelled) ---" -ForegroundColor Cyan

$rejectedCases = @(
    # Empty / null — Read-Host on Enter-with-no-input
    @{ Input = '';        Label = "empty string" }
    @{ Input = $null;     Label = "`$null" }
    @{ Input = '   ';     Label = "whitespace only" }

    # Wrong ceremony strings — DESTROY SYSTEM is a different prompt for the
    # system-disk override; WIPE ALL and WIPE DATA are the extra-wipe /
    # data-disk prompts. None of them should pass THIS parser.
    @{ Input = 'DESTROY SYSTEM'; Label = "'DESTROY SYSTEM' (belongs to a different prompt)" }
    @{ Input = 'WIPE ALL';       Label = "'WIPE ALL' (belongs to the extra-wipe prompt)" }
    @{ Input = 'WIPE DATA';      Label = "'WIPE DATA' (belongs to the data-disk prompt)" }

    # Common accidental affirmations — must NOT proceed with a destructive op
    @{ Input = 'YES'; Label = "'YES'" }
    @{ Input = 'yes'; Label = "'yes'" }
    @{ Input = 'Y';   Label = "'Y'" }
    @{ Input = 'y';   Label = "'y'" }
    @{ Input = 'OK';  Label = "'OK'" }
    @{ Input = '1';   Label = "'1'" }

    # Near-misses on the accepted strings — no substring or prefix match
    @{ Input = 'ERAS';           Label = "'ERAS' (prefix truncated)" }
    @{ Input = 'ERASEE';         Label = "'ERASEE' (extra suffix char)" }
    @{ Input = 'ERASE ME';       Label = "'ERASE ME' (extra suffix word)" }
    @{ Input = 'ERASE_1';        Label = "'ERASE_1' (extra suffix)" }
    @{ Input = 'DELETE';         Label = "'DELETE' alone" }
    @{ Input = 'DELETE ALL';     Label = "'DELETE ALL' (truncated)" }
    @{ Input = 'DELETEALLDATA';  Label = "'DELETEALLDATA' (spaces stripped)" }
    @{ Input = 'DELETE ALL DATAX'; Label = "'DELETE ALL DATAX' (extra char)" }

    # Trim() only strips outer whitespace — internal spacing changes must fail
    @{ Input = 'DELETE  ALL DATA'; Label = "double-spaced 'DELETE  ALL DATA'" }
)

foreach ($c in $rejectedCases) {
    $got = Test-FinalWipeConfirmationLocal -InputText $c.Input
    Write-Result -Test "Rejects $($c.Label)" -Pass ($got -eq $false) -Detail "got $got"
}

# ---------------------------------------------------------------------------
# Drift guard: safety-critical function shape must still live in the script
# ---------------------------------------------------------------------------

Write-Host "`n--- Drift guard ---" -ForegroundColor Cyan

if (-not (Test-Path $scriptPath)) {
    Write-Result -Test "Deploy script exists at $scriptPath" -Pass $false
} else {
    Write-Result -Test "Deploy script exists" -Pass $true
    $scriptText = Get-Content $scriptPath -Raw

    Write-Result -Test "Function 'Test-FinalWipeConfirmation' still defined" `
        -Pass ($scriptText -match 'function\s+Test-FinalWipeConfirmation\b') `
        -Detail "expected 'function Test-FinalWipeConfirmation'"

    Write-Result -Test "Normalizer still applies Trim() + ToUpperInvariant()" `
        -Pass ($scriptText -match '\.Trim\(\)\.ToUpperInvariant\(\)') `
        -Detail 'expected .Trim().ToUpperInvariant() pipeline'

    Write-Result -Test "Accepted set still includes 'ERASE'" `
        -Pass ($scriptText -match "'ERASE'\s*,\s*'DELETE ALL DATA'") `
        -Detail "expected @('ERASE', 'DELETE ALL DATA') literal in accepted list"

    # Both call sites must still route through the parser rather than an
    # inline comparison — an accidental refactor back to
    # `if ($finalConfirm -eq 'ERASE')` would drop case-insensitive /
    # trim-tolerant behavior for operators.
    $callSites = ([regex]::Matches($scriptText, 'Test-FinalWipeConfirmation\s+-InputText')).Count
    Write-Result -Test "Both Select-TargetDisk call sites still route through the parser (>=2)" `
        -Pass ($callSites -ge 2) `
        -Detail "found $callSites call site(s)"
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
