<#
.SYNOPSIS
    Fixture test for the CCTK config-file selection logic in
    Invoke-CctkConfig (unified_winpe_deploy.ps1).
.DESCRIPTION
    Invoke-CctkConfig picks a per-deploy BIOS config from <IMAGES>\cctk\
    using two pieces of host identity and a three-tier precedence:

      1. <SERVICETAG>.ini   (Win32_BIOS.SerialNumber.Trim())
      2. <MODEL>.ini        (Win32_ComputerSystem.Model run through
                              `-replace '[^A-Za-z0-9]', ''` then .Trim())
      3. default.ini        (catch-all)

    Two safety properties matter for fleets:

      a. The model-normalization regex must strip ALL non-alphanumeric
         characters so on-disk filenames stay portable across vendors
         that quote model names with spaces, hyphens, parentheses, or
         underscores. A regex drift would silently break per-model
         rollouts (the file's there, the host's there, the wrong one
         loads or none loads).

      b. The precedence must be tag > model > default - never the other
         way around. A precedence flip would let a stale default.ini
         override a per-machine tag override that the operator added
         specifically to fix that one box.

    Pure fixture, no real WMI, no real BIOS. Mirrors the same
    no-Pester pattern as tests/test_disk_enumeration.ps1 and
    tests/test_wim_parser.ps1, so it adds no new CI dependencies.
    Drift guard at the bottom asserts the regex and the selection
    chain still live in the deploy script.

    Works with PowerShell 5.1 and 7+. Returns exit code 0 on success,
    1 on failure.
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

