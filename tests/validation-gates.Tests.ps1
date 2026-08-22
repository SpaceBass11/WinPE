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
          - -Silent without -WimFile / -TargetDisk / -Force
          - -Silent with malformed -WipeDisks (non-decimal token)
      - Start-Deployment warns but proceeds when -BitLockerPin is
        provided without -EnableBitLocker (the only surface telling
        the operator their PIN did nothing).
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

    # ---- v4.7.1 LookupMode contract ----
    # The LookupMode field added in v4.7.1 drives which branch of
    # Initialize-BitLockerSetup runs: 'ImagesLabel' bakes a runtime
    # `Get-Volume -FileSystemLabel 'IMAGES'` lookup into the staged
    # first-boot script (survives Windows reassigning the USB letter);
    # 'Literal' bakes the resolved path verbatim. A regression that
    # drops the field, mis-spells the value, or flips a branch silently
    # breaks the v4.7.1 escrow fix - recovery keys would fail to write
    # to the USB when the drive letter shifted between WinPE and Windows.

    It "LookupMode='Literal' for the -BitLockerKeyPath override (no per-boot lookup)" {
        $result = & $script:DeployModule {
            $BitLockerKeyPath = '\\fileserver\BitLockerKeys'
            Resolve-BitLockerKeyPath
        }
        $result.LookupMode | Should -Be 'Literal'
    }

    It "LookupMode='Literal' even when env var ALSO set (override wins precedence)" {
        # Regression guard: the IMAGES-label lookup must NOT activate when the
        # operator pinned an explicit escrow path. Their UNC share has no IMAGES
        # label and the runtime Get-Volume call would fall through to C:.
        $env:DEPLOY_IMAGE_DRIVE = $TestDrive
        $result = & $script:DeployModule {
            $BitLockerKeyPath = '\\fileserver\BitLockerKeys'
            Resolve-BitLockerKeyPath
        }
        $result.Path       | Should -Be '\\fileserver\BitLockerKeys'
        $result.LookupMode | Should -Be 'Literal'
    }

    It "LookupMode='ImagesLabel' when DEPLOY_IMAGE_DRIVE is set and no override" {
        # This is the v4.7.1 fix path. The Path field is informational
        # (operator log line); the runtime lookup ignores it.
        $env:DEPLOY_IMAGE_DRIVE = $TestDrive
        $result = & $script:DeployModule {
            $BitLockerKeyPath = $null
            Resolve-BitLockerKeyPath
        }
        $result.LookupMode | Should -Be 'ImagesLabel'
    }

    It "LookupMode='Literal' on the final fallback (no env, no override)" {
        # C:\Windows\Setup\BitLockerKeys is a fixed path on the encrypted
        # volume - no label lookup possible or needed.
        $result = & $script:DeployModule {
            $BitLockerKeyPath = $null
            Resolve-BitLockerKeyPath
        }
        $result.LookupMode | Should -Be 'Literal'
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

    # -------------------------------------------------------------------
    # Silent-mode bare-precondition gates (lines 1701-1717 in the script).
    # PR #125's body called these out as the next-untested Pester gaps:
    # an unattended run with any of -WimFile / -TargetDisk / -Force
    # missing — or with a malformed -WipeDisks string — must abort BEFORE
    # the first destructive op (Invoke-Diskpart). A regression that
    # swapped any of these guards would let a misconfigured CI/build
    # pipeline run to disk-wipe with operator-required inputs unmet.
    # -------------------------------------------------------------------

    It "Rejects -Silent without -WimFile" {
        $result = & $script:DeployModule {
            $WimFile    = $null   # missing
            $TargetDisk =  0
            $Force      = $true
            $Silent     = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'Silent mode requires -WimFile' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart    -Times 0
        Should -Invoke -ModuleName DeployUnderTest -CommandName Apply-WindowsImage -Times 0
    }

    It "Rejects -Silent without -TargetDisk" {
        $result = & $script:DeployModule {
            $WimFile    = 'I:\images\Win.wim'
            $TargetDisk = -1      # missing (default sentinel)
            $Force      = $true
            $Silent     = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'Silent mode requires -TargetDisk' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart    -Times 0
        Should -Invoke -ModuleName DeployUnderTest -CommandName Apply-WindowsImage -Times 0
    }

    It "Rejects -Silent without -Force" {
        $result = & $script:DeployModule {
            $WimFile    = 'I:\images\Win.wim'
            $TargetDisk =  0
            $Force      = $false  # the gate
            $Silent     = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'Silent mode requires -Force' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart    -Times 0
        Should -Invoke -ModuleName DeployUnderTest -CommandName Apply-WindowsImage -Times 0
    }

    It "Rejects -Silent with malformed -WipeDisks string" {
        # Anything other than comma-separated decimals trips the regex gate
        # at line 1714 in Start-Deployment. A typo'd entry like 'sda1' would
        # silently fall through to Select-AdditionalWipeDisks's [int] cast
        # if this gate ever regressed.
        $result = & $script:DeployModule {
            $WimFile    = 'I:\images\Win.wim'
            $TargetDisk =  0
            $WipeDisks  = '1,sda,2'  # not '^\s*\d+(\s*,\s*\d+)*\s*$'
            $Force      = $true
            $Silent     = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'must be comma-separated disk numbers' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart    -Times 0
        Should -Invoke -ModuleName DeployUnderTest -CommandName Apply-WindowsImage -Times 0
    }

    It "Warns when -BitLockerPin is provided without -EnableBitLocker, but does not abort" {
        # Line 1696-1698 in the script: a stray PIN with no encryption switch
        # is operator error (or stale args), but it's not fatal — the PIN is
        # logged as ignored and the deploy proceeds. The warning is the only
        # surface telling the operator "your PIN did nothing" — losing it
        # silently would let an operator believe BitLocker was on when it
        # wasn't.
        $result = & $script:DeployModule {
            $WimFile         = 'I:\images\Win.wim'
            $TargetDisk      =  0
            $Force           = $true
            $Silent          = $true
            $EnableBitLocker = $false       # off
            $BitLockerPin    = 'goodpin42'  # set anyway
            Start-Deployment
        }
        $result | Should -BeTrue
        $logs = $Global:CapturedLogs
        $warn = $logs | Where-Object { $_.Message -match 'PIN ignored' -and $_.Level -eq 'Warning' }
        $warn | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Apply-WindowsImage -Times 1
    }
}
