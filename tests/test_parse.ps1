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

# Test 11: refresh_usb.ps1 (syntax only - workflow wrapper)
Write-Host "`n--- scripts/refresh_usb.ps1 ---" -ForegroundColor Cyan
Test-ScriptSyntax -Path $refreshPath -Label "USB refresh" | Out-Null

# Test 12: build_iso.ps1 (syntax only - distribution packager for end-user ISOs)
Write-Host "`n--- scripts/build_iso.ps1 ---" -ForegroundColor Cyan
Test-ScriptSyntax -Path $buildIsoPath -Label "ISO builder" | Out-Null

# Test 13: first-login.ps1 — syntax + key behavioral invariants
# The script does TWO things that silently regress in obvious ways:
#   1. Dual-hive apply (Pass 1 = HKCU live, Pass 2 = Default User template).
#      If Pass 2 is dropped in a refactor, the current user gets the tweaks
#      but every future user provisioned from C:\Users\Default\NTUSER.DAT
#      (TechL0/1/2, etc.) silently doesn't — and the regression only
#      manifests months later when those accounts first log in.
#   2. [gc]::Collect() before reg.exe unload. PowerShell holds onto registry
#      handles past the last property access; without the forced collect
#      the unload call fails and leaves the Default User hive loaded,
#      blocking the NTUSER.DAT file from flushing until reboot.
Write-Host "`n--- scripts/first-login.ps1 ---" -ForegroundColor Cyan
$firstLoginOk = Test-ScriptSyntax -Path $firstLoginPath -Label "First-login tweaks"
if ($firstLoginOk) {
    $fc = Get-Content $firstLoginPath -Raw

    Write-Result -Test "First-login: Apply-Tweak helper present" -Pass ($fc -match 'function\s+Apply-Tweak\b')
    Write-Result -Test "First-login: Pass 1 applies tweaks to HKCU (current user)" `
        -Pass ($fc -match "Apply-Tweak\s+-Root\s+'HKCU:'")
    Write-Result -Test "First-login: Pass 2 applies tweaks to mounted Default User hive" `
        -Pass ($fc -match 'Apply-Tweak\s+-Root\s+"HKLM:\\\$mountKey"')
    Write-Result -Test "First-login: Default User hive path is the standard NTUSER.DAT location" `
        -Pass ($fc -match 'Users\\Default\\NTUSER\.DAT')
    Write-Result -Test "First-login: reg.exe load present (mounts Default User hive)" `
        -Pass ($fc -match 'reg\.exe\s+load\b')
    Write-Result -Test "First-login: reg.exe unload present (releases Default User hive)" `
        -Pass ($fc -match 'reg\.exe\s+unload\b')
    Write-Result -Test "First-login: [gc]::Collect() before unload (releases registry handles)" `
        -Pass ($fc -match '\[gc\]::Collect\(\)')
}

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
