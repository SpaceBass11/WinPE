<#
.SYNOPSIS
    Validates PowerShell syntax of every script shipped by the deploy
    pipeline: unified_winpe_deploy.ps1 plus scripts/build_boot_wim.ps1,
    scripts/prepare_wim.ps1, scripts/refresh_usb.ps1, scripts/build_iso.ps1,
    and scripts/first-login.ps1.
.DESCRIPTION
    Parses each script and reports any syntax errors. Returns exit code 0 on
    success, 1 on failure. Works with both PowerShell 5.1 and 7+.
#>

$ErrorActionPreference = 'Stop'
$scriptPath    = Join-Path $PSScriptRoot '..' 'unified_winpe_deploy.ps1'
$builderPath   = Join-Path $PSScriptRoot '..' 'scripts\build_boot_wim.ps1'
$prepPath      = Join-Path $PSScriptRoot '..' 'scripts\prepare_wim.ps1'
$refreshPath   = Join-Path $PSScriptRoot '..' 'scripts\refresh_usb.ps1'
$buildIsoPath  = Join-Path $PSScriptRoot '..' 'scripts\build_iso.ps1'
$firstLoginPath = Join-Path $PSScriptRoot '..' 'scripts\first-login.ps1'
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

function Test-ScriptSyntax {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) {
        Write-Result -Test "$Label exists" -Pass $false -Detail "Not found at $Path"
        return $false
    }
    Write-Result -Test "$Label exists" -Pass $true
    $c = Get-Content $Path -Raw
    $parseErrors = $null
    [System.Management.Automation.PSParser]::Tokenize($c, [ref]$parseErrors) | Out-Null
    $ok = ($parseErrors.Count -eq 0)
    Write-Result -Test "$Label syntax valid" -Pass $ok -Detail "$($parseErrors.Count) error(s)"
    if (-not $ok) {
        foreach ($err in $parseErrors) {
            Write-Host "    Line $($err.Token.StartLine): $($err.Message)" -ForegroundColor Yellow
        }
    }
    return $ok
}

Write-Host "`n=== WinPE Deploy Script - Syntax Validation ===" -ForegroundColor Cyan
Write-Host "Script: $scriptPath`n"

# Test 1: File exists
$fileExists = Test-Path $scriptPath
Write-Result -Test "Script file exists" -Pass $fileExists
if (-not $fileExists) {
    Write-Host "`nCannot continue - script file not found" -ForegroundColor Red
    exit 1
}

$content = Get-Content $scriptPath -Raw
$lines = Get-Content $scriptPath

# Test 2: PowerShell parser (syntax errors)
$parseErrors = $null
$tokens = [System.Management.Automation.PSParser]::Tokenize($content, [ref]$parseErrors)
$syntaxOk = ($parseErrors.Count -eq 0)
Write-Result -Test "PowerShell syntax valid" -Pass $syntaxOk -Detail "$($parseErrors.Count) error(s)"
if (-not $syntaxOk) {
    foreach ($err in $parseErrors) {
        Write-Host "    Line $($err.Token.StartLine): $($err.Message)" -ForegroundColor Yellow
    }
}

# Test 3: Balanced braces
$openBraces = ($content.ToCharArray() | Where-Object { $_ -eq '{' }).Count
$closeBraces = ($content.ToCharArray() | Where-Object { $_ -eq '}' }).Count
Write-Result -Test "Balanced braces" -Pass ($openBraces -eq $closeBraces) -Detail "Open: $openBraces, Close: $closeBraces"

# Test 4: Region/endregion balance
$regions = ($lines | Where-Object { $_ -match '^\s*#region\b' }).Count
$endregions = ($lines | Where-Object { $_ -match '^\s*#endregion' }).Count
Write-Result -Test "Balanced #region/#endregion" -Pass ($regions -eq $endregions) -Detail "Regions: $regions, Endregions: $endregions"

