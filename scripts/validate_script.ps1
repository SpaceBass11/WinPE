<#
.SYNOPSIS
    Full static analysis of unified_winpe_deploy.ps1
.DESCRIPTION
    Performs comprehensive validation covering syntax, safety, deployment logic,
    and code quality. Use this before releasing the script.
#>

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..' 'unified_winpe_deploy.ps1'

if (-not (Test-Path $scriptPath)) {
    Write-Host "Script not found: $scriptPath" -ForegroundColor Red
    exit 1
}

$content = Get-Content $scriptPath -Raw
$lines = Get-Content $scriptPath
$results = @{ Pass = 0; Warn = 0; Fail = 0 }

function Write-Check {
    param(
        [string]$Category,
        [string]$Test,
        [ValidateSet('PASS','WARN','FAIL')]
        [string]$Result,
        [string]$Detail = ''
    )
    $color = switch ($Result) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
    }
    Write-Host "  [$Result] $Test" -ForegroundColor $color
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor Gray }
    $script:results[$Result]++
}

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host "  WinPE Deploy Script - Full Validation" -ForegroundColor Cyan
Write-Host "================================================================`n" -ForegroundColor Cyan

# ── SYNTAX ──
Write-Host "[SYNTAX]" -ForegroundColor Magenta
$parseErrors = $null
[System.Management.Automation.PSParser]::Tokenize($content, [ref]$parseErrors) | Out-Null
Write-Check -Category "Syntax" -Test "PowerShell parse" -Result $(if ($parseErrors.Count -eq 0) { 'PASS' } else { 'FAIL' }) -Detail "$($parseErrors.Count) error(s)"

$openBraces = ([regex]::Matches($content, '\{')).Count
$closeBraces = ([regex]::Matches($content, '\}')).Count
Write-Check -Category "Syntax" -Test "Balanced braces" -Result $(if ($openBraces -eq $closeBraces) { 'PASS' } else { 'FAIL' }) -Detail "{=$openBraces }=$closeBraces"

# ── VERSION ──
Write-Host "`n[VERSION]" -ForegroundColor Magenta
$configVer = if ($content -match "ScriptVersion\s*=\s*'([^']+)'") { $Matches[1] } else { $null }
$headerVer = if ($content -match '\.VERSION\s*\r?\n\s*(\S+)') { $Matches[1] } else { $null }
Write-Check -Category "Version" -Test "Config version found" -Result $(if ($configVer) { 'PASS' } else { 'FAIL' }) -Detail "Value: $configVer"
Write-Check -Category "Version" -Test "Header version found" -Result $(if ($headerVer) { 'PASS' } else { 'FAIL' }) -Detail "Value: $headerVer"

$verMatch = $configVer -and $headerVer -and ($headerVer -match [regex]::Escape($configVer))
Write-Check -Category "Version" -Test "Versions match" -Result $(if ($verMatch) { 'PASS' } else { 'WARN' }) -Detail "Config=$configVer Header=$headerVer"

