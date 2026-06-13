<#
.SYNOPSIS
    Fixture test for Initialize-BitLockerSetup's generated bitlocker-setup.ps1
    first-boot script in unified_winpe_deploy.ps1.

.DESCRIPTION
    Initialize-BitLockerSetup emits a multi-section here-string into
    C:\Windows\Setup\Scripts\bitlocker-setup.ps1 at deploy time. A staged
    SetupComplete.cmd runs that .ps1 at first boot to enable BitLocker on
    C: (and optionally D:).

    If the generated .ps1 is syntactically invalid, PowerShell rejects it
    at first boot, SetupComplete.cmd's exit code is not checked, and the
    machine boots with BitLocker NEVER enabled - the operator only finds
    out by inspecting manage-bde -status manually after the deploy looks
    successful. Exactly the silent-failure class a pre-flight parse
    check exists to catch.

    Risk surfaces the test guards against:

      1. PIN escape regression - the script doubles ' in the PIN value
         for embedding in a single-quoted PS literal. A refactor that
         drops or weakens the doubling produces a malformed string
         literal when an apostrophe is in the PIN.
      2. recovery-dir branch regression - the function emits one of two
         branches (IMAGES-label lookup vs Literal path) that must each
         parse cleanly. A code edit that breaks the here-string
         splicing in either branch fails the parse.
      3. DataDisk branch regression - the optional D: section is
         appended only when -DataDiskNumber is set. The concatenation
         site must produce a well-formed combined script.

    No real disks, no DISM, no first-boot run. The deploy script is
    loaded as a dynamic module (same body-stripping seam as
    tests/validation-gates.Tests.ps1), Set-Content / Write-Log /
    Test-Path / New-Item are overridden via module-scope function
    definitions, and the captured generated script is fed through
    Language.Parser::ParseInput to assert error count = 0.

    Works with PowerShell 5.1+. Returns exit code 0 on success, 1 on
    failure. Wired into the CI 'syntax' job alongside the other
    fixture tests.
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

Write-Host "`n=== WinPE Deploy - BitLocker Setup Script Tests ===" -ForegroundColor Cyan

if (-not (Test-Path $scriptPath)) {
    Write-Result -Test "Deploy script exists at $scriptPath" -Pass $false
    exit 1
}

