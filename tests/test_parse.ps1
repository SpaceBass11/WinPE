<#
.SYNOPSIS
    Validates PowerShell syntax of unified_winpe_deploy.ps1, scripts/build_boot_wim.ps1,
    scripts/prepare_wim.ps1, scripts/refresh_usb.ps1, and scripts/first-login.ps1.
.DESCRIPTION
    Parses each script and reports any syntax errors. Returns exit code 0 on
    success, 1 on failure. Works with both PowerShell 5.1 and 7+.
#>

$ErrorActionPreference = 'Stop'
$scriptPath    = Join-Path $PSScriptRoot '..' 'unified_winpe_deploy.ps1'
$builderPath   = Join-Path $PSScriptRoot '..' 'scripts\build_boot_wim.ps1'
$prepPath      = Join-Path $PSScriptRoot '..' 'scripts\prepare_wim.ps1'
$refreshPath   = Join-Path $PSScriptRoot '..' 'scripts\refresh_usb.ps1'
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
$requiredFunctions = @(
    'Write-Log', 'Write-Banner', 'Test-Administrator', 'Show-MessageBox',
    'Initialize-SystemPaths', 'Find-ImageFiles', 'Search-DirectoryForImages',
    'Show-ImageSelection', 'Test-WinPEEnvironment', 'Test-SystemMemory',
    'Get-SystemDisks', 'Show-DiskMenu', 'Select-TargetDisk',
    'Get-WimImageInfo', 'Select-ImageIndex', 'New-DiskpartScript',
    'Invoke-Diskpart', 'Apply-WindowsImage', 'Set-BootConfiguration',
    'Start-Deployment'
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

# Test 9: build_boot_wim.ps1 (syntax only - it's a simpler single-purpose script)
Write-Host "`n--- scripts/build_boot_wim.ps1 ---" -ForegroundColor Cyan
Test-ScriptSyntax -Path $builderPath -Label "Builder" | Out-Null

# Test 10: prepare_wim.ps1 (syntax only - companion WIM prep script)
Write-Host "`n--- scripts/prepare_wim.ps1 ---" -ForegroundColor Cyan
Test-ScriptSyntax -Path $prepPath -Label "WIM prep" | Out-Null

# Test 11: refresh_usb.ps1 (syntax only - workflow wrapper)
Write-Host "`n--- scripts/refresh_usb.ps1 ---" -ForegroundColor Cyan
Test-ScriptSyntax -Path $refreshPath -Label "USB refresh" | Out-Null

# Test 12: first-login.ps1 (syntax only - staged into deployed image, runs at first sign-in)
Write-Host "`n--- scripts/first-login.ps1 ---" -ForegroundColor Cyan
Test-ScriptSyntax -Path $firstLoginPath -Label "First-login" | Out-Null

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
