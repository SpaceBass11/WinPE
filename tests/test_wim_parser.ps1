<#
.SYNOPSIS
    Fixture test for the DISM /Get-WimInfo output parser used by
    Get-WimImageInfo in unified_winpe_deploy.ps1.
.DESCRIPTION
    Get-WimImageInfo silently returns an empty list if its regex parser
    fails to match DISM output. A bad parser would either abort the deploy
    ("Could not enumerate WIM indexes from DISM") or - worse - mis-attribute
    edition names to indexes, letting the operator deploy the wrong edition.

    This test feeds a realistic DISM /Get-WimInfo /English fixture through a
    parser block that mirrors Get-WimImageInfo, then asserts the parsed
    structure. A drift guard at the end confirms the four parser regex
    patterns still live in the deploy script verbatim; if the patterns
    change without updating this test, the drift guard fails.

    Works with both PowerShell 5.1 and 7+. Returns exit code 0 on success,
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

Write-Host "`n=== WinPE Deploy - WIM Index Parser Tests ===" -ForegroundColor Cyan

# --- Parser logic (mirrors Get-WimImageInfo in unified_winpe_deploy.ps1) ---
# Patterns kept verbatim so the drift guard at the bottom of this file can
# verify them against the deploy script.
$rxIndex = '^\s*Index\s*:\s*(\d+)'
$rxName  = '^\s*Name\s*:\s*(.+)'
$rxDesc  = '^\s*Description\s*:\s*(.+)'
$rxSize  = '^\s*Size\s*:\s*(.+)'

function Invoke-WimInfoParser {
    param(
        [string[]]$Lines,
        [string]$IndexPattern,
        [string]$NamePattern,
        [string]$DescPattern,
        [string]$SizePattern
    )

    $indexes = @()
    $currentIndex = $null
    foreach ($line in $Lines) {
        if ($line -match $IndexPattern) {
            if ($currentIndex) { $indexes += $currentIndex }
            $currentIndex = @{ Index = [int]$Matches[1]; Name = ''; Description = ''; Size = '' }
        } elseif ($currentIndex -and $line -match $NamePattern) {
            $currentIndex.Name = $Matches[1].Trim()
        } elseif ($currentIndex -and $line -match $DescPattern) {
            $currentIndex.Description = $Matches[1].Trim()
        } elseif ($currentIndex -and $line -match $SizePattern) {
            $currentIndex.Size = $Matches[1].Trim()
        }
    }
    if ($currentIndex) { $indexes += $currentIndex }
    return ,$indexes
}

function Invoke-Fixture {
    param([string[]]$Lines)
    return Invoke-WimInfoParser -Lines $Lines `
        -IndexPattern $rxIndex -NamePattern $rxName `
        -DescPattern $rxDesc -SizePattern $rxSize
}

# --- Fixture: realistic DISM /Get-WimInfo /English output (multi-index WIM) ---
$multiFixture = @'
Deployment Image Servicing and Management tool
Version: 10.0.22621.1

Details for image : D:\images\Win11_Pro.wim

Index : 1
Name : Windows 11 Home
Description : Windows 11 Home
Size : 16,134,221,478 bytes

Index : 2
Name : Windows 11 Home N
Description : Windows 11 Home N
Size : 15,512,345,678 bytes

Index : 3
Name : Windows 11 Pro
Description : Windows 11 Pro
Size : 17,234,567,890 bytes

The operation completed successfully.
'@ -split "`r?`n"

$result = Invoke-Fixture -Lines $multiFixture

Write-Host "`n--- Multi-index fixture ---" -ForegroundColor Cyan
Write-Result -Test "Parsed 3 indexes" -Pass ($result.Count -eq 3) -Detail "Got $($result.Count)"
if ($result.Count -ge 1) {
    Write-Result -Test "Index 1 number is integer 1" -Pass ($result[0].Index -eq 1 -and $result[0].Index -is [int])
    Write-Result -Test "Index 1 name = 'Windows 11 Home'" -Pass ($result[0].Name -eq 'Windows 11 Home') -Detail "Got '$($result[0].Name)'"
    Write-Result -Test "Index 1 description = 'Windows 11 Home'" -Pass ($result[0].Description -eq 'Windows 11 Home')
    Write-Result -Test "Index 1 size = '16,134,221,478 bytes'" -Pass ($result[0].Size -eq '16,134,221,478 bytes') -Detail "Got '$($result[0].Size)'"
}
if ($result.Count -ge 3) {
    Write-Result -Test "Index 3 name = 'Windows 11 Pro'" -Pass ($result[2].Name -eq 'Windows 11 Pro') -Detail "Got '$($result[2].Name)'"
    Write-Result -Test "Index 3 number is integer 3" -Pass ($result[2].Index -eq 3)
}

# --- Fixture: single-index WIM (common for captured/debloated images) ---
$singleFixture = @'
Deployment Image Servicing and Management tool
Version: 10.0.22621.1

Details for image : D:\images\Win11_Custom.wim

Index : 1
Name : Windows 11 Custom
Description : Customized image with debloat applied
Size : 14,012,345,678 bytes

The operation completed successfully.
'@ -split "`r?`n"

$result = Invoke-Fixture -Lines $singleFixture

Write-Host "`n--- Single-index fixture ---" -ForegroundColor Cyan
Write-Result -Test "Parsed 1 index" -Pass ($result.Count -eq 1) -Detail "Got $($result.Count)"
if ($result.Count -ge 1) {
    Write-Result -Test "Index name = 'Windows 11 Custom'" -Pass ($result[0].Name -eq 'Windows 11 Custom')
    Write-Result -Test "Description preserved verbatim" -Pass ($result[0].Description -eq 'Customized image with debloat applied') -Detail "Got '$($result[0].Description)'"
}

# --- Fixture: empty / non-matching output (corrupted WIM, unsupported DISM) ---
$emptyFixture = @'
Deployment Image Servicing and Management tool
Version: 10.0.22621.1

An error occurred while servicing the image.
'@ -split "`r?`n"

$result = Invoke-Fixture -Lines $emptyFixture

Write-Host "`n--- Empty/error fixture ---" -ForegroundColor Cyan
Write-Result -Test "No indexes parsed from error output" -Pass ($result.Count -eq 0) -Detail "Got $($result.Count)"

# --- Drift guard: regex patterns must still appear in the deploy script ---
Write-Host "`n--- Drift guard ---" -ForegroundColor Cyan
if (-not (Test-Path $scriptPath)) {
    Write-Result -Test "Deploy script exists at $scriptPath" -Pass $false
} else {
    Write-Result -Test "Deploy script exists" -Pass $true
    $scriptText = Get-Content $scriptPath -Raw
    foreach ($pair in @(
        @{ Label = 'Index regex'; Pattern = $rxIndex },
        @{ Label = 'Name regex'; Pattern = $rxName },
        @{ Label = 'Description regex'; Pattern = $rxDesc },
        @{ Label = 'Size regex'; Pattern = $rxSize }
    )) {
        $needle = [regex]::Escape($pair.Pattern)
        $found = $scriptText -match $needle
        Write-Result -Test "$($pair.Label) still present in deploy script" -Pass $found -Detail "Pattern: $($pair.Pattern)"
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
