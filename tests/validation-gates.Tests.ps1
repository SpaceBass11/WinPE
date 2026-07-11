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
      - Resolve-BitLockerKeyPath precedence (param > IMAGES > fallback,
        never D:\BitLocker)
      - New-DiskpartScript refuses to mountvol /d the WIM source drive
      - Start-Deployment validation gates reject:
          - -DataDiskNumber == -TargetDisk
          - nonexistent / system / USB-only -DataDiskNumber
          - -EnableBitLocker without -BitLockerPin
          - -EnableBitLocker -BitLockerPin '<5 chars>'
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
        # -Match (not -Be) so the test stays green when the human-readable
        # Source suffix evolves (e.g. v4.7.1 added a "keep USB plugged in"
        # hint to this string). Same pattern as the parameter-override test
        # above.
        $result.Source | Should -Match 'IMAGES partition'
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

    # All mock setup lives directly in BeforeEach. Pester v5 does not expose
    # functions defined outside of Pester blocks (script root, BeforeAll) to
    # BeforeEach during the run phase. Inlining is the only reliable pattern.
    BeforeEach {
        # Reset log capture. Use $Global: rather than $Script: because Pester v5
        # mock bodies (with -ModuleName) execute in a scope where neither the
        # test-script $Script: nor the module's $Script: is reliably visible.
        # $Global: is unambiguous everywhere.
        $Global:CapturedLogs = New-Object System.Collections.ArrayList

        # Reset all CLI param vars to their defaults
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
        # Default disk set: disk 0 = target, disk 1 = data. Both non-system, non-USB.
        # Individual tests that need a different topology re-register just this mock.
        Mock -ModuleName DeployUnderTest -CommandName Get-SystemDisks -MockWith {
            ,@(
                [PSCustomObject]@{ Number=0; Size=500; Model='Target NVMe'; InterfaceType='SCSI'; HasPartitions=$false; PartitionInfo='No partitions'; IsSystemDisk=$false }
                [PSCustomObject]@{ Number=1; Size=500; Model='Data NVMe';   InterfaceType='SCSI'; HasPartitions=$true;  PartitionInfo='Part1:500GB'; IsSystemDisk=$false }
            )
        }
        Mock -ModuleName DeployUnderTest -CommandName Select-TargetDisk -MockWith {
            [PSCustomObject]@{ Number=0; Size=500; Model='Target NVMe'; InterfaceType='SCSI'; HasPartitions=$false; PartitionInfo='No partitions'; IsSystemDisk=$false }
        }
        Mock -ModuleName DeployUnderTest -CommandName Select-AdditionalWipeDisks -MockWith { ,@() }
        Mock -ModuleName DeployUnderTest -CommandName New-DiskpartScript     -MockWith { $true }
        Mock -ModuleName DeployUnderTest -CommandName Invoke-Diskpart        -MockWith { $true }
        Mock -ModuleName DeployUnderTest -CommandName Apply-WindowsImage     -MockWith { $true }
        Mock -ModuleName DeployUnderTest -CommandName Set-BootConfiguration  -MockWith { $true }
        Mock -ModuleName DeployUnderTest -CommandName Initialize-BitLockerSetup -MockWith { $true }
        Mock -ModuleName DeployUnderTest -CommandName Test-Path              -MockWith { $true }
        Mock -ModuleName DeployUnderTest -CommandName Read-Host              -MockWith { 'WIPE DATA' }
        Mock -ModuleName DeployUnderTest -CommandName Show-MessageBox        -MockWith { 'No' }
        Mock -ModuleName DeployUnderTest -CommandName Start-Sleep            -MockWith { }
        Mock -ModuleName DeployUnderTest -CommandName Write-Log              -MockWith {
            param($Message, $Level)
            [void]$Global:CapturedLogs.Add(@{ Message = $Message; Level = $Level })
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
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'same as the target disk' }) | Should -Not -BeNullOrEmpty
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
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'not a valid non-USB internal disk' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart    -Times 0
        Should -Invoke -ModuleName DeployUnderTest -CommandName Apply-WindowsImage -Times 0
    }

    It "Rejects -DataDiskNumber pointing at the system disk" {
        Mock -ModuleName DeployUnderTest -CommandName Get-SystemDisks -MockWith {
            ,@(
                [PSCustomObject]@{ Number=0; Size=500; Model='Target'; InterfaceType='SCSI'; HasPartitions=$false; PartitionInfo='No partitions'; IsSystemDisk=$false }
                [PSCustomObject]@{ Number=1; Size=500; Model='System'; InterfaceType='SCSI'; HasPartitions=$true;  PartitionInfo='Part1:500GB'; IsSystemDisk=$true }
            )
        }
        $result = & $script:DeployModule {
            $WimFile        = 'I:\images\Win.wim'
            $TargetDisk     =  0
            $DataDiskNumber =  1   # IsSystemDisk=$true in mock
            $Force          = $true
            $Silent         = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'is the system disk' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart -Times 0
    }

    It "Excludes USB-only disks from the -DataDiskNumber pick (filtered by Get-SystemDisks)" {
        Mock -ModuleName DeployUnderTest -CommandName Get-SystemDisks -MockWith {
            ,@(
                [PSCustomObject]@{ Number=0; Size=500; Model='Target'; InterfaceType='SCSI'; HasPartitions=$false; PartitionInfo='No partitions'; IsSystemDisk=$false }
            )
        }
        $result = & $script:DeployModule {
            $WimFile        = 'I:\images\Win.wim'
            $TargetDisk     =  0
            $DataDiskNumber =  1   # not returned by Get-SystemDisks mock
            $Force          = $true
            $Silent         = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'not a valid non-USB internal disk' }) | Should -Not -BeNullOrEmpty
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
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'requires -BitLockerPin' }) | Should -Not -BeNullOrEmpty
    }

    It "Rejects -EnableBitLocker -BitLockerPin five-char value below length floor" {
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
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match '6-20 characters' }) | Should -Not -BeNullOrEmpty
    }

    It "Warns when -BitLockerKeyPath is provided without -EnableBitLocker (parallel to -BitLockerPin gate)" {
        # -BitLockerKeyPath is only consulted through Resolve-BitLockerKeyPath,
        # which is called from Initialize-BitLockerSetup, which early-returns when
        # EnableBitLocker is off. Without this warning the operator's escrow
        # override is silently ignored - same failure mode as the pre-existing
        # -BitLockerPin-without-EnableBitLocker warning.
        & $script:DeployModule {
            $WimFile          = 'I:\images\Win.wim'
            $TargetDisk       =  0
            $Force            = $true
            $Silent           = $true
            $EnableBitLocker  = $false
            $BitLockerKeyPath = '\\fileserver\BitLockerKeys'
            Start-Deployment | Out-Null
        }
        $logs = $Global:CapturedLogs
        ($logs | Where-Object {
            $_.Level -eq 'Warning' -and $_.Message -match '-BitLockerKeyPath provided without -EnableBitLocker'
        }) | Should -Not -BeNullOrEmpty
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
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'requires -Force' }) | Should -Not -BeNullOrEmpty
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
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'aborting' }) | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart       -Times 1
        Should -Invoke -ModuleName DeployUnderTest -CommandName Apply-WindowsImage    -Times 1
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
