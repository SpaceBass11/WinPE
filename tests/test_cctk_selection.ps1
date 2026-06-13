<#
.SYNOPSIS
    Fixture test for the CCTK config-file selection precedence used by
    Invoke-CctkConfig in unified_winpe_deploy.ps1.
.DESCRIPTION
    Invoke-CctkConfig picks a per-machine .ini from the IMAGES partition's
    `cctk\` directory and feeds it to `cctk.exe --infile=`. Three safety
    properties matter:

      1. Precedence: <SERVICETAG>.ini wins over <MODEL>.ini wins over
         default.ini. A regression that flipped the order (model before
         tag, or default before either specific config) would silently
         apply the wrong BIOS settings to a fleet.
      2. Model normalization: Win32_ComputerSystem.Model is alnum-stripped
         and Trim()'d before lookup. A "Latitude 7430" should resolve to
         `Latitude7430.ini`. A refactor that dropped the strip would
         break every per-model config in the field.
      3. No-match fallback: if none of (tag.ini, model.ini, default.ini)
         exist, the function returns success and skips CCTK. A regression
         that hard-failed here would break every USB whose cctk\ folder
         only ships a couple of per-machine configs.

    No real cctk.exe, no real WMI, no real Dell hardware. The selection
    logic is mirrored from Invoke-CctkConfig into a self-contained
    function exercised against a temp directory of fixture .ini files.
    A drift guard at the bottom of this file confirms the safety-critical
    code shapes still live in the deploy script; if either side moves,
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

Write-Host "`n=== WinPE Deploy - CCTK Config Selection Tests ===" -ForegroundColor Cyan

# --- Model normalization (mirrors the alnum-strip in Invoke-CctkConfig) ---
function ConvertTo-NormalizedModel {
    param([string]$RawModel)
    if (-not $RawModel) { return $null }
    return ($RawModel -replace '[^A-Za-z0-9]', '').Trim()
}

# --- Selection logic (mirrors lines ~1319-1346 of Invoke-CctkConfig) ---
function Select-CctkConfig {
    param(
        [string]$CctkDir,
        [string]$ServiceTag,
        [string]$Model
    )
    if (-not (Test-Path $CctkDir)) {
        return [PSCustomObject]@{ Path = $null; Reason = 'no-cctk-dir' }
    }

    if ($ServiceTag) {
        $candidate = Join-Path $CctkDir "$ServiceTag.ini"
        if (Test-Path $candidate) {
            return [PSCustomObject]@{ Path = $candidate; Reason = "service tag $ServiceTag" }
        }
    }
    if ($Model) {
        $candidate = Join-Path $CctkDir "$Model.ini"
        if (Test-Path $candidate) {
            return [PSCustomObject]@{ Path = $candidate; Reason = "model $Model" }
        }
    }
    $candidate = Join-Path $CctkDir 'default.ini'
    if (Test-Path $candidate) {
        return [PSCustomObject]@{ Path = $candidate; Reason = 'default' }
    }

    return [PSCustomObject]@{ Path = $null; Reason = 'no-match' }
}

# ---------------------------------------------------------------------------
# Model normalization
# ---------------------------------------------------------------------------

Write-Host "`n--- Model normalization (Win32_ComputerSystem.Model -> filename stem) ---" -ForegroundColor Cyan

$normCases = @(
    @{ Raw = 'Latitude 7430';           Expected = 'Latitude7430'   ; Label = 'space stripped' }
    @{ Raw = 'OptiPlex 7090';           Expected = 'OptiPlex7090'   ; Label = 'OptiPlex with digits' }
    @{ Raw = 'Precision-3460';          Expected = 'Precision3460'  ; Label = 'hyphen stripped' }
    @{ Raw = 'XPS 13 (9310)';           Expected = 'XPS139310'      ; Label = 'parentheses + space stripped' }
    @{ Raw = '  Latitude 7430  ';       Expected = 'Latitude7430'   ; Label = 'leading/trailing whitespace stripped' }
    @{ Raw = 'Inspiron_15_5000';        Expected = 'Inspiron155000' ; Label = 'underscores stripped' }
    @{ Raw = '';                        Expected = $null            ; Label = 'empty model returns null' }
    @{ Raw = $null;                     Expected = $null            ; Label = 'null model returns null' }
)

