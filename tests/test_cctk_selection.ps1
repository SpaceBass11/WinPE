<#
.SYNOPSIS
    Fixture test for the CCTK config-selection precedence in
    Invoke-CctkConfig (unified_winpe_deploy.ps1).
.DESCRIPTION
    Invoke-CctkConfig picks which .ini file cctk.exe gets fed at
    pre-deploy time. The precedence, per docs/CCTK.md, is:

      1. <SERVICETAG>.ini  (Win32_BIOS.SerialNumber, verbatim)
      2. <MODEL>.ini       (Win32_ComputerSystem.Model, non-alnum stripped)
      3. default.ini       (catch-all)
      4. none              -> skip CCTK, continue to deploy

    A regression in this ordering (or in the model normalization) can
    apply the wrong BIOS config to a machine — e.g. push an OptiPlex
    config onto a Latitude, or silently ignore a per-service-tag
    override. Neither test_parse.ps1 nor validation-gates.Tests.ps1
    covers behavior; masterize check #13 only verifies ordering
    relative to disk selection.

    No real WMI, no real cctk.exe, no boot.wim. The selection
    predicate and the model normalizer are mirrored here in helper
    functions that match the deploy script's Invoke-CctkConfig body
    verbatim. A drift guard at the bottom pins the code shapes still
    live in unified_winpe_deploy.ps1; if either side moves, the
    guard fails and forces the test to be updated.

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

# ---------------------------------------------------------------------------
# Helpers that MIRROR Invoke-CctkConfig
# ---------------------------------------------------------------------------

# Mirrors the alnum normalizer at unified_winpe_deploy.ps1:
#   $model = ($rawModel -replace '[^A-Za-z0-9]', '').Trim()
function Get-NormalizedModel {
    param([string]$RawModel)
    if ([string]::IsNullOrEmpty($RawModel)) { return '' }
    return (($RawModel -replace '[^A-Za-z0-9]', '').Trim())
}

# Mirrors the three-step precedence block in Invoke-CctkConfig:
#   1. <SERVICETAG>.ini
#   2. <MODEL>.ini
#   3. default.ini
#   otherwise: $null (caller returns $true and skips CCTK)
function Select-CctkConfig {
    param(
        [string]$CctkDir,
        [string]$ServiceTag,
        [string]$Model
    )
    $configPath  = $null
    $matchReason = $null

    if ($ServiceTag) {
        $candidate = Join-Path $CctkDir "$ServiceTag.ini"
        if (Test-Path $candidate) {
            $configPath  = $candidate
            $matchReason = "service tag $ServiceTag"
        }
    }
    if (-not $configPath -and $Model) {
        $candidate = Join-Path $CctkDir "$Model.ini"
        if (Test-Path $candidate) {
            $configPath  = $candidate
            $matchReason = "model $Model"
        }
    }
    if (-not $configPath) {
        $candidate = Join-Path $CctkDir 'default.ini'
        if (Test-Path $candidate) {
            $configPath  = $candidate
            $matchReason = 'default'
        }
    }

    return [PSCustomObject]@{
        Path   = $configPath
        Reason = $matchReason
    }
}

# ---------------------------------------------------------------------------
# Fixture directory (real files, since the selector uses Test-Path)
# ---------------------------------------------------------------------------

$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cctk-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null

function New-CctkFixtureFile {
    param([string]$Name)
    $p = Join-Path $fixtureDir $Name
    # Content is irrelevant to the selector - only Test-Path matters.
    Set-Content -Path $p -Value "; fixture $Name" -Encoding ASCII -Force
    return $p
}