# Test 5: Required functions exist
# Functions covering the destructive-operation entry points (Invoke-Diskpart,
# Apply-WindowsImage, Set-BootConfiguration, Invoke-CctkConfig,
# Select-AdditionalWipeDisks) and their confirmation parser
# (Test-FinalWipeConfirmation) must be present — silent loss of any one of
# them is a safety regression. Show-ImageList backs the public -ListOnly flag.
$requiredFunctions = @(
    'Write-Log', 'Write-Banner', 'Test-Administrator', 'Show-MessageBox',
    'Initialize-SystemPaths', 'Find-ImageFiles', 'Search-DirectoryForImages',
    'Show-ImageList', 'Show-ImageSelection',
    'Test-WinPEEnvironment', 'Test-SystemMemory',
    'Get-SystemDisks', 'Show-DiskMenu', 'Test-FinalWipeConfirmation',
    'Select-TargetDisk', 'Get-WimImageInfo', 'Select-ImageIndex',
    'New-DiskpartScript', 'Invoke-Diskpart', 'Apply-WindowsImage',
    'Set-BootConfiguration', 'Invoke-CctkConfig',
    'Select-AdditionalWipeDisks', 'Resolve-BitLockerKeyPath',
    'Initialize-BitLockerSetup', 'Start-Deployment'
)
foreach ($func in $requiredFunctions) {
    $found = $content -match "function\s+$func\b"
    Write-Result -Test "Function '$func' defined" -Pass $found
}

# Test 6: Version consistency
$configVersion = if ($content -match "ScriptVersion\s*=\s*'([^']+)'") { $Matches[1] } else { 'NOT FOUND' }
$headerVersion = if ($content -match '\.VERSION\s*\r?\n\s*(\S+)') { $Matches[1] } else { 'NOT FOUND' }
$versionMatch = ($configVersion -eq $headerVersion) -or ($headerVersion -match [regex]::Escape($configVersion))
Write-Result -Test "Version consistency (Config: $configVersion, Header: $headerVersion)" -Pass $versionMatch

# Test 7: CmdletBinding present
$hasCmdletBinding = $content -match '\[CmdletBinding\(\)\]'
Write-Result -Test "CmdletBinding attribute present" -Pass $hasCmdletBinding

# Test 8: Requires RunAsAdministrator
$hasRequires = $content -match '#Requires\s+-RunAsAdministrator'
Write-Result -Test "#Requires -RunAsAdministrator present" -Pass $hasRequires

# Test 9: build_boot_wim.ps1 — syntax + key behavioral invariants
Write-Host "`n--- scripts/build_boot_wim.ps1 ---" -ForegroundColor Cyan
$builderOk = Test-ScriptSyntax -Path $builderPath -Label "Builder"
if ($builderOk) {
    $bc = Get-Content $builderPath -Raw

    # DCH API DLL validation must be present and must throw on missing DLLs
    Write-Result -Test "Builder: DCH DLL check present (dchapi64.dll)" -Pass ($bc -match 'dchapi64\.dll')
    Write-Result -Test "Builder: DCH DLL check present (dchbas64.dll)" -Pass ($bc -match 'dchbas64\.dll')
    Write-Result -Test "Builder: DCH DLL check present (BIOSIntf.dll)"  -Pass ($bc -match 'BIOSIntf\.dll')
    Write-Result -Test "Builder: DCH DLL check throws on missing" -Pass ($bc -match 'missingDlls' -and $bc -match 'throw.*DCH API DLLs missing|throw.*missingDlls')

    # Copy block must use $cctkDir (the validated path), not a separately recomputed variable
    Write-Result -Test 'Builder: copy block uses $cctkDir' -Pass ($bc -match 'Copy-Item.*\$cctkDir|Join-Path\s+\$cctkDir')
}

# Test 10: prepare_wim.ps1 (syntax only - companion WIM prep script)
Write-Host "`n--- scripts/prepare_wim.ps1 ---" -ForegroundColor Cyan
Test-ScriptSyntax -Path $prepPath -Label "WIM prep" | Out-Null

