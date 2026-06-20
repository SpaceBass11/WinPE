<#
.SYNOPSIS
    Fixture test for the CCTK config selection precedence used by
    Invoke-CctkConfig in unified_winpe_deploy.ps1.

.DESCRIPTION
    Invoke-CctkConfig picks ONE .ini file from <IMAGES>\cctk\ and runs
    cctk.exe against it. The selection precedence is documented in the
    function header (and in docs/CCTK.md):

      1. <SERVICETAG>.ini  - per-machine (Win32_BIOS.SerialNumber)
      2. <MODEL>.ini       - per-model, alnum-normalized
                             (Win32_ComputerSystem.Model with
                             [^A-Za-z0-9] characters stripped)
      3. default.ini       - catch-all
      4. none              - skip CCTK entirely, continue to deploy

    A regression that flipped precedence (e.g. always picked default.ini
    even when a service-tag config existed) would silently apply the
    wrong BIOS settings to every machine in a Dell fleet - exactly the
    failure mode this feature was added to prevent. The masterize CI
    grep only enforces that CCTK runs before disk selection - it does
    NOT check which file is picked.

    No real WMI, no real CCTK invocation, no real BIOS. Fixture .ini
    files are written into a temp dir; the resolver function mirrors
    the inline selection logic from Invoke-CctkConfig. A drift guard
    at the bottom confirms the safety-critical code shapes still live
    in the deploy script.

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

Write-Host "`n=== WinPE Deploy - CCTK Selection Precedence Tests ===" -ForegroundColor Cyan