# ---------------------------------------------------------------------------
# Load the deploy script as a dynamic module so we can call
# Initialize-BitLockerSetup directly. Strip the bottom auto-execute block
# (same stable seam validation-gates.Tests.ps1 uses) and the
# #Requires -RunAsAdministrator line which would refuse to run outside an
# admin shell.
# ---------------------------------------------------------------------------
$raw = Get-Content -Path $scriptPath -Raw
$marker = '# Execute main process'
$cut = $raw.IndexOf($marker)
if ($cut -lt 0) {
    Write-Result -Test "Test seam marker '$marker' found in script" -Pass $false `
        -Detail "the marker comment must stay in the script for this test to work"
    exit 1
}
$body = $raw.Substring(0, $cut) -replace '(?m)^#Requires\s+-RunAsAdministrator\s*$', ''

# Suppress the System.Windows.Forms load warning on Linux runners
$WarningPreference = 'SilentlyContinue'
$mod = New-Module -Name 'DeployBitLockerTest' -ScriptBlock ([scriptblock]::Create($body)) | Import-Module -PassThru
$WarningPreference = 'Continue'

# Override Set-Content / Write-Log / Test-Path / New-Item inside the
# module's scope. Function definitions in the same scope take precedence
# over cmdlets at command resolution. Captured output lives on the
# module so the mock function can reach it - function definitions don't
# close over local variables the way scriptblocks do.
& $mod {
    $Script:Captured = @{}
    function script:Write-Log { param([string]$Message, [string]$Level) }
    function script:Test-Path { param($Path, $PathType) $true }
    function script:New-Item { param($ItemType, $Path, [switch]$Force) }
    function script:Set-Content {
        param($Path, $Value, $Encoding, [switch]$Force)
        $Script:Captured[$Path] = $Value
    }
}

# Helper: reset module state, run Initialize-BitLockerSetup with a config
# permutation, return @{ Result; PsScript; CmdScript }.
function Invoke-Permutation {
    param(
        [bool]$EnableBitLocker = $true,
        [string]$Pin = 'goodpin42',
        [int]$DataDiskNumber = -1,
        [string]$KeyPathOverride,
        [string]$ImagesDriveEnv
    )

    # Clear capture and env between runs so leftover state doesn't bleed
    & $mod { $Script:Captured.Clear() }
    Remove-Item Env:DEPLOY_IMAGE_DRIVE -ErrorAction SilentlyContinue
    if ($ImagesDriveEnv) { $env:DEPLOY_IMAGE_DRIVE = $ImagesDriveEnv }

    # Setup + invocation must live in a single `& $mod { ... }` scriptblock:
    # an in-block `$BitLockerKeyPath = ...` assignment is scriptblock-local
    # and does NOT persist into a later scriptblock invocation. Using the
    # `$Script:` prefix on the param() variable would persist, but staying
    # in one scriptblock mirrors how Resolve-BitLockerKeyPath's existing
    # Pester tests pass their fixture values (see validation-gates.Tests.ps1).
    $result = & $mod {
        param($eb, $pin, $ddn, $kp)
        $Script:Config.EnableBitLocker = $eb
        $Script:Config.BitLockerPin    = $pin
        $Script:Config.DataDiskNumber  = $ddn
        $BitLockerKeyPath              = $kp
        Initialize-BitLockerSetup
    } $EnableBitLocker $Pin $DataDiskNumber $KeyPathOverride
    [PSCustomObject]@{
        Result    = $result
        PsScript  = & $mod { $Script:Captured['C:\Windows\Setup\Scripts\bitlocker-setup.ps1'] }
        CmdScript = & $mod { $Script:Captured['C:\Windows\Setup\Scripts\SetupComplete.cmd'] }
    }
}

function Test-Parses {
    param([string]$Source)
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$null, [ref]$errs) | Out-Null
    return @{
        Ok       = ($errs.Count -eq 0)
        Errors   = $errs
        ErrCount = $errs.Count
        ErrMsgs  = ($errs | ForEach-Object { "L$($_.Extent.StartLineNumber):$($_.Message)" }) -join '; '
    }
}

# Resolve a real path for the IMAGES-label fixture: Join-Path validates
# drive existence on PSv7+, so we can't use a fictional 'I:'.
$imagesFixture = $env:TEMP
if (-not $imagesFixture) { $imagesFixture = '/tmp' }

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

Write-Host "`n--- IMAGES-label mode, no DataDisk ---" -ForegroundColor Cyan

$p = Invoke-Permutation -EnableBitLocker $true -Pin 'goodpin42' -DataDiskNumber -1 -ImagesDriveEnv $imagesFixture
Write-Result -Test "Initialize-BitLockerSetup returns `$true (ImagesLabel, no DataDisk)" -Pass ($p.Result -eq $true)
Write-Result -Test "bitlocker-setup.ps1 was written" -Pass ($null -ne $p.PsScript -and $p.PsScript.Length -gt 0) `
    -Detail "captured = $($p.PsScript.Length) bytes"
Write-Result -Test "SetupComplete.cmd was written"   -Pass ($null -ne $p.CmdScript -and $p.CmdScript.Length -gt 0)
$parse = Test-Parses $p.PsScript
Write-Result -Test "Generated bitlocker-setup.ps1 has zero parse errors" -Pass $parse.Ok -Detail $parse.ErrMsgs
Write-Result -Test "ImagesLabel branch emits 'IMAGES' label lookup" `
    -Pass ($p.PsScript -match "FileSystemLabel 'IMAGES'") -Detail "expected Get-Volume -FileSystemLabel 'IMAGES'"
Write-Result -Test "C: protector line present" `
    -Pass ($p.PsScript -match "Enable-BitLocker -MountPoint 'C:'") -Detail "expected Enable-BitLocker -MountPoint 'C:'"
Write-Result -Test "D: protector line ABSENT when no DataDisk" `
    -Pass (-not ($p.PsScript -match "Enable-BitLocker -MountPoint 'D:'")) -Detail "D: section must be opt-in"
Write-Result -Test "Self-delete of staged scripts present" `
    -Pass ($p.PsScript -match "Self-deleted staging scripts") -Detail "PIN-on-disk cleanup line must remain"

Write-Host "`n--- IMAGES-label mode, with DataDisk D: ---" -ForegroundColor Cyan

$p = Invoke-Permutation -EnableBitLocker $true -Pin 'goodpin42' -DataDiskNumber 1 -ImagesDriveEnv $imagesFixture
Write-Result -Test "Initialize-BitLockerSetup returns `$true (ImagesLabel + DataDisk)" -Pass ($p.Result -eq $true)
$parse = Test-Parses $p.PsScript
Write-Result -Test "Generated bitlocker-setup.ps1 parses with DataDisk appended" -Pass $parse.Ok -Detail $parse.ErrMsgs
Write-Result -Test "D: protector line PRESENT when DataDisk is set" `
    -Pass ($p.PsScript -match "Enable-BitLocker -MountPoint 'D:'") -Detail "expected D: protector"
Write-Result -Test "D: auto-unlock line present (tied to C: unlock)" `
    -Pass ($p.PsScript -match "Enable-BitLockerAutoUnlock -MountPoint 'D:'") -Detail "expected Enable-BitLockerAutoUnlock for D:"

Write-Host "`n--- Literal mode (-BitLockerKeyPath override) ---" -ForegroundColor Cyan

$p = Invoke-Permutation -EnableBitLocker $true -Pin 'goodpin42' -DataDiskNumber -1 -KeyPathOverride '\\fileserver\BitLockerKeys'
Write-Result -Test "Initialize-BitLockerSetup returns `$true (Literal override)" -Pass ($p.Result -eq $true)
$parse = Test-Parses $p.PsScript
Write-Result -Test "Generated bitlocker-setup.ps1 parses in Literal mode" -Pass $parse.Ok -Detail $parse.ErrMsgs
Write-Result -Test "Literal branch bakes verbatim path into single-quoted string" `
    -Pass ($p.PsScript -match [regex]::Escape("`$recoveryDir = '\\fileserver\BitLockerKeys'")) `
    -Detail "expected literal escrow path in `$recoveryDir assignment"
Write-Result -Test "Literal mode does NOT emit IMAGES-label lookup block" `
    -Pass (-not ($p.PsScript -match "FileSystemLabel 'IMAGES'")) -Detail "label lookup must be Literal-mode exclusive"

Write-Host "`n--- PIN escape regression guard ---" -ForegroundColor Cyan

# PIN with an embedded apostrophe must have it doubled so the single-quoted
# PS literal in the generated script is well-formed. A refactor that drops
# the -replace "'", "''" emits 'it's-a-pin' which is two adjacent literals
# and a free-floating bareword - a parse error in the .ps1, which is exactly
# what this fixture catches before the disk is wiped.
$p = Invoke-Permutation -EnableBitLocker $true -Pin "it's-a-pin" -DataDiskNumber -1 -ImagesDriveEnv $imagesFixture
Write-Result -Test "Initialize-BitLockerSetup returns `$true with apostrophe in PIN" -Pass ($p.Result -eq $true)
$parse = Test-Parses $p.PsScript
Write-Result -Test "Apostrophe-PIN generated script still parses (escape doubled)" -Pass $parse.Ok -Detail $parse.ErrMsgs
Write-Result -Test "Single quote in PIN is doubled in the emitted literal" `
    -Pass ($p.PsScript -match "ConvertTo-SecureString 'it''s-a-pin'") `
    -Detail "expected doubled '' in single-quoted literal"

# A PIN with backtick / dollar / double-quote stays inside the single-quoted
# literal too. Those characters are inert in PowerShell single-quoted strings,
# so the only escape concern is the apostrophe handled above - but the parse
# assertion guards against a future change to double-quoted embedding.
$p = Invoke-Permutation -EnableBitLocker $true -Pin '`$pin"42' -DataDiskNumber -1 -ImagesDriveEnv $imagesFixture
$parse = Test-Parses $p.PsScript
Write-Result -Test "Backtick / dollar / quote PIN still produces parseable script" -Pass $parse.Ok -Detail $parse.ErrMsgs

Write-Host "`n--- Early-exit branches ---" -ForegroundColor Cyan

$p = Invoke-Permutation -EnableBitLocker $false -Pin $null -DataDiskNumber -1
Write-Result -Test "Returns `$true and writes nothing when EnableBitLocker is `$false" `
    -Pass ($p.Result -eq $true -and $null -eq $p.PsScript) -Detail "expected early return with no Set-Content"

$p = Invoke-Permutation -EnableBitLocker $true -Pin $null -DataDiskNumber -1 -ImagesDriveEnv $imagesFixture
Write-Result -Test "Returns `$false and writes nothing when PIN is missing" `
    -Pass ($p.Result -eq $false -and $null -eq $p.PsScript) -Detail "expected hard-fail before Set-Content"

# ---------------------------------------------------------------------------
# Drift guard: safety-critical code shapes must still live in the deploy script
# ---------------------------------------------------------------------------

Write-Host "`n--- Drift guard ---" -ForegroundColor Cyan

$scriptText = Get-Content $scriptPath -Raw

Write-Result -Test "PIN escape doubling clause still present" `
    -Pass ($scriptText -match "BitLockerPin -replace `"'`", `"''`"") `
    -Detail "expected `$Script:Config.BitLockerPin -replace `"'`", `"''`""

Write-Result -Test "ImagesLabel branch detector ('FileSystemLabel') still in the staged script" `
    -Pass ($scriptText -match "FileSystemLabel 'IMAGES'") `
    -Detail "expected Get-Volume -FileSystemLabel 'IMAGES'"

Write-Result -Test "Self-delete block still in the staged script" `
    -Pass ($scriptText -match 'bitlocker-setup\.ps1') `
    -Detail "expected reference to staged bitlocker-setup.ps1 in the deploy script"

Write-Result -Test "SetupComplete.cmd wrapper still generated" `
    -Pass ($scriptText -match 'SetupComplete\.cmd') `
    -Detail "expected SetupComplete.cmd literal in the deploy script"

# --- Summary ---
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "Passed: $passed" -ForegroundColor Green
Write-Host "Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })

Remove-Module DeployBitLockerTest -Force -ErrorAction SilentlyContinue
Remove-Item Env:DEPLOY_IMAGE_DRIVE -ErrorAction SilentlyContinue

if ($failed -gt 0) {
    exit 1
} else {
    Write-Host "`nAll checks passed!" -ForegroundColor Green
    exit 0
}
