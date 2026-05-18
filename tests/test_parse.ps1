<#
.SYNOPSIS
    Validates PowerShell syntax of MDT scripts.
.DESCRIPTION
    Parses each MDT script and reports any syntax errors. Returns exit code 0 on
    success, 1 on failure. Works with both PowerShell 5.1 and 7+.
#>

$ErrorActionPreference = 'Stop'
$mdtInitPath   = Join-Path $PSScriptRoot '..' 'scripts\mdt\Initialize-MDTDeploymentShare.ps1'
$mdtImportPath = Join-Path $PSScriptRoot '..' 'scripts\mdt\Import-WimImages.ps1'
$mdtMediaPath  = Join-Path $PSScriptRoot '..' 'scripts\mdt\New-MDTMedia.ps1'
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

Write-Host "`n=== MDT Scripts - Syntax Validation ===" -ForegroundColor Cyan

# Test MDT scripts
Write-Host "`n--- scripts/mdt/Initialize-MDTDeploymentShare.ps1 ---" -ForegroundColor Cyan
Test-ScriptSyntax -Path $mdtInitPath -Label "MDT initialize" | Out-Null

Write-Host "`n--- scripts/mdt/Import-WimImages.ps1 ---" -ForegroundColor Cyan
Test-ScriptSyntax -Path $mdtImportPath -Label "MDT WIM import" | Out-Null

Write-Host "`n--- scripts/mdt/New-MDTMedia.ps1 ---" -ForegroundColor Cyan
Test-ScriptSyntax -Path $mdtMediaPath -Label "MDT media build" | Out-Null

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