function Clear-CctkFixture {
    Get-ChildItem -Path $fixtureDir -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

try {
    # -----------------------------------------------------------------------
    # Precedence: SERVICETAG wins over MODEL and default
    # -----------------------------------------------------------------------

    Write-Host "`n--- Precedence: service tag wins ---" -ForegroundColor Cyan

    Clear-CctkFixture
    $stagPath    = New-CctkFixtureFile '1A2B3C4.ini'
    $modelPath   = New-CctkFixtureFile 'OptiPlex7090.ini'
    $defaultPath = New-CctkFixtureFile 'default.ini'

    $r = Select-CctkConfig -CctkDir $fixtureDir -ServiceTag '1A2B3C4' -Model 'OptiPlex7090'
    Write-Result -Test "All three files present -> service tag file wins" `
        -Pass ($r.Path -eq $stagPath) -Detail "got '$($r.Path)'"
    Write-Result -Test "Service tag reason mentions the tag" `
        -Pass ($r.Reason -eq 'service tag 1A2B3C4') -Detail "got '$($r.Reason)'"

    # -----------------------------------------------------------------------
    # Precedence: MODEL wins over default when no service tag file exists
    # -----------------------------------------------------------------------

    Write-Host "`n--- Precedence: model wins over default ---" -ForegroundColor Cyan

    Clear-CctkFixture
    $modelPath   = New-CctkFixtureFile 'OptiPlex7090.ini'
    $defaultPath = New-CctkFixtureFile 'default.ini'

    $r = Select-CctkConfig -CctkDir $fixtureDir -ServiceTag '1A2B3C4' -Model 'OptiPlex7090'
    Write-Result -Test "No service-tag file -> model file wins over default" `
        -Pass ($r.Path -eq $modelPath) -Detail "got '$($r.Path)'"
    Write-Result -Test "Model reason mentions the model" `
        -Pass ($r.Reason -eq 'model OptiPlex7090') -Detail "got '$($r.Reason)'"

    # -----------------------------------------------------------------------
    # Precedence: default is the last resort
    # -----------------------------------------------------------------------

    Write-Host "`n--- Precedence: default is the fallback ---" -ForegroundColor Cyan

    Clear-CctkFixture
    $defaultPath = New-CctkFixtureFile 'default.ini'

    $r = Select-CctkConfig -CctkDir $fixtureDir -ServiceTag '1A2B3C4' -Model 'Latitude7420'
    Write-Result -Test "Only default.ini present -> default wins" `
        -Pass ($r.Path -eq $defaultPath) -Detail "got '$($r.Path)'"
    Write-Result -Test "Default reason literal is 'default'" `
        -Pass ($r.Reason -eq 'default') -Detail "got '$($r.Reason)'"

    # -----------------------------------------------------------------------
    # No match -> null (caller skips CCTK without aborting the deploy)
    # -----------------------------------------------------------------------

    Write-Host "`n--- No match: safe skip ---" -ForegroundColor Cyan

    Clear-CctkFixture
    $unrelated = New-CctkFixtureFile 'someOtherFile.ini'

    $r = Select-CctkConfig -CctkDir $fixtureDir -ServiceTag 'AAA' -Model 'BBB'
    Write-Result -Test "No matching file -> Path is null (deploy continues, CCTK skipped)" `
        -Pass ($null -eq $r.Path) -Detail "got '$($r.Path)'"
    Write-Result -Test "No matching file -> Reason is null" `
        -Pass ($null -eq $r.Reason) -Detail "got '$($r.Reason)'"

    # -----------------------------------------------------------------------
    # Empty service tag: fall through to model
    # -----------------------------------------------------------------------

    Write-Host "`n--- Empty service tag: model still matches ---" -ForegroundColor Cyan

    Clear-CctkFixture
    $modelPath   = New-CctkFixtureFile 'Latitude7420.ini'
    $defaultPath = New-CctkFixtureFile 'default.ini'

    # Simulates Get-WmiObject returning a blank/whitespace service tag (some
    # virtualization stacks do this) - the guarded `if ($serviceTag)` clause
    # must skip step 1 without exploding.
    $r = Select-CctkConfig -CctkDir $fixtureDir -ServiceTag '' -Model 'Latitude7420'
    Write-Result -Test "Empty service tag + valid model -> model wins" `
        -Pass ($r.Path -eq $modelPath) -Detail "got '$($r.Path)'"

    # -----------------------------------------------------------------------
    # Both service tag and model empty: default catches
    # -----------------------------------------------------------------------

    Write-Host "`n--- Both empty: default catches ---" -ForegroundColor Cyan

    Clear-CctkFixture
    $defaultPath = New-CctkFixtureFile 'default.ini'

    $r = Select-CctkConfig -CctkDir $fixtureDir -ServiceTag '' -Model ''
    Write-Result -Test "Empty tag + empty model + default present -> default wins" `
        -Pass ($r.Path -eq $defaultPath) -Detail "got '$($r.Path)'"

    Clear-CctkFixture
    $r = Select-CctkConfig -CctkDir $fixtureDir -ServiceTag '' -Model ''
    Write-Result -Test "Empty tag + empty model + no files -> Path is null" `
        -Pass ($null -eq $r.Path) -Detail "got '$($r.Path)'"

    # -----------------------------------------------------------------------
    # Model normalization: -replace '[^A-Za-z0-9]', ''
    # -----------------------------------------------------------------------

    Write-Host "`n--- Model normalization (non-alnum stripped) ---" -ForegroundColor Cyan

    $normalizationCases = @(
        @{ Raw = 'OptiPlex 7090';          Expected = 'OptiPlex7090' }
        @{ Raw = 'Latitude  7420';         Expected = 'Latitude7420' }
        @{ Raw = 'XPS 15 9500';            Expected = 'XPS159500'    }
        @{ Raw = 'Precision-5570';         Expected = 'Precision5570'}
        @{ Raw = 'Precision_5570';         Expected = 'Precision5570'}
        @{ Raw = '  Latitude 5420  ';      Expected = 'Latitude5420' }
        @{ Raw = 'Model/With\Slashes';     Expected = 'ModelWithSlashes' }
        @{ Raw = 'Model.With.Dots';        Expected = 'ModelWithDots' }
        @{ Raw = 'Vostro 3400 (Gen 2)';    Expected = 'Vostro3400Gen2' }
        @{ Raw = '';                       Expected = ''             }
        @{ Raw = '   ';                    Expected = ''             }
    )

    foreach ($case in $normalizationCases) {
        $got = Get-NormalizedModel -RawModel $case.Raw
        Write-Result -Test ("Normalize '{0}' -> '{1}'" -f $case.Raw, $case.Expected) `
            -Pass ($got -eq $case.Expected) -Detail "got '$got'"
    }

    # Normalized model should match the fixture filename after normalization,
    # not the raw WMI model string (regression guard for the case where a
    # future refactor drops .Trim() or changes the regex character class).
    Clear-CctkFixture
    $modelPath = New-CctkFixtureFile 'OptiPlex7090.ini'
    $rawModel  = 'OptiPlex 7090'
    $r = Select-CctkConfig -CctkDir $fixtureDir -ServiceTag '' -Model (Get-NormalizedModel -RawModel $rawModel)
    Write-Result -Test "Normalized model 'OptiPlex 7090' matches 'OptiPlex7090.ini'" `
        -Pass ($r.Path -eq $modelPath) -Detail "got '$($r.Path)'"

    # Negative: raw (un-normalized) model must NOT match the alnum-only file.
    # Uses -PathType Leaf explicitly to sidestep any Test-Path fuzziness on
    # oddly-quoted paths - what we care about here is that the raw string
    # would not be handed to the selector in the deploy script.
    $rawCandidate = Join-Path $fixtureDir "$rawModel.ini"
    Write-Result -Test "Raw model 'OptiPlex 7090.ini' file does NOT exist (would miss without normalization)" `
        -Pass (-not (Test-Path $rawCandidate -PathType Leaf)) -Detail "unexpected: $rawCandidate"

    # -----------------------------------------------------------------------
    # Drift guard: safety-critical code shapes still live in the deploy script
    # -----------------------------------------------------------------------

    Write-Host "`n--- Drift guard ---" -ForegroundColor Cyan

    if (-not (Test-Path $scriptPath)) {
        Write-Result -Test "Deploy script exists at $scriptPath" -Pass $false
    } else {
        Write-Result -Test "Deploy script exists" -Pass $true
        $scriptText = Get-Content $scriptPath -Raw

        Write-Result -Test "Model normalizer regex still present" `
            -Pass ($scriptText -match "\`$rawModel -replace '\[\^A-Za-z0-9\]', ''") `
            -Detail "expected -replace '[^A-Za-z0-9]', ''"

        Write-Result -Test "Service-tag candidate build still present" `
            -Pass ($scriptText -match '\$candidate = Join-Path \$cctkDir "\$serviceTag\.ini"') `
            -Detail 'expected $candidate = Join-Path $cctkDir "$serviceTag.ini"'

        Write-Result -Test "Model candidate build still present" `
            -Pass ($scriptText -match '\$candidate = Join-Path \$cctkDir "\$model\.ini"') `
            -Detail 'expected $candidate = Join-Path $cctkDir "$model.ini"'

        Write-Result -Test "Default candidate build still present" `
            -Pass ($scriptText -match "\`$candidate = Join-Path \`$cctkDir 'default\.ini'") `
            -Detail "expected default.ini fallback"

        Write-Result -Test "Precedence branch 2 gated on 'not configPath -and model'" `
            -Pass ($scriptText -match '-not \$configPath -and \$model') `
            -Detail "expected 'if (-not \$configPath -and \$model)' guard on model branch"

        Write-Result -Test "Reason literal 'service tag' still present" `
            -Pass ($scriptText -match '"service tag \$serviceTag"') `
            -Detail "expected literal 'service tag \$serviceTag'"

        Write-Result -Test "Reason literal 'model' still present" `
            -Pass ($scriptText -match '"model \$model"') `
            -Detail "expected literal 'model \$model'"

        Write-Result -Test "Reason literal 'default' still present" `
            -Pass ($scriptText -match "\`$matchReason = 'default'") `
            -Detail "expected literal 'default'"

        Write-Result -Test "No-match skip returns \$true (does not abort deploy)" `
            -Pass ($scriptText -match "No CCTK config matched.*skipping BIOS config" -and `
                   $scriptText -match "No CCTK config matched[^`n]*`n[^`n]*return \`$true") `
            -Detail "expected 'No CCTK config matched ... skipping BIOS config' then 'return \$true' on the next line"
    }
}
finally {
    if (Test-Path $fixtureDir) {
        Remove-Item -Path $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
    }
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