# Mirror of the inline precedence + model-normalization logic from
# Invoke-CctkConfig. Kept as small as possible so any drift between this
# helper and the live function shows up in the drift-guard block below.
function Get-CctkConfigPick {
    param(
        [string]$CctkDir,
        [string]$ServiceTag,
        [string]$RawModel
    )

    $model = $null
    if ($RawModel) { $model = ($RawModel -replace '[^A-Za-z0-9]', '').Trim() }

    $tag = $null
    if ($ServiceTag) { $tag = $ServiceTag.Trim() }

    $configPath  = $null
    $matchReason = $null

    if ($tag) {
        $candidate = Join-Path $CctkDir "$tag.ini"
        if (Test-Path $candidate) {
            $configPath  = $candidate
            $matchReason = "service tag $tag"
        }
    }
    if (-not $configPath -and $model) {
        $candidate = Join-Path $CctkDir "$model.ini"
        if (Test-Path $candidate) {
            $configPath  = $candidate
            $matchReason = "model $model"
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
        Path           = $configPath
        Reason         = $matchReason
        NormalizedModel = $model
    }
}

# ---------------------------------------------------------------------------
# Fixture: a temp cctk directory under the OS temp dir. Re-create fresh
# per scenario so leftover files from a prior scenario can't bleed in.
# ---------------------------------------------------------------------------

$root = Join-Path ([IO.Path]::GetTempPath()) ("cctk_test_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null

function Reset-CctkDir {
    if (Test-Path $root) { Remove-Item $root -Recurse -Force }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
}

function Add-IniFile {
    param([string]$Name)
    # Content is irrelevant - selection logic only checks Test-Path.
    Set-Content -Path (Join-Path $root $Name) -Value "; fixture" -Force
}

try {

# ---------------------------------------------------------------------------
# Selection precedence
# ---------------------------------------------------------------------------

Write-Host "`n--- Precedence (servicetag > model > default) ---" -ForegroundColor Cyan

# 1) All three files present - service tag wins
Reset-CctkDir
Add-IniFile 'ABC1234.ini'
Add-IniFile 'OptiPlex7090.ini'
Add-IniFile 'default.ini'
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag 'ABC1234' -RawModel 'OptiPlex 7090'
Write-Result -Test "All three present: service tag .ini is picked" `
    -Pass ($r.Path -eq (Join-Path $root 'ABC1234.ini')) `
    -Detail "got '$($r.Path)' reason='$($r.Reason)'"
Write-Result -Test "All three present: reason names the service tag" `
    -Pass ($r.Reason -eq 'service tag ABC1234')

# 2) Only model + default - model wins
Reset-CctkDir
Add-IniFile 'OptiPlex7090.ini'
Add-IniFile 'default.ini'
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag 'ABC1234' -RawModel 'OptiPlex 7090'
Write-Result -Test "Only model+default: model .ini is picked" `
    -Pass ($r.Path -eq (Join-Path $root 'OptiPlex7090.ini')) `
    -Detail "got '$($r.Path)' reason='$($r.Reason)'"
Write-Result -Test "Only model+default: reason names the model" `
    -Pass ($r.Reason -eq 'model OptiPlex7090')

# 3) Only default - default wins
Reset-CctkDir
Add-IniFile 'default.ini'
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag 'ABC1234' -RawModel 'OptiPlex 7090'
Write-Result -Test "Only default: default.ini is picked" `
    -Pass ($r.Path -eq (Join-Path $root 'default.ini'))
Write-Result -Test "Only default: reason is 'default'" `
    -Pass ($r.Reason -eq 'default')

# 4) Nothing matches - returns null path (Invoke-CctkConfig logs and skips)
Reset-CctkDir
Add-IniFile 'SomeOtherTag.ini'   # tag mismatch
Add-IniFile 'OtherModel.ini'     # model mismatch (no default)
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag 'ABC1234' -RawModel 'OptiPlex 7090'
Write-Result -Test "No match: returns null path (deploy continues without BIOS config)" `
    -Pass ($null -eq $r.Path) `
    -Detail "got '$($r.Path)'"

# 5) Empty directory - same as no match
Reset-CctkDir
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag 'ABC1234' -RawModel 'OptiPlex 7090'
Write-Result -Test "Empty cctk dir: returns null path" `
    -Pass ($null -eq $r.Path)

# ---------------------------------------------------------------------------
# Service-tag / model edge cases (Get-WmiObject returns these unpredictably)
# ---------------------------------------------------------------------------

Write-Host "`n--- Identifier edge cases ---" -ForegroundColor Cyan

# 6) Null service tag falls through to model
Reset-CctkDir
Add-IniFile 'OptiPlex7090.ini'
Add-IniFile 'default.ini'
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag $null -RawModel 'OptiPlex 7090'
Write-Result -Test "Null service tag: falls through to model match" `
    -Pass ($r.Path -eq (Join-Path $root 'OptiPlex7090.ini'))

# 7) Empty-string service tag falls through to model
Reset-CctkDir
Add-IniFile 'OptiPlex7090.ini'
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag '' -RawModel 'OptiPlex 7090'
Write-Result -Test "Empty service tag: falls through to model match" `
    -Pass ($r.Path -eq (Join-Path $root 'OptiPlex7090.ini'))

# 8) Whitespace-only service tag does not match a '   .ini' file
Reset-CctkDir
Add-IniFile 'default.ini'
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag '   ' -RawModel $null
Write-Result -Test "Whitespace-only service tag: trimmed away, falls through to default" `
    -Pass ($r.Path -eq (Join-Path $root 'default.ini')) `
    -Detail "got '$($r.Path)'"

# 9) Both null - falls through to default
Reset-CctkDir
Add-IniFile 'default.ini'
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag $null -RawModel $null
Write-Result -Test "Null tag + null model: default.ini is picked" `
    -Pass ($r.Path -eq (Join-Path $root 'default.ini'))

# 10) Null model normalizes to null (does not crash)
Reset-CctkDir
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag 'NOPE' -RawModel $null
Write-Result -Test "Null model: NormalizedModel is null (no .ini lookup attempt)" `
    -Pass ($null -eq $r.NormalizedModel)

# ---------------------------------------------------------------------------
# Model normalization: [^A-Za-z0-9] stripped, never replaced with '_' / ' '
# ---------------------------------------------------------------------------

Write-Host "`n--- Model normalization ---" -ForegroundColor Cyan

# 11) Spaces stripped: 'OptiPlex 7090' -> 'OptiPlex7090'
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag $null -RawModel 'OptiPlex 7090'
Write-Result -Test "Space stripped: 'OptiPlex 7090' -> 'OptiPlex7090'" `
    -Pass ($r.NormalizedModel -eq 'OptiPlex7090')

# 12) Hyphens stripped: 'Inspiron 15-3000' -> 'Inspiron153000'
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag $null -RawModel 'Inspiron 15-3000'
Write-Result -Test "Hyphen stripped: 'Inspiron 15-3000' -> 'Inspiron153000'" `
    -Pass ($r.NormalizedModel -eq 'Inspiron153000')

# 13) Underscore stripped: 'Latitude_E7440' -> 'LatitudeE7440'
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag $null -RawModel 'Latitude_E7440'
Write-Result -Test "Underscore stripped: 'Latitude_E7440' -> 'LatitudeE7440'" `
    -Pass ($r.NormalizedModel -eq 'LatitudeE7440')

# 14) Trademark / unicode stripped
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag $null -RawModel 'XPS 15 (9520)'
Write-Result -Test "Parens stripped: 'XPS 15 (9520)' -> 'XPS159520'" `
    -Pass ($r.NormalizedModel -eq 'XPS159520')

# 15) Already-clean model: round-trips
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag $null -RawModel 'OptiPlex7090'
Write-Result -Test "Already-clean model unchanged" `
    -Pass ($r.NormalizedModel -eq 'OptiPlex7090')

# 16) Pure-symbol model normalizes to empty -> does NOT match a '.ini' file
Reset-CctkDir
Add-IniFile 'default.ini'
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag $null -RawModel '!!!---'
Write-Result -Test "Pure-symbol model: empty after normalize, falls through to default" `
    -Pass ($r.Path -eq (Join-Path $root 'default.ini')) `
    -Detail "normalizedModel='$($r.NormalizedModel)' got='$($r.Path)'"

# 17) Real-world Dell model from WMI: 'Latitude 7400'
Reset-CctkDir
Add-IniFile 'Latitude7400.ini'
$r = Get-CctkConfigPick -CctkDir $root -ServiceTag $null -RawModel 'Latitude 7400'
Write-Result -Test "Real-world: 'Latitude 7400' picks 'Latitude7400.ini'" `
    -Pass ($r.Path -eq (Join-Path $root 'Latitude7400.ini'))

# ---------------------------------------------------------------------------
# Drift guard: safety-critical code shapes must still live in the deploy script
# ---------------------------------------------------------------------------

Write-Host "`n--- Drift guard ---" -ForegroundColor Cyan

if (-not (Test-Path $scriptPath)) {
    Write-Result -Test "Deploy script exists at $scriptPath" -Pass $false
} else {
    Write-Result -Test "Deploy script exists" -Pass $true
    $scriptText = Get-Content $scriptPath -Raw

    Write-Result -Test "Service-tag lookup still uses '<TAG>.ini' filename pattern" `
        -Pass ($scriptText -match 'Join-Path \$cctkDir "\$serviceTag\.ini"') `
        -Detail 'expected Join-Path $cctkDir "$serviceTag.ini"'

    Write-Result -Test "Model lookup still uses '<MODEL>.ini' filename pattern" `
        -Pass ($scriptText -match 'Join-Path \$cctkDir "\$model\.ini"') `
        -Detail 'expected Join-Path $cctkDir "$model.ini"'

    Write-Result -Test "default.ini fallback still present (literal filename)" `
        -Pass ($scriptText -match "Join-Path \`$cctkDir 'default\.ini'") `
        -Detail "expected Join-Path \$cctkDir 'default.ini'"

    Write-Result -Test "Model normalization regex still strips non-alnum" `
        -Pass ($scriptText -match "\-replace '\[\^A-Za-z0-9\]', ''") `
        -Detail "expected -replace '[^A-Za-z0-9]', ''"

    Write-Result -Test "Service-tag check still precedes model check (line order)" `
        -Pass (
            ($scriptText.IndexOf('Join-Path $cctkDir "$serviceTag.ini"')) -lt
            ($scriptText.IndexOf('Join-Path $cctkDir "$model.ini"'))
        ) -Detail 'service-tag block must appear before model block in source'

    Write-Result -Test "Model check still precedes default.ini fallback" `
        -Pass (
            ($scriptText.IndexOf('Join-Path $cctkDir "$model.ini"')) -lt
            ($scriptText.IndexOf("Join-Path `$cctkDir 'default.ini'"))
        ) -Detail 'model block must appear before default block in source'
}

}
finally {
    if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host "Passed: $passed" -ForegroundColor Green
Write-Host "Failed: $failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
Write-Host ""

if ($failed -eq 0) {
    Write-Host "All checks passed!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failed check(s) failed." -ForegroundColor Red
    exit 1
}