Write-Host "`n=== WinPE Deploy - CCTK Config Selection Tests ===" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Identity normalization (mirrors the Get-WmiObject post-processing in
# Invoke-CctkConfig: service-tag .Trim(), model alnum-only + .Trim())
# ---------------------------------------------------------------------------

function ConvertTo-CctkServiceTag {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    return $Raw.Trim()
}

function ConvertTo-CctkModelKey {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    return ($Raw -replace '[^A-Za-z0-9]', '').Trim()
}

Write-Host "`n--- Service-tag normalization (.Trim()) ---" -ForegroundColor Cyan

$tagFixtures = @(
    @{ Label = 'plain Dell tag';                    Raw = 'ABC1234';      Expected = 'ABC1234' }
    @{ Label = 'leading/trailing whitespace';       Raw = '  ABC1234  ';  Expected = 'ABC1234' }
    @{ Label = 'tab-padded tag';                    Raw = "`tXYZ9876`t";  Expected = 'XYZ9876' }
    @{ Label = 'empty string';                      Raw = '';             Expected = $null }
    @{ Label = '$null SerialNumber (no BIOS read)'; Raw = $null;          Expected = $null }
    @{ Label = 'whitespace-only stays as empty';    Raw = '   ';          Expected = '' }
)
foreach ($f in $tagFixtures) {
    $actual = ConvertTo-CctkServiceTag -Raw $f.Raw
    Write-Result -Test "Tag '$($f.Label)' -> '$($f.Expected)'" `
        -Pass ($actual -eq $f.Expected) `
        -Detail "got '$actual'"
}

Write-Host "`n--- Model normalization (alnum-only + .Trim()) ---" -ForegroundColor Cyan

$modelFixtures = @(
    # Real-world model strings seen in the field
    @{ Label = 'Dell Latitude with space';          Raw = 'Latitude 5520';            Expected = 'Latitude5520' }
    @{ Label = 'Dell OptiPlex with space';          Raw = 'OptiPlex 7090';            Expected = 'OptiPlex7090' }
    @{ Label = 'Dell Precision multi-space';        Raw = 'Precision 5560 Mobile';    Expected = 'Precision5560Mobile' }
    @{ Label = 'underscore-padded';                 Raw = 'Latitude_5520';            Expected = 'Latitude5520' }
    @{ Label = 'hyphenated';                        Raw = 'Inspiron-15-3000';         Expected = 'Inspiron153000' }
    @{ Label = 'parens';                            Raw = 'XPS 13 (9310)';            Expected = 'XPS139310' }
    @{ Label = 'period in model';                   Raw = 'PowerEdge R740xd 2.5"';    Expected = 'PowerEdgeR740xd25' }
    @{ Label = 'leading/trailing whitespace';       Raw = '  Latitude 7420  ';        Expected = 'Latitude7420' }
    @{ Label = 'tab-padded model';                  Raw = "`tDell OptiPlex 3070`t";   Expected = 'DellOptiPlex3070' }
    # Non-Latin characters get stripped too — keeps Join-Path filenames
    # portable. (Vendors occasionally ship Unicode model strings.)
    @{ Label = 'Unicode chars stripped';            Raw = 'Café-Box 9000';            Expected = 'CafBox9000' }
    # Edge cases
    @{ Label = 'empty string';                      Raw = '';                         Expected = $null }
    @{ Label = '$null Model';                       Raw = $null;                      Expected = $null }
    @{ Label = 'only punctuation collapses empty';  Raw = '----';                     Expected = '' }
)
foreach ($f in $modelFixtures) {
    $actual = ConvertTo-CctkModelKey -Raw $f.Raw
    Write-Result -Test "Model '$($f.Label)' -> '$($f.Expected)'" `
        -Pass ($actual -eq $f.Expected) `
        -Detail "got '$actual'"
}

# ---------------------------------------------------------------------------
# Selection precedence (mirrors the three-tier lookup in Invoke-CctkConfig)
# ---------------------------------------------------------------------------

# Helper that mirrors the script's selection chain. Resolves to a hashtable
# with the chosen file's basename and a human-readable reason, or $null when
# nothing matched (caller skips CCTK).
function Select-CctkConfig {
    param(
        [string]$ServiceTag,
        [string]$Model,
        [string[]]$AvailableFiles  # filenames present in the cctk\ dir
    )

    if ($ServiceTag) {
        $candidate = "$ServiceTag.ini"
        if ($AvailableFiles -contains $candidate) {
            return @{ File = $candidate; Reason = "service tag $ServiceTag" }
        }
    }
    if ($Model) {
        $candidate = "$Model.ini"
        if ($AvailableFiles -contains $candidate) {
            return @{ File = $candidate; Reason = "model $Model" }
        }
    }
    if ($AvailableFiles -contains 'default.ini') {
        return @{ File = 'default.ini'; Reason = 'default' }
    }
    return $null
}

Write-Host "`n--- Selection precedence (tag > model > default > none) ---" -ForegroundColor Cyan

# All three present: tag wins.
$r = Select-CctkConfig -ServiceTag 'ABC1234' -Model 'Latitude5520' `
    -AvailableFiles @('ABC1234.ini', 'Latitude5520.ini', 'default.ini')
Write-Result -Test "All three present: tag wins" `
    -Pass ($r.File -eq 'ABC1234.ini' -and $r.Reason -like 'service tag*') `
    -Detail "file='$($r.File)' reason='$($r.Reason)'"

# Tag missing on disk, model present: model wins.
$r = Select-CctkConfig -ServiceTag 'ABC1234' -Model 'Latitude5520' `
    -AvailableFiles @('Latitude5520.ini', 'default.ini')
Write-Result -Test "Tag.ini absent: model wins over default" `
    -Pass ($r.File -eq 'Latitude5520.ini' -and $r.Reason -like 'model*') `
    -Detail "file='$($r.File)' reason='$($r.Reason)'"

# Tag and model missing on disk: default wins.
$r = Select-CctkConfig -ServiceTag 'ABC1234' -Model 'Latitude5520' `
    -AvailableFiles @('default.ini')
Write-Result -Test "Tag.ini and model.ini absent: default wins" `
    -Pass ($r.File -eq 'default.ini' -and $r.Reason -eq 'default') `
    -Detail "file='$($r.File)' reason='$($r.Reason)'"

# Nothing present at all: $null (caller logs "no config matched - skipping").
$r = Select-CctkConfig -ServiceTag 'ABC1234' -Model 'Latitude5520' `
    -AvailableFiles @()
Write-Result -Test "Nothing matches: returns null (skip CCTK)" `
    -Pass ($null -eq $r) `
    -Detail "got '$($r.File)'"

# Tag empty/null (Get-WmiObject failed): falls through to model.
$r = Select-CctkConfig -ServiceTag $null -Model 'Latitude5520' `
    -AvailableFiles @('Latitude5520.ini', 'default.ini')
Write-Result -Test "Empty service tag: model wins" `
    -Pass ($r.File -eq 'Latitude5520.ini') `
    -Detail "file='$($r.File)'"

$r = Select-CctkConfig -ServiceTag '' -Model 'Latitude5520' `
    -AvailableFiles @('Latitude5520.ini', 'default.ini')
Write-Result -Test "Whitespace-trimmed-to-empty tag: model wins" `
    -Pass ($r.File -eq 'Latitude5520.ini') `
    -Detail "file='$($r.File)'"

# Tag and model both empty: falls through to default.
$r = Select-CctkConfig -ServiceTag $null -Model $null `
    -AvailableFiles @('default.ini')
Write-Result -Test "Both tag and model null: default wins" `
    -Pass ($r.File -eq 'default.ini') `
    -Detail "file='$($r.File)'"

$r = Select-CctkConfig -ServiceTag $null -Model $null `
    -AvailableFiles @()
Write-Result -Test "Both tag and model null, no default: skip" `
    -Pass ($null -eq $r) `
    -Detail "got '$($r.File)'"

# Mixed-case .ini extension on disk: filename match is exact (case-sensitive
# in our -contains check, but Windows filesystems are case-insensitive so
# this mirrors what Test-Path would actually find). Using same-case here
# matches how operators name their fleet configs - the test pins the
# documented convention rather than coincidentally passing on Windows.
$r = Select-CctkConfig -ServiceTag 'ABC1234' -Model $null `
    -AvailableFiles @('ABC1234.ini')
Write-Result -Test "Tag-only match: tag wins, no model evaluated" `
    -Pass ($r.File -eq 'ABC1234.ini') `
    -Detail "file='$($r.File)'"

# ---------------------------------------------------------------------------
# Round-trip: a raw model string from WMI normalizes to a key that picks
# the matching on-disk file. Guards against a regex that strips too much
# or too little.
# ---------------------------------------------------------------------------

Write-Host "`n--- Round-trip: raw model -> normalized key -> file pick ---" -ForegroundColor Cyan

$roundTripCases = @(
    @{ Raw = 'Latitude 5520';           File = 'Latitude5520.ini' }
    @{ Raw = 'OptiPlex 7090';           File = 'OptiPlex7090.ini' }
    @{ Raw = 'XPS 13 (9310)';           File = 'XPS139310.ini' }
    @{ Raw = 'Precision 5560 Mobile';   File = 'Precision5560Mobile.ini' }
)
foreach ($c in $roundTripCases) {
    $key = ConvertTo-CctkModelKey -Raw $c.Raw
    $r = Select-CctkConfig -ServiceTag $null -Model $key -AvailableFiles @($c.File)
    Write-Result -Test "Raw '$($c.Raw)' normalizes and picks '$($c.File)'" `
        -Pass ($r.File -eq $c.File) `
        -Detail "key='$key' picked='$($r.File)'"
}

# ---------------------------------------------------------------------------
# Drift guard: regex + chain shape must still live in the deploy script
# ---------------------------------------------------------------------------

Write-Host "`n--- Drift guard ---" -ForegroundColor Cyan

if (-not (Test-Path $scriptPath)) {
    Write-Result -Test "Deploy script exists at $scriptPath" -Pass $false
} else {
    Write-Result -Test "Deploy script exists" -Pass $true
    $scriptText = Get-Content $scriptPath -Raw

    # Model alnum-only regex — the load-bearing normalization.
    Write-Result -Test "Model alnum regex still '[^A-Za-z0-9]' (strips everything non-alphanumeric)" `
        -Pass ($scriptText -match "-replace\s+'\[\^A-Za-z0-9\]',\s*''") `
        -Detail "expected -replace '[^A-Za-z0-9]', ''"

    # Service-tag trim — minimal but load-bearing for filename match.
    Write-Result -Test "Service-tag .Trim() still present" `
        -Pass ($scriptText -match '\$serviceTag\s*=\s*\$serviceTag\.Trim\(\)') `
        -Detail 'expected $serviceTag = $serviceTag.Trim()'

    # Precedence chain markers - the human-readable reason strings the
    # operator sees in the log. If these drift the log gets confusing; if
    # they vanish the precedence has been refactored and the test needs a
    # second look.
    Write-Result -Test "Precedence chain: 'service tag' reason string present" `
        -Pass ($scriptText -match 'service tag \$serviceTag') `
        -Detail "expected 'service tag \$serviceTag' literal"

    Write-Result -Test "Precedence chain: 'model' reason string present" `
        -Pass ($scriptText -match '"model \$model"') `
        -Detail "expected '\"model \$model\"' literal"

    Write-Result -Test "Precedence chain: 'default' reason string present" `
        -Pass ($scriptText -match "'default'") `
        -Detail "expected 'default' literal"

    Write-Result -Test "default.ini filename literal still present" `
        -Pass ($scriptText -match "'default\.ini'") `
        -Detail "expected 'default.ini' literal"

    # The "no config matched" skip branch — the safe default when none of the
    # three tiers fire. If this is gone, the deploy may try to run cctk.exe
    # against a missing file and crash.
    Write-Result -Test "'No CCTK config matched' skip branch still present" `
        -Pass ($scriptText -match 'No CCTK config matched') `
        -Detail "expected 'No CCTK config matched' log line"
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
