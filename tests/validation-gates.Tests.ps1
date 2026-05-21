<#
.SYNOPSIS
    Pester v5 smoke tests for the v4.7.0 BitLocker / data-disk safety gates.

.DESCRIPTION
    Loads unified_winpe_deploy.ps1 as a dynamic module (stripping the
    bottom auto-execute block before evaluation) so:
      - the script's destructive auto-exec never runs in CI, and
      - Pester Mock can intercept the script's internal functions
        cleanly via -ModuleName, and
      - the script's param() variables (TargetDisk, DataDiskNumber, etc.)
        can be mutated from outside via the `& $module { ... }` pattern.

    Covered invariants (each tied to a v4.7.0 safety guarantee):
      - DataDiskNumber default off (-1)
      - EnableBitLocker default off ($false)
      - BitLockerPin default $null
      - ForbiddenBitLockerPins contains 'ChangeMe123!'
      - Resolve-BitLockerKeyPath precedence (param > IMAGES > fallback,
        never D:\BitLocker)
      - New-DiskpartScript refuses to mountvol /d the WIM source drive
      - Start-Deployment validation gates reject:
          - -DataDiskNumber == -TargetDisk
          - nonexistent / system / USB-only -DataDiskNumber
          - -EnableBitLocker without -BitLockerPin
          - -EnableBitLocker -BitLockerPin '<5 chars>'
          - each placeholder PIN in ForbiddenBitLockerPins
          - -Silent -DataDiskNumber without -Force
      - Start-Deployment validation passes with -Silent -Force
        -DataDiskNumber explicit (mocks short-circuit before any
        destructive op runs).

    No real disks, no DISM, no ADK, no WinPE. Tests run on any
    Windows host with Pester v5 (preinstalled on GitHub
    windows-latest runners). PowerShell 5.1+ compatible.

.NOTES
    Run via:  Invoke-Pester -Path tests/validation-gates.Tests.ps1
    CI:       see .github/workflows/ci.yml job 'pester'
#>

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'unified_winpe_deploy.ps1'
    if (-not (Test-Path $scriptPath)) {
        throw "Cannot find unified_winpe_deploy.ps1 at $scriptPath"
    }

    $raw = Get-Content -Path $scriptPath -Raw

    # Strip the bottom auto-execute block. The marker is a stable comment
    # that has lived at this position since the script was written; the
    # masterize CI checks indirectly pin the surrounding code, so a refactor
    # that removes the marker would surface in CI before reaching these tests.
    $marker = '# Execute main process'
    $cut = $raw.IndexOf($marker)
    if ($cut -lt 0) {
        throw "Test seam marker '$marker' missing from script - update either the test or the script"
    }
    $body = $raw.Substring(0, $cut)

    # Also drop the #Requires -RunAsAdministrator line. The script enforces
    # it for real invocations; when we load the body as a dynamic module
    # the directive would refuse to run outside an admin shell, which CI
    # runners give us but local dev shells may not.
    $body = $body -replace '(?m)^#Requires\s+-RunAsAdministrator\s*$', ''

    # New-Module evaluates the body in its own scope. The param() block at
    # the top of the body declares the script's CLI params as module-scope
    # variables (bound to their defaults). We can later mutate them via
    # `& $module { $TargetDisk = 0 ; ... }`.
    $script:DeployModule = New-Module -Name 'DeployUnderTest' -ScriptBlock ([scriptblock]::Create($body)) |
        Import-Module -PassThru
}