foreach ($c in $normCases) {
    $got = ConvertTo-NormalizedModel -RawModel $c.Raw
    Write-Result -Test "Normalize '$($c.Raw)' -> '$($c.Expected)' ($($c.Label))" `
        -Pass ($got -eq $c.Expected) -Detail "got '$got'"
}

# ---------------------------------------------------------------------------
# Selection precedence
# ---------------------------------------------------------------------------

Write-Host "`n--- Selection precedence (tag > model > default > none) ---" -ForegroundColor Cyan

# Build a temp cctk\ directory and stage fixture .ini files into it. Each
# test toggles which files exist by re-creating the directory and writing
# only the .ini's relevant to that case. Using a real filesystem (not a
# Test-Path mock) is intentional - the deploy script's Test-Path call is
# what we're locking in.
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cctk-test-" + [Guid]::NewGuid().ToString())
$cctkDir  = Join-Path $tempRoot 'cctk'

function Reset-Fixture {
    param([string[]]$IniFiles)
    if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $cctkDir -Force | Out-Null
    foreach ($f in $IniFiles) {
        $p = Join-Path $cctkDir $f
        Set-Content -Path $p -Value "# fixture $f" -Encoding ASCII
    }
}

try {
    # 1) Tag wins: tag.ini + model.ini + default.ini all present -> picks tag.
    Reset-Fixture -IniFiles @('ABC1234.ini', 'Latitude7430.ini', 'default.ini')
    $r = Select-CctkConfig -CctkDir $cctkDir -ServiceTag 'ABC1234' -Model 'Latitude7430'
    Write-Result -Test "Tag wins over model + default" `
        -Pass ($r.Path -eq (Join-Path $cctkDir 'ABC1234.ini')) -Detail "got '$($r.Path)' reason '$($r.Reason)'"
    Write-Result -Test "Tag-match reason names the tag" `
        -Pass ($r.Reason -eq 'service tag ABC1234') -Detail "got '$($r.Reason)'"

    # 2) Model wins when no tag file: model.ini + default.ini present, tag absent.
    Reset-Fixture -IniFiles @('Latitude7430.ini', 'default.ini')
    $r = Select-CctkConfig -CctkDir $cctkDir -ServiceTag 'ABC1234' -Model 'Latitude7430'
    Write-Result -Test "Model wins over default when no tag.ini" `
        -Pass ($r.Path -eq (Join-Path $cctkDir 'Latitude7430.ini')) -Detail "got '$($r.Path)' reason '$($r.Reason)'"
    Write-Result -Test "Model-match reason names the model" `
        -Pass ($r.Reason -eq 'model Latitude7430') -Detail "got '$($r.Reason)'"

    # 3) Default wins when neither tag nor model file present.
    Reset-Fixture -IniFiles @('default.ini')
    $r = Select-CctkConfig -CctkDir $cctkDir -ServiceTag 'ABC1234' -Model 'Latitude7430'
    Write-Result -Test "Default picked when no tag.ini and no model.ini" `
        -Pass ($r.Path -eq (Join-Path $cctkDir 'default.ini')) -Detail "got '$($r.Path)' reason '$($r.Reason)'"
    Write-Result -Test "Default-match reason is literally 'default'" `
        -Pass ($r.Reason -eq 'default') -Detail "got '$($r.Reason)'"

    # 4) No match: directory is empty -> Path null, Reason no-match.
    Reset-Fixture -IniFiles @()
    $r = Select-CctkConfig -CctkDir $cctkDir -ServiceTag 'ABC1234' -Model 'Latitude7430'
    Write-Result -Test "No .ini files -> Path null" `
        -Pass ($null -eq $r.Path) -Detail "got '$($r.Path)'"
    Write-Result -Test "No .ini files -> Reason 'no-match'" `
        -Pass ($r.Reason -eq 'no-match') -Detail "got '$($r.Reason)'"

    # 5) Tag missing (null/empty service tag): falls through to model.
    Reset-Fixture -IniFiles @('Latitude7430.ini', 'default.ini')
    $r = Select-CctkConfig -CctkDir $cctkDir -ServiceTag $null -Model 'Latitude7430'
    Write-Result -Test "Null service tag -> falls to model match" `
        -Pass ($r.Path -eq (Join-Path $cctkDir 'Latitude7430.ini')) -Detail "got '$($r.Path)'"
    $r = Select-CctkConfig -CctkDir $cctkDir -ServiceTag '' -Model 'Latitude7430'
    Write-Result -Test "Empty service tag -> falls to model match" `
        -Pass ($r.Path -eq (Join-Path $cctkDir 'Latitude7430.ini')) -Detail "got '$($r.Path)'"

    # 6) Both tag + model null/empty: only default applies.
    Reset-Fixture -IniFiles @('default.ini')
    $r = Select-CctkConfig -CctkDir $cctkDir -ServiceTag $null -Model $null
    Write-Result -Test "Null tag + null model -> default" `
        -Pass ($r.Path -eq (Join-Path $cctkDir 'default.ini')) -Detail "got '$($r.Path)' reason '$($r.Reason)'"

    # 7) Both tag + model null/empty, no default: no-match.
    Reset-Fixture -IniFiles @('Latitude7430.ini')
    $r = Select-CctkConfig -CctkDir $cctkDir -ServiceTag $null -Model $null
    Write-Result -Test "Null tag + null model + no default -> no-match" `
        -Pass ($null -eq $r.Path -and $r.Reason -eq 'no-match') `
        -Detail "got Path='$($r.Path)' Reason='$($r.Reason)'"

    # 8) cctk directory missing entirely: distinct 'no-cctk-dir' reason.
    Remove-Item $tempRoot -Recurse -Force
    $r = Select-CctkConfig -CctkDir $cctkDir -ServiceTag 'ABC1234' -Model 'Latitude7430'
    Write-Result -Test "Missing cctk dir -> Path null" `
        -Pass ($null -eq $r.Path) -Detail "got '$($r.Path)'"
    Write-Result -Test "Missing cctk dir -> Reason 'no-cctk-dir'" `
        -Pass ($r.Reason -eq 'no-cctk-dir') -Detail "got '$($r.Reason)'"

    # 9) End-to-end: raw model string through normalizer + selector.
    Reset-Fixture -IniFiles @('Latitude7430.ini', 'default.ini')
    $normalized = ConvertTo-NormalizedModel -RawModel 'Latitude 7430'
    $r = Select-CctkConfig -CctkDir $cctkDir -ServiceTag $null -Model $normalized
    Write-Result -Test "'Latitude 7430' -> normalized 'Latitude7430' -> Latitude7430.ini" `
        -Pass ($r.Path -eq (Join-Path $cctkDir 'Latitude7430.ini')) `
        -Detail "got '$($r.Path)' normalized='$normalized'"
} finally {
    if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# Drift guard: safety-critical code shapes must still live in the deploy script
# ---------------------------------------------------------------------------

Write-Host "`n--- Drift guard ---" -ForegroundColor Cyan

if (-not (Test-Path $scriptPath)) {
    Write-Result -Test "Deploy script exists at $scriptPath" -Pass $false
} else {
    Write-Result -Test "Deploy script exists" -Pass $true
    $scriptText = Get-Content $scriptPath -Raw

    Write-Result -Test "Invoke-CctkConfig function still defined" `
        -Pass ($scriptText -match 'function\s+Invoke-CctkConfig') `
        -Detail 'expected: function Invoke-CctkConfig'

    Write-Result -Test "Service-tag .ini lookup still uses Win32_BIOS.SerialNumber" `
        -Pass ($scriptText -match "Get-WmiObject -Class Win32_BIOS") `
        -Detail 'expected: Get-WmiObject -Class Win32_BIOS'

    Write-Result -Test "Model lookup still uses Win32_ComputerSystem.Model" `
        -Pass ($scriptText -match "Get-WmiObject -Class Win32_ComputerSystem") `
        -Detail 'expected: Get-WmiObject -Class Win32_ComputerSystem'

    Write-Result -Test "Model normalization (alnum strip) still present" `
        -Pass ($scriptText -match "-replace '\[\^A-Za-z0-9\]', ''") `
        -Detail "expected: -replace '[^A-Za-z0-9]', ''"

    Write-Result -Test "Service-tag .ini candidate path still constructed" `
        -Pass ($scriptText -match '"\$serviceTag\.ini"') `
        -Detail 'expected: Join-Path $cctkDir "$serviceTag.ini"'

    Write-Result -Test "Model .ini candidate path still constructed" `
        -Pass ($scriptText -match '"\$model\.ini"') `
        -Detail 'expected: Join-Path $cctkDir "$model.ini"'

    Write-Result -Test "default.ini fallback literal still present" `
        -Pass ($scriptText -match "'default\.ini'") `
        -Detail "expected: 'default.ini'"

    # Precedence: tag block must precede model block must precede default block.
    $tagIdx     = $scriptText.IndexOf('"$serviceTag.ini"')
    $modelIdx   = $scriptText.IndexOf('"$model.ini"')
    $defaultIdx = $scriptText.IndexOf("'default.ini'")
    Write-Result -Test "Selection order in source: tag block precedes model block" `
        -Pass ($tagIdx -gt 0 -and $modelIdx -gt 0 -and $tagIdx -lt $modelIdx) `
        -Detail "tagIdx=$tagIdx modelIdx=$modelIdx"
    Write-Result -Test "Selection order in source: model block precedes default block" `
        -Pass ($modelIdx -gt 0 -and $defaultIdx -gt 0 -and $modelIdx -lt $defaultIdx) `
        -Detail "modelIdx=$modelIdx defaultIdx=$defaultIdx"

    Write-Result -Test "Non-zero cctk exit still aborts the deploy" `
        -Pass ($scriptText -match 'CCTK returned exit code') `
        -Detail "expected: 'CCTK returned exit code <N> - aborting deploy'"
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