# Test 11: refresh_usb.ps1 — syntax + key behavioral invariants
# refresh_usb.ps1 is a thin wrapper that must delegate correctly to
# prepare_wim.ps1 (and optionally build_boot_wim.ps1). A silent regression
# in the pass-through wiring wastes 20 min of prepare_wim runtime before the
# operator learns the wrapper misrouted a flag or missed an error.
Write-Host "`n--- scripts/refresh_usb.ps1 ---" -ForegroundColor Cyan
$refreshOk = Test-ScriptSyntax -Path $refreshPath -Label "USB refresh"
if ($refreshOk) {
    $rc = Get-Content $refreshPath -Raw

    # copype pre-flight must exist AND must sit inside the -RebuildBootWim Yes
    # branch. If the copype check runs unconditionally, image-only refreshes on
    # a plain PowerShell (no ADK env) fail unnecessarily. If the check is
    # dropped, operators eat 20 min of prepare_wim runtime before boot.wim
    # rebuild fails.
    Write-Result -Test "Refresh: copype pre-flight present" -Pass ($rc -match 'Get-Command\s+copype')
    Write-Result -Test "Refresh: copype pre-flight gated by -RebuildBootWim Yes" `
        -Pass ($rc -match "RebuildBootWim\s+-eq\s+'Yes'[\s\S]{0,300}?Get-Command\s+copype")

    # prepare_wim.ps1's $LASTEXITCODE must be checked after invocation.
    # Dropping the check would let the wrapper claim success on a failed
    # image build and go on to rebuild boot.wim against a half-baked WIM.
    Write-Result -Test 'Refresh: prepare_wim.ps1 $LASTEXITCODE checked' `
        -Pass ($rc -match '&\s+\$prepScript[\s\S]{0,200}?\$LASTEXITCODE\s+-ne\s+0')

    # -DisableExtraBloat forwarded to prepare_wim.ps1. The gate that stages
    # first-login.ps1 into the image lives inside prepare_wim; if the wrapper
    # drops the passthrough, first-login.ps1 silently stops being staged.
    Write-Result -Test 'Refresh: -DisableExtraBloat forwarded to prepare_wim' `
        -Pass ($rc -match '\$prepArgs\.DisableExtraBloat')

    # -Index / -Edition are passed through only when explicitly bound by the
    # caller, so prepare_wim's own defaults ("Windows 11 Enterprise" for
    # Edition) survive when the wrapper's caller doesn't supply them.
    # A refactor to `if ($Index)` would drop `-Index 0` at binding time
    # (0 is falsy) and silently clobber prepare_wim's default Edition
    # by forwarding an empty string.
    Write-Result -Test 'Refresh: -Index passed via PSBoundParameters.ContainsKey' `
        -Pass ($rc -match "PSBoundParameters\.ContainsKey\(\s*'Index'\s*\)")
    Write-Result -Test 'Refresh: -Edition passed via PSBoundParameters.ContainsKey' `
        -Pass ($rc -match "PSBoundParameters\.ContainsKey\(\s*'Edition'\s*\)")
}

# Test 12: build_iso.ps1 (syntax only - distribution packager for end-user ISOs)
Write-Host "`n--- scripts/build_iso.ps1 ---" -ForegroundColor Cyan
Test-ScriptSyntax -Path $buildIsoPath -Label "ISO builder" | Out-Null

# Test 13: first-login.ps1 (syntax only - first-boot per-user tweaks staged into the image)
Write-Host "`n--- scripts/first-login.ps1 ---" -ForegroundColor Cyan
Test-ScriptSyntax -Path $firstLoginPath -Label "First-login tweaks" | Out-Null

# Summary
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "Passed: $passed" -ForegroundColor Green
Write-Host "Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })

if ($failed -gt 0) {
    exit 1
} else {
    Write-Host "`nAll checks passed!" -ForegroundColor Green
    exit 0
}