AfterAll {
    if ($script:DeployModule) {
        Remove-Module -ModuleInfo $script:DeployModule -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Helper: set up the standard mock stack for Start-Deployment tests. Mocks
# every destructive entry point so a successful pass through Start-Deployment
# never touches a real disk. Validation-gate tests can rely on these mocks
# to drive execution to the gate of interest.
# ---------------------------------------------------------------------------
function Initialize-DeployMocks {
    param(
        [array]$Disks = @(
            [PSCustomObject]@{ Number=0; Size=500; Model='Target NVMe'; InterfaceType='SCSI'; HasPartitions=$false; PartitionInfo='No partitions'; IsSystemDisk=$false }
            [PSCustomObject]@{ Number=1; Size=500; Model='Data NVMe';   InterfaceType='SCSI'; HasPartitions=$true;  PartitionInfo='Part1:500GB'; IsSystemDisk=$false }
        ),
        $TargetDiskOverride = $null,
        [string]$ReadHostReturn = 'WIPE DATA'
    )

    # Pester executes -ModuleName mock scriptblocks in the module's scope, so
    # local function variables like $Disks are invisible there. Push all
    # mock data into $Script: variables on the module first, then reference
    # them as $Script:MockDisks etc. inside the mock bodies.
    #
    # PSModuleInfo does not forward positional args when called as
    # `& $module { param($x) } $arg` — $x would be $null. The correct API
    # is NewBoundScriptBlock, which creates a scriptblock that executes in
    # the module's scope and accepts parameters like any normal scriptblock.
    $initData = $script:DeployModule.NewBoundScriptBlock({
        param($d, $tdo, $rhr)
        $Script:CapturedLogs       = New-Object System.Collections.ArrayList
        $Script:MockDisks          = $d
        $Script:MockTargetDisk     = $tdo
        $Script:MockReadHostReturn = $rhr
    })
    & $initData $Disks $TargetDiskOverride $ReadHostReturn

    Mock -ModuleName DeployUnderTest -CommandName Test-Administrator     -MockWith { $true }
    Mock -ModuleName DeployUnderTest -CommandName Initialize-SystemPaths -MockWith { }
    Mock -ModuleName DeployUnderTest -CommandName Find-ImageFiles        -MockWith {
        @(@{ Path='I:\images\Win.wim'; Name='Win.wim'; Size=10GB; Type='Mock'; LastModified=(Get-Date) })
    }
    Mock -ModuleName DeployUnderTest -CommandName Show-ImageSelection    -MockWith {
        @{ Path='I:\images\Win.wim'; Name='Win.wim'; Size=10GB; Type='Mock'; LastModified=(Get-Date) }
    }
    Mock -ModuleName DeployUnderTest -CommandName Get-WimImageInfo       -MockWith {
        @(@{ Index=1; Name='Test'; Description='Test'; Size='10000000000' })
    }
    Mock -ModuleName DeployUnderTest -CommandName Select-ImageIndex      -MockWith { 1 }
    Mock -ModuleName DeployUnderTest -CommandName Test-WinPEEnvironment  -MockWith { $true }
    Mock -ModuleName DeployUnderTest -CommandName Test-SystemMemory      -MockWith { $true }
    Mock -ModuleName DeployUnderTest -CommandName Invoke-CctkConfig      -MockWith { $true }
    Mock -ModuleName DeployUnderTest -CommandName Get-SystemDisks        -MockWith { ,$Script:MockDisks }
    if ($TargetDiskOverride) {
        Mock -ModuleName DeployUnderTest -CommandName Select-TargetDisk  -MockWith { $Script:MockTargetDisk }
    } else {
        Mock -ModuleName DeployUnderTest -CommandName Select-TargetDisk  -MockWith { $Script:MockDisks[0] }
    }
    Mock -ModuleName DeployUnderTest -CommandName Select-AdditionalWipeDisks -MockWith { ,@() }
    Mock -ModuleName DeployUnderTest -CommandName New-DiskpartScript     -MockWith { $true }
    Mock -ModuleName DeployUnderTest -CommandName Invoke-Diskpart        -MockWith { $true }
    Mock -ModuleName DeployUnderTest -CommandName Apply-WindowsImage     -MockWith { $true }
    Mock -ModuleName DeployUnderTest -CommandName Set-BootConfiguration  -MockWith { $true }
    Mock -ModuleName DeployUnderTest -CommandName Initialize-BitLockerSetup -MockWith { $true }
    # Post-diskpart Test-Path loop expects S:\, C:\, (D:\)
    Mock -ModuleName DeployUnderTest -CommandName Test-Path -MockWith { $true }
    # Final shutdown prompt + WIPE DATA confirmation
    Mock -ModuleName DeployUnderTest -CommandName Read-Host    -MockWith { $Script:MockReadHostReturn }
    Mock -ModuleName DeployUnderTest -CommandName Show-MessageBox -MockWith { 'No' }
    # Start-Sleep appears in the post-diskpart drive-letter retry loop; mock it
    # so the "Passes validation" test doesn't burn 2-6 real seconds.
    Mock -ModuleName DeployUnderTest -CommandName Start-Sleep  -MockWith { }
    Mock -ModuleName DeployUnderTest -CommandName Write-Log    -MockWith {
        param($Message, $Level)
        [void]$Script:CapturedLogs.Add(@{ Message = $Message; Level = $Level })
    }
}

function Get-CapturedLog {
    & $script:DeployModule { ,$Script:CapturedLogs }
}

function Test-LogContains {
    param([string]$Pattern)
    $logs = Get-CapturedLog
    return [bool]($logs | Where-Object { $_.Message -match $Pattern })
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

Describe "v4.7.0 default configuration (must stay opt-in)" {

    It "DataDiskNumber default is -1 (off)" {
        $val = & $script:DeployModule { $Script:Config.DataDiskNumber }
        $val | Should -Be -1
    }

    It "EnableBitLocker default is `$false (off)" {
        $val = & $script:DeployModule { $Script:Config.EnableBitLocker }
        $val | Should -BeFalse
    }

    It "BitLockerPin default is `$null" {
        $val = & $script:DeployModule { $Script:Config.BitLockerPin }
        $val | Should -BeNullOrEmpty
    }

    It "ForbiddenBitLockerPins includes the v4.6.x placeholder" {
        $forbidden = & $script:DeployModule { ,$Script:Config.ForbiddenBitLockerPins }
        $forbidden | Should -Contain 'ChangeMe123!'
    }
}

Describe "Resolve-BitLockerKeyPath escrow precedence" {

    AfterEach {
        Remove-Item Env:DEPLOY_IMAGE_DRIVE -ErrorAction SilentlyContinue
        & $script:DeployModule { $BitLockerKeyPath = $null }
    }

    It "Returns the -BitLockerKeyPath override when set" {
        $result = & $script:DeployModule {
            $BitLockerKeyPath = '\\fileserver\BitLockerKeys'
            Resolve-BitLockerKeyPath
        }
        $result.Path   | Should -Be '\\fileserver\BitLockerKeys'
        $result.Source | Should -Match 'parameter'
    }

    It "Falls back to <DEPLOY_IMAGE_DRIVE>\BitLockerKeys when env var is set" {
        # Use TestDrive (Pester's per-test temp dir) instead of a fictional
        # I: drive letter. Join-Path validates drive existence on PSv7+ and
        # would throw on hosts where I: isn't a real PSDrive (CI runners,
        # dev workstations). The production WinPE flow only sets
        # DEPLOY_IMAGE_DRIVE when startnet.cmd has confirmed the IMAGES
        # volume is mounted, so it always resolves there.
        $env:DEPLOY_IMAGE_DRIVE = $TestDrive
        $result = & $script:DeployModule {
            $BitLockerKeyPath = $null
            Resolve-BitLockerKeyPath
        }
        $result.Path   | Should -Be (Join-Path $TestDrive 'BitLockerKeys')
        $result.Source | Should -Be 'IMAGES partition'
    }

    It "NEVER falls back to D:\BitLocker (v4.6.x regression block)" {
        # No env, no param -> last-resort fallback must NOT be the encrypted
        # volume that the recovery keys are meant to recover.
        $result = & $script:DeployModule {
            $BitLockerKeyPath = $null
            Resolve-BitLockerKeyPath
        }
        $result.Path | Should -Not -Be 'D:\BitLocker'
        $result.Path | Should -Not -Match '^D:'
        $result.Path | Should -Match 'C:\\Windows'
    }
}

Describe "New-DiskpartScript source-drive protection" {

    BeforeEach {
        # Pretend D:\ exists so the letter-free loop reaches the guard
        Mock -ModuleName DeployUnderTest -CommandName Test-Path -ParameterFilter { $Path -eq 'D:\' } -MockWith { $true }
        Mock -ModuleName DeployUnderTest -CommandName Test-Path -ParameterFilter { $Path -ne 'D:\' } -MockWith { $false }
        Mock -ModuleName DeployUnderTest -CommandName Set-Content -MockWith { }
        Mock -ModuleName DeployUnderTest -CommandName Write-Log -MockWith { }
        # Prevent any real mountvol invocation just in case
        Mock -ModuleName DeployUnderTest -CommandName mountvol -MockWith { }
    }

    It "Refuses to mountvol /d the WIM source drive when -DataDiskNumber would unmount it" {
        # DataDiskNumber >= 0 puts D into lettersToFree. ProtectedSourceDrive='D:'
        # should make New-DiskpartScript return $false BEFORE issuing mountvol.
        $result = & $script:DeployModule {
            $Script:Config.DataDiskNumber = 1
            $Script:SystemPaths.DiskpartScript = Join-Path $env:TEMP 'fake_diskpart.txt'
            New-DiskpartScript -DiskNumber 0 -ProtectedSourceDrive 'D:'
        }
        $result | Should -BeFalse
    }

    It "Proceeds when -DataDiskNumber is off (D not in letters to free)" {
        $result = & $script:DeployModule {
            $Script:Config.DataDiskNumber = -1
            $Script:SystemPaths.DiskpartScript = Join-Path $env:TEMP 'fake_diskpart.txt'
            New-DiskpartScript -DiskNumber 0 -ProtectedSourceDrive 'D:'
        }
        $result | Should -BeTrue
    }
}

Describe "Start-Deployment validation gates" {

    BeforeEach {
        Initialize-DeployMocks
        # Reset all CLI param vars to their defaults before each test
        & $script:DeployModule {
            $WimFile          = $null
            $ImagePath        = $null
            $TargetDisk       = -1
            $WipeDisks        = $null
            $UnattendFile     = $null
            $DataDiskNumber   = -1
            $EnableBitLocker  = $false
            $BitLockerPin     = $null
            $BitLockerKeyPath = $null
            $Force            = $false
            $Silent           = $false
            $ListOnly         = $false
            $Script:Config.DataDiskNumber  = -1
            $Script:Config.EnableBitLocker = $false
            $Script:Config.BitLockerPin    = $null
        }
    }

    It "Rejects -DataDiskNumber equal to -TargetDisk" {
        $result = & $script:DeployModule {
            $WimFile        = 'I:\images\Win.wim'
            $TargetDisk     =  0
            $DataDiskNumber =  0   # same as target
            $Force          = $true
            $Silent         = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        (Test-LogContains 'same as the target disk') | Should -BeTrue
    }

    It "Rejects a nonexistent -DataDiskNumber before any destructive op" {
        $result = & $script:DeployModule {
            $WimFile        = 'I:\images\Win.wim'
            $TargetDisk     =  0
            $DataDiskNumber = 99    # not in mocked disk list
            $Force          = $true
            $Silent         = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        (Test-LogContains 'not a valid non-USB internal disk') | Should -BeTrue
        # Confirm no destructive call slipped through
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart -Times 0
        Should -Invoke -ModuleName DeployUnderTest -CommandName Apply-WindowsImage -Times 0
    }

    It "Rejects -DataDiskNumber pointing at the system disk" {
        $disks = @(
            [PSCustomObject]@{ Number=0; Size=500; Model='Target'; InterfaceType='SCSI'; HasPartitions=$false; PartitionInfo='No partitions'; IsSystemDisk=$false }
            [PSCustomObject]@{ Number=1; Size=500; Model='System'; InterfaceType='SCSI'; HasPartitions=$true;  PartitionInfo='Part1:500GB'; IsSystemDisk=$true }
        )
        Initialize-DeployMocks -Disks $disks
        $result = & $script:DeployModule {
            $WimFile        = 'I:\images\Win.wim'
            $TargetDisk     =  0
            $DataDiskNumber =  1   # IsSystemDisk=$true in mock
            $Force          = $true
            $Silent         = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        (Test-LogContains 'is the system disk') | Should -BeTrue
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart -Times 0
    }

    It "Excludes USB-only disks from the -DataDiskNumber pick (filtered by Get-SystemDisks)" {
        # Get-SystemDisks already excludes USB. Verify by giving it a USB-only
        # set and showing -DataDiskNumber pointing at the USB disk number is
        # rejected as "not a valid non-USB internal disk".
        $disks = @(
            [PSCustomObject]@{ Number=0; Size=500;  Model='Target';  InterfaceType='SCSI'; HasPartitions=$false; PartitionInfo='No partitions'; IsSystemDisk=$false }
            # USB disk would have been filtered out by Get-SystemDisks - simulate
            # by simply not including it in the mocked list.
        )
        Initialize-DeployMocks -Disks $disks
        $result = & $script:DeployModule {
            $WimFile        = 'I:\images\Win.wim'
            $TargetDisk     =  0
            $DataDiskNumber =  1   # The "USB" disk that Get-SystemDisks filtered out
            $Force          = $true
            $Silent         = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        (Test-LogContains 'not a valid non-USB internal disk') | Should -BeTrue
    }

    It "Rejects -EnableBitLocker without -BitLockerPin" {
        $result = & $script:DeployModule {
            $WimFile         = 'I:\images\Win.wim'
            $TargetDisk      =  0
            $Force           = $true
            $Silent          = $true
            $EnableBitLocker = $true
            $BitLockerPin    = $null
            Start-Deployment
        }
        $result | Should -BeFalse
        (Test-LogContains 'requires -BitLockerPin') | Should -BeTrue
    }

    It "Rejects -EnableBitLocker -BitLockerPin '<5 chars>' (below length floor)" {
        $result = & $script:DeployModule {
            $WimFile         = 'I:\images\Win.wim'
            $TargetDisk      =  0
            $Force           = $true
            $Silent          = $true
            $EnableBitLocker = $true
            $BitLockerPin    = 'abcde'   # 5 chars, floor is 6
            Start-Deployment
        }
        $result | Should -BeFalse
        (Test-LogContains '6-20 characters') | Should -BeTrue
    }

    It "Rejects each entry in ForbiddenBitLockerPins" -ForEach @(
        @{ Pin = 'ChangeMe123!' }
        @{ Pin = 'password'     }
        @{ Pin = 'Password1'    }
        @{ Pin = '123456'       }
    ) {
        Initialize-DeployMocks
        $captured = & $script:DeployModule {
            param($p)
            $WimFile         = 'I:\images\Win.wim'
            $TargetDisk      =  0
            $Force           = $true
            $Silent          = $true
            $EnableBitLocker = $true
            $BitLockerPin    = $p
            $result = Start-Deployment
            ,@($result, $Script:CapturedLogs)
        } $Pin
        $captured[0] | Should -BeFalse
        ($captured[1] | Where-Object { $_.Message -match 'forbidden placeholder' }) | Should -Not -BeNullOrEmpty
    }

    It "Rejects -Silent -DataDiskNumber without -Force (WIPE DATA prompt cannot run silently)" {
        $result = & $script:DeployModule {
            $WimFile        = 'I:\images\Win.wim'
            $TargetDisk     =  0
            $DataDiskNumber =  1
            $Force          = $false   # the gate
            $Silent         = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        (Test-LogContains 'prompt cannot run silently') | Should -BeTrue
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart -Times 0
    }

    It "Passes validation phase with -Silent -Force -DataDiskNumber explicit (mocks short-circuit before diskpart)" {
        $result = & $script:DeployModule {
            $WimFile        = 'I:\images\Win.wim'
            $TargetDisk     =  0
            $DataDiskNumber =  1
            $Force          = $true
            $Silent         = $true
            Start-Deployment
        }
        $result | Should -BeTrue
        # The mocks let it run all the way through; no rejection log line
        (Test-LogContains 'aborting') | Should -BeFalse
        # But the destructive entry points were called - confirming the gates
        # actually passed and the path reached them (mocks intercept, no real
        # disk touched).
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart    -Times 1
        Should -Invoke -ModuleName DeployUnderTest -CommandName Apply-WindowsImage -Times 1
        Should -Invoke -ModuleName DeployUnderTest -CommandName Set-BootConfiguration -Times 1
    }

    It "Passes the wiring: -DataDiskNumber 1 actually sets `$Script:Config.DataDiskNumber" {
        # Regression guard for the PSBoundParameters scope bug fixed in
        # commit 3d6ca95 (Start-Deployment is a function with no params,
        # so $PSBoundParameters there is always empty - we must read the
        # script-level param directly).
        & $script:DeployModule {
            $WimFile        = 'I:\images\Win.wim'
            $TargetDisk     =  0
            $DataDiskNumber =  1
            $Force          = $true
            $Silent         = $true
            Start-Deployment | Out-Null
        }
        $val = & $script:DeployModule { $Script:Config.DataDiskNumber }
        $val | Should -Be 1
    }

    It "Passes the wiring: -BitLockerPin 'goodpin42' actually sets `$Script:Config.BitLockerPin" {
        & $script:DeployModule {
            $WimFile         = 'I:\images\Win.wim'
            $TargetDisk      =  0
            $Force           = $true
            $Silent          = $true
            $EnableBitLocker = $true
            $BitLockerPin    = 'goodpin42'
            Start-Deployment | Out-Null
        }
        $val = & $script:DeployModule { $Script:Config.BitLockerPin }
        $val | Should -Be 'goodpin42'
    }
}