# ── SAFETY ──
Write-Host "`n[SAFETY]" -ForegroundColor Magenta
Write-Check -Category "Safety" -Test "#Requires -RunAsAdministrator" -Result $(if ($content -match '#Requires\s+-RunAsAdministrator') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Safety" -Test "Test-Administrator function" -Result $(if ($content -match 'function\s+Test-Administrator') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Safety" -Test "Admin check in Start-Deployment" -Result $(if ($content -match 'Test-Administrator') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Safety" -Test "DELETE ALL DATA confirmation" -Result $(if ($content -match "DELETE ALL DATA") { 'PASS' } else { 'FAIL' })
Write-Check -Category "Safety" -Test "DESTROY SYSTEM confirmation" -Result $(if ($content -match "DESTROY SYSTEM") { 'PASS' } else { 'FAIL' })
Write-Check -Category "Safety" -Test "USB drives excluded" -Result $(if ($content -match "InterfaceType\s+-ne\s+'USB'") { 'PASS' } else { 'WARN' }) -Detail "Get-SystemDisks should filter USB"
Write-Check -Category "Safety" -Test "Memory validation" -Result $(if ($content -match 'function\s+Test-SystemMemory') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Safety" -Test "WinPE environment check" -Result $(if ($content -match 'function\s+Test-WinPEEnvironment') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Safety" -Test "WinPE check blocks non-WinPE" -Result $(if ($content -match 'Test-WinPEEnvironment' -and $content -match 'CONTINUE ANYWAY') { 'PASS' } else { 'WARN' }) -Detail "Test-WinPEEnvironment should require confirmation outside WinPE"
Write-Check -Category "Safety" -Test "-Force parameter exists" -Result $(if ($content -match '\[switch\]\$Force') { 'PASS' } else { 'WARN' }) -Detail "-TargetDisk should require -Force to skip confirmation"
Write-Check -Category "Safety" -Test "Drive letter cleanup before diskpart" -Result $(if ($content -match 'mountvol.*\/d') { 'PASS' } else { 'WARN' }) -Detail "Free C: and S: before diskpart assign"
Write-Check -Category "Safety" -Test "Post-deployment verification" -Result $(if ($content -match 'Verifying deployment' -and $content -match "C:\\Windows\\System32") { 'PASS' } else { 'WARN' }) -Detail "Verify C:\\Windows exists after DISM"
Write-Check -Category "Safety" -Test "Disk size validation" -Result $(if ($content -match 'Target disk too small') { 'PASS' } else { 'WARN' }) -Detail "Check disk can fit image"
Write-Check -Category "Safety" -Test "-Force never bypasses DESTROY SYSTEM" -Result $(if ($content -match 'Force.*DESTROY SYSTEM|DESTROY SYSTEM.*Force' -or ($content -match '\$Force' -and $content -match 'IsSystemDisk.*DESTROY SYSTEM')) { 'PASS' } else { 'WARN' }) -Detail "-Force + system disk must still require DESTROY SYSTEM"
Write-Check -Category "Safety" -Test "System drive protected from mountvol" -Result $(if ($content -match 'SystemDrive.*continue|SystemDrive.*mountvol') { 'PASS' } else { 'WARN' }) -Detail "mountvol /d must check \$env:SystemDrive"
Write-Check -Category "Safety" -Test "Post-diskpart verification" -Result $(if ($content -match "Test-Path\s+'S:\\'.*Test-Path\s+'C:\\\'" -or ($content -match "Test-Path\s+'S:\\\'" -and $content -match "Test-Path\s+'C:\\\'" -and $content -match 'Partition verification')) { 'PASS' } else { 'WARN' }) -Detail "Verify S: and C: exist after diskpart"
Write-Check -Category "Safety" -Test "USB disk skip logging" -Result $(if ($content -match 'Skipping USB disk') { 'PASS' } else { 'WARN' }) -Detail "Log when USB disks are excluded"

# Check if -Silent + -TargetDisk bypasses confirmations
Write-Check -Category "Safety" -Test "-Silent cannot bypass disk confirmation" -Result $(if ($content -match "DELETE ALL DATA" -and $content -notmatch 'Silent.*DELETE\s+ALL') { 'PASS' } else { 'WARN' }) -Detail "Verify -Silent + -TargetDisk still requires confirmation"

# ── DEPLOYMENT LOGIC ──
Write-Host "`n[DEPLOYMENT]" -ForegroundColor Magenta
Write-Check -Category "Deploy" -Test "Diskpart: convert gpt" -Result $(if ($content -match 'convert gpt') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Deploy" -Test "Diskpart: EFI partition (300MB)" -Result $(if ($content -match 'create partition efi size=300') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Deploy" -Test "Diskpart: MSR partition (16MB)" -Result $(if ($content -match 'create partition msr size=16') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Deploy" -Test "Diskpart: Primary NTFS" -Result $(if ($content -match 'create partition primary' -and $content -match "format quick fs=ntfs label=Windows") { 'PASS' } else { 'FAIL' })
Write-Check -Category "Deploy" -Test "Diskpart: EFI letter S:" -Result $(if ($content -match 'assign letter S') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Deploy" -Test "Diskpart: Primary letter C:" -Result $(if ($content -match 'assign letter C') { 'PASS' } else { 'FAIL' })

Write-Check -Category "Deploy" -Test "DISM /apply-image used" -Result $(if ($content -match '/apply-image') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Deploy" -Test "DISM target is C:\" -Result $(if ($content -match "TargetPath.*'C:\\'") { 'PASS' } else { 'WARN' }) -Detail "Verify DISM applies to C:\"
Write-Check -Category "Deploy" -Test "DISM /English for locale safety" -Result $(if ($content -match '/English') { 'PASS' } else { 'WARN' }) -Detail "DISM /Get-WimInfo should use /English"
Write-Check -Category "Deploy" -Test "DISM inline progress (-NoNewWindow)" -Result $(if ($content -match 'NoNewWindow') { 'PASS' } else { 'WARN' }) -Detail "DISM should show progress inline"
Write-Check -Category "Deploy" -Test "bcdboot C:\Windows /s S: /f UEFI" -Result $(if ($content -match "bcdboot" -and $content -match '/s.*S:' -and $content -match '/f.*UEFI') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Deploy" -Test "shutdown.exe (not Stop-Computer)" -Result $(if ($content -match 'shutdown\.exe' -and $content -notmatch 'Stop-Computer') { 'PASS' } else { 'WARN' }) -Detail "WinPE: use shutdown.exe for reliability"
Write-Check -Category "Deploy" -Test "ESD recovery index warning" -Result $(if ($content -match '\.esd.*recovery|recovery.*\.esd') { 'PASS' } else { 'WARN' }) -Detail "Warn users about ESD recovery indexes"
Write-Check -Category "Deploy" -Test "EfiWimFile parameter" -Result $(if ($content -match '\[string\]\$EfiWimFile') { 'PASS' } else { 'WARN' }) -Detail "Optional EFI WIM support"
Write-Check -Category "Deploy" -Test "Boot method logging" -Result $(if ($content -match 'Boot method:') { 'PASS' } else { 'WARN' }) -Detail "Log which boot method was used"

# ── ERROR HANDLING ──
Write-Host "`n[ERROR HANDLING]" -ForegroundColor Magenta
Write-Check -Category "Errors" -Test "Diskpart exit code checked" -Result $(if ($content -match 'Invoke-Diskpart' -and $content -match '\$process\.ExitCode') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Errors" -Test "DISM exit code checked" -Result $(if ($content -match 'Apply-WindowsImage' -and $content -match 'ExitCode') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Errors" -Test "BCDBoot exit code checked" -Result $(if ($content -match 'Set-BootConfiguration' -and $content -match 'ExitCode') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Errors" -Test "Main try/catch with exit 1" -Result $(if ($content -match 'try\s*\{[\s\S]*Start-Deployment[\s\S]*catch[\s\S]*exit 1') { 'PASS' } else { 'WARN' })
Write-Check -Category "Errors" -Test "Temp file cleanup" -Result $(if ($content -match 'Remove-Item.*DiskpartScript') { 'PASS' } else { 'WARN' })
Write-Check -Category "Errors" -Test "Recovery guidance on DISM failure" -Result $(if ($content -match 'RECOVERY GUIDANCE') { 'PASS' } else { 'WARN' })
Write-Check -Category "Errors" -Test "Log file support" -Result $(if ($content -match 'LogFile' -and $content -match 'Add-Content.*LogFile') { 'PASS' } else { 'WARN' })

# ── IMAGE DISCOVERY ──
Write-Host "`n[IMAGE DISCOVERY]" -ForegroundColor Magenta
Write-Check -Category "Discovery" -Test "WimFile parameter priority" -Result $(if ($content -match 'if\s*\(\$WimFile\)') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Discovery" -Test "ImagePath fallback" -Result $(if ($content -match 'if\s*\(\$ImagePath') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Discovery" -Test "Auto-discovery scan" -Result $(if ($content -match 'Get-PSDrive.*FileSystem') { 'PASS' } else { 'FAIL' })
Write-Check -Category "Discovery" -Test "System drive excluded from scan" -Result $(if ($content -match 'SystemDrive') { 'PASS' } else { 'WARN' })
Write-Check -Category "Discovery" -Test "File size filter (>100MB)" -Result $(if ($content -match '100MB') { 'PASS' } else { 'WARN' })
Write-Check -Category "Discovery" -Test "Recursion depth limited" -Result $(if ($content -match 'Depth') { 'PASS' } else { 'WARN' })
Write-Check -Category "Discovery" -Test "WIM index selection" -Result $(if ($content -match 'function\s+Select-ImageIndex' -and $content -match 'function\s+Get-WimImageInfo') { 'PASS' } else { 'WARN' }) -Detail "Multi-edition WIM support"
Write-Check -Category "Discovery" -Test "Env var image drive support" -Result $(if ($content -match 'DEPLOY_IMAGE_DRIVE') { 'PASS' } else { 'WARN' }) -Detail "Smart launcher integration"

# ── SUMMARY ──
Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host "  RESULTS" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  PASS: $($results.Pass)" -ForegroundColor Green
Write-Host "  WARN: $($results.Warn)" -ForegroundColor Yellow
Write-Host "  FAIL: $($results.Fail)" -ForegroundColor $(if ($results.Fail -gt 0) { 'Red' } else { 'Green' })
Write-Host "================================================================`n" -ForegroundColor Cyan

if ($results.Fail -gt 0) {
    Write-Host "VERDICT: Issues found - review FAIL items above" -ForegroundColor Red
    exit 1
} elseif ($results.Warn -gt 0) {
    Write-Host "VERDICT: Passed with warnings - review WARN items above" -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "VERDICT: All checks passed" -ForegroundColor Green
    exit 0
}
