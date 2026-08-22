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

# Test 8b: Unattend copy is guarded against silent Copy-Item failures.
# The staging block runs AFTER DISM apply succeeds, so the disk is already
# written and the operator is committed. A bare `Copy-Item -Force` uses the
# default -ErrorAction Continue: a failure prints a red line but the next
# `Write-Log "Unattend file staged"` still runs, giving a false success
# summary. Windows Setup then silently ignores the missing unattend.xml and
# first boot lands in manual OOBE — the exact failure mode the pre-flight
# XML well-formedness check was added to prevent. Pin -ErrorAction Stop on
# the copy and a recovery-guidance line in the catch.
$unattendCopyGuarded = $content -match "Copy-Item\s+-Path\s+\`$UnattendFile[^\r\n]*-ErrorAction\s+Stop"
Write-Result -Test 'Unattend copy uses -ErrorAction Stop' -Pass $unattendCopyGuarded
$unattendRecoveryLogged = $content -match 'First boot will land in manual OOBE'
Write-Result -Test 'Unattend copy failure logs recovery guidance' -Pass $unattendRecoveryLogged

# Test 8c: Initialize-BitLockerSetup guards its staging I/O against silent failures.
# The pre-Set-Content New-Item used to sit outside the try/catch so a directory
# creation failure at C:\Windows\Setup\Scripts was a non-terminating error the
# catch never saw. Both Set-Content calls also default to -ErrorAction Continue.
# Combined, a fully-silent failure could return $true from Initialize-BitLockerSetup
# with no first-boot script staged, and the deployed OS would come up unencrypted
# with no signal. Pin -ErrorAction Stop on the New-Item + both Set-Content calls
# so any I/O miss surfaces as "Failed to stage BitLocker setup" instead.
$blNewItemGuarded = $content -match "New-Item\s+-ItemType\s+Directory\s+-Path\s+\`$scriptsDir[^\r\n]*-ErrorAction\s+Stop"
Write-Result -Test 'BitLocker New-Item uses -ErrorAction Stop' -Pass $blNewItemGuarded
$blSetContentGuarded = ([regex]::Matches($content, "Set-Content\s+-Path\s+`"\`$scriptsDir[^\r\n]*-ErrorAction\s+Stop")).Count -ge 2
Write-Result -Test 'BitLocker staging Set-Content calls use -ErrorAction Stop' -Pass $blSetContentGuarded
$blRecoveryLogged = $content -match 'First boot will come up UNENCRYPTED'
Write-Result -Test 'BitLocker staging failure logs recovery guidance' -Pass $blRecoveryLogged

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

    # startnet.cmd invariants — the embedded here-string is silently critical:
    # a regression doesn't fail the build_boot_wim.ps1 run, it just produces
    # a boot.wim that misbehaves at deploy time. Guard the three brittle bits.
    #  - wpeinit: without it, WinPE never brings up the network stack, so any
    #    later remote-help / driver-fetch step fails with no obvious cause.
    #  - setlocal enabledelayedexpansion: required so the final
    #      powershell.exe ... !DEPLOYARGS!
    #    line and the {DRIVE} substitution actually expand — without it,
    #    deploy.args silently loses all its parameters.
    #  - {DRIVE}=%DEPLOY_IMAGE_DRIVE% substitution: the single-ISO end-user
    #    workflow relies on this to rewrite {DRIVE}\images\... paths at
    #    boot; dropping it breaks every build_iso.ps1 output.
    Write-Result -Test 'Builder: startnet.cmd runs wpeinit' -Pass ($bc -match '(?m)^\s*wpeinit\s*$')
    Write-Result -Test 'Builder: startnet.cmd enables delayed expansion' -Pass ($bc -match 'setlocal\s+enabledelayedexpansion')
    Write-Result -Test 'Builder: startnet.cmd substitutes {DRIVE} placeholder' -Pass ($bc -match '\{DRIVE\}=%DEPLOY_IMAGE_DRIVE%')
}

# Test 10: prepare_wim.ps1 — syntax + key behavioral invariants
Write-Host "`n--- scripts/prepare_wim.ps1 ---" -ForegroundColor Cyan
$prepOk = Test-ScriptSyntax -Path $prepPath -Label "WIM prep"
if ($prepOk) {
    $pc = Get-Content $prepPath -Raw

    # Output WIM destination name must derive from $target.ImageName, not a
    # hardcoded $Edition. Regressing to the literal "$Edition (Custom)" mis-
    # labels every captured WIM as 'Windows 11 Enterprise (Custom)' regardless
    # of source (the 2026-05-16 fix in CHANGELOG / routine log).
    Write-Result -Test 'WIM prep: destination name uses $target.ImageName' `
        -Pass ($pc -match '\$target\.ImageName' -and $pc -match '\$sourceName\s*=\s*if\s*\(\s*\$target\.ImageName')
    Write-Result -Test 'WIM prep: destination name not hardcoded "$Edition (Custom)"' `
        -Pass ($pc -notmatch '"\$Edition\s*\(Custom\)"' -and $pc -notmatch "'\`$Edition\s*\(Custom\)'")

    # Re-export must use max compression + integrity check. Either dropping
    # silently inflates output size or lets WIM corruption escape into
    # production deployments.
    Write-Result -Test 'WIM prep: re-export uses -CompressionType Max' `
        -Pass ($pc -match '-CompressionType\s+Max')
    Write-Result -Test 'WIM prep: re-export uses -CheckIntegrity' `
        -Pass ($pc -match 'Export-WindowsImage[\s\S]+?-CheckIntegrity')

    # -DriverPath must reject a folder with no .inf files; a silent regression
    # would let operators build with no drivers and not know until deploy.
    Write-Result -Test 'WIM prep: -DriverPath rejects empty .inf folder' `
        -Pass ($pc -match 'contains no \.inf files')

    # first-login.ps1 staging must stay gated on -DisableExtraBloat. Ungating
    # would silently change the staged image for plain -DisableCopilot runs.
    Write-Result -Test 'WIM prep: first-login.ps1 staging gated on $DisableExtraBloat' `
        -Pass ($pc -match 'if\s*\(\s*\$DisableExtraBloat\s*\)\s*\{[\s\S]{0,400}?first-login\.ps1')
}

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
    # Window is deliberately generous: other pre-flight checks (e.g. the
    # -BootUsbDrive format/accessibility guards) legitimately sit between
    # the branch open and the copype probe. What matters is that copype is
    # inside the branch, not how many siblings precede it.
    Write-Result -Test "Refresh: copype pre-flight gated by -RebuildBootWim Yes" `
        -Pass ($rc -match "RebuildBootWim\s+-eq\s+'Yes'[\s\S]{0,900}?Get-Command\s+copype")

    # prepare_wim.ps1 must NOT be gated on $LASTEXITCODE. It sets
    # $ErrorActionPreference = 'Stop' and throws on real failures, so a
    # genuine error already propagates out of the '& $prepScript' call.
    # $LASTEXITCODE, by contrast, reflects only the last *native* command
    # prepare_wim ran - typically 'reg.exe unload', which returns non-zero
    # on benign "handles still open" warnings. Gating on it produced false
    # failures on successful preps. Pin the explanatory comment so the
    # check doesn't get "helpfully" reintroduced.
    Write-Result -Test 'Refresh: prepare_wim.ps1 not gated on $LASTEXITCODE' `
        -Pass ($rc -notmatch '&\s+\$prepScript[\s\S]{0,200}?\$LASTEXITCODE\s+-ne\s+0')
    Write-Result -Test 'Refresh: $LASTEXITCODE-is-unreliable rationale documented' `
        -Pass ($rc -match 'NOT gate on \$LASTEXITCODE')

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

# Test 12: build_iso.ps1 — syntax + key behavioral invariants
# Mirrors the build_boot_wim block above (PR #52). Tests that the safety-
# critical shapes can't drift silently — each invariant maps to a documented
# behavior the deploy pipeline depends on:
#   - The destructive-intent gate (-ConfirmSilentDestructiveIso) must throw
#     when neither flag is set, so a default invocation can't produce a
#     silent disk-wiping ISO.
#   - The volume label must default to 'IMAGES' so the boot.wim startnet.cmd
#     drive-letter scan finds the data partition by `vol`-and-`find /i`.
#   - The WIM extension allowlist (.wim/.esd) must reject wrong file types
#     up front rather than failing inside oscdimg.
#   - The -WipeDisks regex must validate format so an injected token can't
#     land in deploy.args verbatim.
#   - oscdimg's -bootdata must include BOTH BIOS (etfsboot.com) and UEFI
#     (efisys.bin) bootloaders so the ISO boots on either firmware.
#   - The {DRIVE} placeholder must be embedded in generated deploy.args
#     paths so startnet.cmd's substitution finds it at boot time.
Write-Host "`n--- scripts/build_iso.ps1 ---" -ForegroundColor Cyan
$buildIsoOk = Test-ScriptSyntax -Path $buildIsoPath -Label "ISO builder"
if ($buildIsoOk) {
    $ic = Get-Content $buildIsoPath -Raw

    Write-Result -Test "ISO builder: -ConfirmSilentDestructiveIso gate present" `
        -Pass ($ic -match 'if\s*\(\s*-not\s+\$Interactive\s+-and\s+-not\s+\$ConfirmSilentDestructiveIso\s*\)')

    Write-Result -Test "ISO builder: VolumeLabel defaults to 'IMAGES'" `
        -Pass ($ic -match "\[string\]\`$VolumeLabel\s*=\s*'IMAGES'")

    Write-Result -Test "ISO builder: WIM extension allowlist (.wim/.esd) present" `
        -Pass ($ic -match "GetExtension\(\`$WimFile\)\s+-notin\s+'\.wim','\.esd'")

    Write-Result -Test "ISO builder: -WipeDisks regex validation present" `
        -Pass ($ic -match '\$WipeDisks\s+-notmatch\s+''\^\\s\*\\d\+')

    Write-Result -Test "ISO builder: oscdimg -bootdata references etfsboot.com (BIOS)" `
        -Pass ($ic -match 'etfsboot\.com')
    Write-Result -Test "ISO builder: oscdimg -bootdata references efisys.bin (UEFI)" `
        -Pass ($ic -match 'efisys\.bin')

    Write-Result -Test "ISO builder: deploy.args paths use {DRIVE} placeholder" `
        -Pass ($ic -match '\{DRIVE\}\\images')
}

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
