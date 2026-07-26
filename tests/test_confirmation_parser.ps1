<#
.SYNOPSIS
    Fixture test for Test-FinalWipeConfirmation - the typed-confirmation
    parser that gates every disk-erase step in unified_winpe_deploy.ps1.

.DESCRIPTION
    Test-FinalWipeConfirmation is the single accept/reject gate between
    the operator typing at the "ERASE" prompt and the script proceeding
    to Invoke-Diskpart. A silent regression there (accepting empty
    input, becoming case-sensitive without a matching prompt change,
    dropping one of the two accepted strings, etc.) would either
    bypass the confirmation entirely or break the documented UX
    without the parse tests noticing.

    This test loads the deploy script as a dynamic module (same pattern
    as validation-gates.Tests.ps1: strip the auto-exec block plus the
    #Requires -RunAsAdministrator so the body can evaluate outside an
    admin shell), then feeds the real function a table of inputs and
    asserts the accept/reject outcome for each.

    A drift guard at the end confirms both accepted strings ('ERASE'
    and 'DELETE ALL DATA') still appear in the deploy script - if a
    refactor removes one, the guard fails and forces the test to be
    updated.

    Standalone PowerShell (no Pester dependency), matching
    test_wim_parser.ps1 and test_disk_enumeration.ps1. Works on
    PowerShell 5.1+. Returns 0 on success, 1 on failure.
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

Write-Host "`n=== WinPE Deploy - Confirmation Parser Tests ===" -ForegroundColor Cyan

if (-not (Test-Path $scriptPath)) {
    Write-Host "  [FAIL] Deploy script not found at $scriptPath" -ForegroundColor Red
    exit 1
}

# --- Load the deploy script as a dynamic module ---
# Strip the auto-execute block at the bottom and the #Requires
# -RunAsAdministrator directive so the body evaluates outside an
# elevated shell. Same seam validation-gates.Tests.ps1 uses.
$raw = Get-Content -Path $scriptPath -Raw
$marker = '# Execute main process'
$cut = $raw.IndexOf($marker)
if ($cut -lt 0) {
    Write-Host "  [FAIL] Test seam marker '$marker' missing from script" -ForegroundColor Red
    exit 1
}
$body = $raw.Substring(0, $cut) -replace '(?m)^#Requires\s+-RunAsAdministrator\s*$', ''

$module = New-Module -Name 'DeployConfirmationTest' -ScriptBlock ([scriptblock]::Create($body)) |
    Import-Module -PassThru

try {
    # --- Cases the parser MUST accept ---
    # Cover the two canonical inputs plus the normalization the function
    # documents: leading/trailing whitespace stripped, case folded.
    $accept = @(
        @{ Label = "exact 'ERASE'";                    Input = 'ERASE' },
        @{ Label = "lowercase 'erase'";                Input = 'erase' },
        @{ Label = "mixed case 'Erase'";               Input = 'Erase' },
        @{ Label = "surrounded by spaces '  ERASE  '"; Input = '  ERASE  ' },
        @{ Label = "surrounded by tabs";               Input = "`tERASE`t" },
        @{ Label = "exact 'DELETE ALL DATA'";          Input = 'DELETE ALL DATA' },
        @{ Label = "lowercase 'delete all data'";      Input = 'delete all data' },
        @{ Label = "title case 'Delete All Data'";     Input = 'Delete All Data' },
        @{ Label = "'DELETE ALL DATA' + trailing space"; Input = 'DELETE ALL DATA ' }
    )

    Write-Host "`n--- Must accept ---" -ForegroundColor Cyan
    foreach ($c in $accept) {
        $got = & $module { param($s) Test-FinalWipeConfirmation -InputText $s } $c.Input
        Write-Result -Test "accepts: $($c.Label)" -Pass ($got -eq $true) -Detail "got $got"
    }

    # --- Cases the parser MUST reject ---
    # Empty / null must never green-light a wipe (no accidental
    # bare-Enter through the prompt). Common near-matches must all
    # fail: partial phrases, extra punctuation, extra characters,
    # broken internal whitespace (double-space rejection is not a
    # deliberate feature but pinning it here catches an accidental
    # regex slip that would loosen input to a much wider set).
    $reject = @(
        @{ Label = "empty string";                     Input = '' },
        @{ Label = "null input";                       Input = $null },
        @{ Label = "generic 'yes'";                    Input = 'yes' },
        @{ Label = "single 'y'";                       Input = 'y' },
        @{ Label = "'OK'";                             Input = 'OK' },
        @{ Label = "'ERASE' + trailing punctuation";   Input = 'ERASE!' },
        @{ Label = "'ERASE' + suffix";                 Input = 'ERASEit' },
        @{ Label = "prefix + 'ERASE'";                 Input = 'DO ERASE' },
        @{ Label = "partial 'DELETE'";                 Input = 'DELETE' },
        @{ Label = "partial 'DELETE ALL'";             Input = 'DELETE ALL' },
        @{ Label = "double-spaced 'DELETE  ALL  DATA'"; Input = 'DELETE  ALL  DATA' },
        @{ Label = "'DESTROY SYSTEM' (different gate)"; Input = 'DESTROY SYSTEM' },
        @{ Label = "'WIPE ALL' (different gate)";      Input = 'WIPE ALL' },
        @{ Label = "'WIPE DATA' (different gate)";     Input = 'WIPE DATA' },
        @{ Label = "single whitespace char";           Input = ' ' }
    )

    Write-Host "`n--- Must reject ---" -ForegroundColor Cyan
    foreach ($c in $reject) {
        $got = & $module { param($s) Test-FinalWipeConfirmation -InputText $s } $c.Input
        Write-Result -Test "rejects: $($c.Label)" -Pass ($got -eq $false) -Detail "got $got"
    }
}
finally {
    if ($module) {
        Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
    }
}

# --- Drift guard ---
# Confirm the two accepted strings still live inside the function body
# in the deploy script. If a maintainer drops one from the -in list
# (or renames the function) the guard fails, forcing the test and the
# operator-facing prompts to stay in sync.
Write-Host "`n--- Drift guard ---" -ForegroundColor Cyan
$scriptText = Get-Content $scriptPath -Raw
if ($scriptText -match '(?ms)function\s+Test-FinalWipeConfirmation\s*\{(.*?)\n\}') {
    $fnBody = $Matches[1]
    Write-Result -Test "Test-FinalWipeConfirmation function body located" -Pass $true
    Write-Result -Test "Function body contains 'ERASE'"           -Pass ($fnBody -match "'ERASE'")
    Write-Result -Test "Function body contains 'DELETE ALL DATA'" -Pass ($fnBody -match "'DELETE ALL DATA'")
} else {
    Write-Result -Test "Test-FinalWipeConfirmation function body located" -Pass $false -Detail 'regex missed the function - update the drift guard or the deploy script'
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
