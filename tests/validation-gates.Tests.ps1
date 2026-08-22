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

Describe "Test-FinalWipeConfirmation typed-confirmation parser" {

    # Guards the shared parser for the final "ERASE" prompt in both the
    # -TargetDisk-preselected path (Select-TargetDisk ~line 762) and the
    # interactive-menu path (~line 808). A regression here would either:
    #   - accept an unrelated string (e.g. "DESTROY SYSTEM" from a prior
    #     prompt), skipping the last-mile confirmation, or
    #   - reject a valid confirmation and force the operator to retype,
    #     eroding trust in the prompt.
    # Pure function, no I/O — trivially testable.

    It "Accepts exact 'ERASE'" {
        $r = & $script:DeployModule { Test-FinalWipeConfirmation -InputText 'ERASE' }
        $r | Should -BeTrue
    }

    It "Accepts exact 'DELETE ALL DATA'" {
        $r = & $script:DeployModule { Test-FinalWipeConfirmation -InputText 'DELETE ALL DATA' }
        $r | Should -BeTrue
    }

    It "Accepts lowercase 'erase' (ToUpperInvariant)" {
        $r = & $script:DeployModule { Test-FinalWipeConfirmation -InputText 'erase' }
        $r | Should -BeTrue
    }

    It "Accepts mixed-case 'Delete All Data'" {
        $r = & $script:DeployModule { Test-FinalWipeConfirmation -InputText 'Delete All Data' }
        $r | Should -BeTrue
    }

    It "Accepts padded ' ERASE ' (Trim)" {
        $r = & $script:DeployModule { Test-FinalWipeConfirmation -InputText '  ERASE  ' }
        $r | Should -BeTrue
    }

    It "Rejects empty string" {
        $r = & $script:DeployModule { Test-FinalWipeConfirmation -InputText '' }
        $r | Should -BeFalse
    }

    It "Rejects whitespace-only string" {
        $r = & $script:DeployModule { Test-FinalWipeConfirmation -InputText "   `t  " }
        $r | Should -BeFalse
    }

    It "Rejects `$null" {
        $r = & $script:DeployModule { Test-FinalWipeConfirmation -InputText $null }
        $r | Should -BeFalse
    }

    It "Rejects partial 'DELETE' (must be full 'DELETE ALL DATA')" {
        $r = & $script:DeployModule { Test-FinalWipeConfirmation -InputText 'DELETE' }
        $r | Should -BeFalse
    }

    It "Rejects extended 'ERASE ME'" {
        $r = & $script:DeployModule { Test-FinalWipeConfirmation -InputText 'ERASE ME' }
        $r | Should -BeFalse
    }

    It "Rejects 'DESTROY SYSTEM' (adjacent confirmation string must not cross-accept)" {
        # DESTROY SYSTEM is the *system disk* pre-confirmation typed one prompt
        # earlier (Select-TargetDisk lines 741 / 755 / 796). It must not
        # satisfy the ERASE prompt that follows — the two barriers are
        # deliberately separate.
        $r = & $script:DeployModule { Test-FinalWipeConfirmation -InputText 'DESTROY SYSTEM' }
        $r | Should -BeFalse
    }

    It "Rejects 'WIPE ALL' (additional-wipe confirmation must not cross-accept)" {
        # WIPE ALL confirms the extra-wipe set in Select-AdditionalWipeDisks
        # (line 1460). Also must not slip through here.
        $r = & $script:DeployModule { Test-FinalWipeConfirmation -InputText 'WIPE ALL' }
        $r | Should -BeFalse
    }

    It "Rejects 'WIPE DATA' (data-disk confirmation must not cross-accept)" {
        # WIPE DATA confirms the -DataDiskNumber format (line 1812). Same
        # cross-accept guard.
        $r = & $script:DeployModule { Test-FinalWipeConfirmation -InputText 'WIPE DATA' }
        $r | Should -BeFalse
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

Describe "Find-ImageFiles -WimFile path resolution" {

    # Regression guard: a relative -WimFile must be returned as an absolute
    # path. The downstream Start-Deployment call does
    # `Split-Path -Qualifier $selectedImage.Path` to derive the WIM source
    # drive that New-DiskpartScript must refuse to unmount. A relative path
    # makes Split-Path -Qualifier emit a runtime error and return $null,
    # silently disabling that source-drive protection - so a -WimFile +
    # -DataDiskNumber combo could unmount the USB mid-deploy and DISM apply
    # would fail. The fix lives in Find-ImageFiles, which must store
    # $item.FullName rather than the raw $WimFile parameter.

    BeforeEach {
        & $script:DeployModule {
            $WimFile  = $null
            $ImagePath = $null
        }
    }

    It "Returns an absolute Path even when -WimFile is given as a relative path" {
        $wimDir = Join-Path $TestDrive 'images'
        New-Item -ItemType Directory -Path $wimDir -Force | Out-Null
        $wimAbs = Join-Path $wimDir 'fixture.wim'
        Set-Content -LiteralPath $wimAbs -Value 'dummy' -NoNewline

        Push-Location $TestDrive
        try {
            # Forward slashes work on PSv5.1+ and on both Windows and POSIX
            $relPath = 'images/fixture.wim'
            $result  = @(& $script:DeployModule {
                param($wf)
                $WimFile = $wf
                Find-ImageFiles
            } $relPath)

            $result.Count | Should -Be 1
            [System.IO.Path]::IsPathRooted($result[0].Path) | Should -BeTrue
            $result[0].Path | Should -Be $wimAbs
            $result[0].Name | Should -Be 'fixture.wim'
        } finally {
            Pop-Location
        }
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

    It "Rejects -EnableBitLocker -BitLockerPin 21-char value above length ceiling" {
        # The 6-20 window is a single conditional (unified_winpe_deploy.ps1:1691-1695)
        # that OR's the lower and upper bounds. If a refactor collapses that to
        # just the lower bound, a 21+ char PIN would pass the gate and fail
        # silently at Windows first boot inside Enable-BitLocker (Enhanced PIN
        # policy caps at 20). This guards the ceiling explicitly.
        $result = & $script:DeployModule {
            $WimFile         = 'I:\images\Win.wim'
            $TargetDisk      =  0
            $Force           = $true
            $Silent          = $true
            $EnableBitLocker = $true
            $BitLockerPin    = 'a' * 21  # 21 chars, ceiling is 20
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match '6-20 characters' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart -Times 0
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

Describe "Start-Deployment -UnattendFile validation" {

    # The -UnattendFile gate lives at unified_winpe_deploy.ps1:1732-1747 and
    # short-circuits the deploy with $false BEFORE any disk work when the
    # file is missing or its XML is malformed. Windows Setup silently ignores
    # a bad unattend.xml at first boot and falls through to manual OOBE, so
    # discovering the failure post-wipe means re-deploying — this gate is
    # what saves the operator that round-trip. No coverage before this block.

    BeforeEach {
        $Global:CapturedLogs = New-Object System.Collections.ArrayList

        & $script:DeployModule {
            $WimFile          = 'I:\images\Win.wim'
            $ImagePath        = $null
            $TargetDisk       = 0
            $WipeDisks        = $null
            $UnattendFile     = $null
            $DataDiskNumber   = -1
            $EnableBitLocker  = $false
            $BitLockerPin     = $null
            $BitLockerKeyPath = $null
            $Force            = $true
            $Silent           = $true
            $ListOnly         = $false
            $Script:Config.DataDiskNumber  = -1
            $Script:Config.EnableBitLocker = $false
            $Script:Config.BitLockerPin    = $null
        }

        Mock -ModuleName DeployUnderTest -CommandName Test-Administrator     -MockWith { $true }
        Mock -ModuleName DeployUnderTest -CommandName Initialize-SystemPaths -MockWith { }
        Mock -ModuleName DeployUnderTest -CommandName Write-Log              -MockWith {
            param($Message, $Level)
            [void]$Global:CapturedLogs.Add(@{ Message = $Message; Level = $Level })
        }
        # If the unattend gate passes, the deploy proceeds to image discovery.
        # Stub image discovery so the run stops cleanly at "no image selected"
        # without touching disks or DISM. Downstream destructive mocks catch
        # any accidental reach-through.
        Mock -ModuleName DeployUnderTest -CommandName Find-ImageFiles       -MockWith { @() }
        Mock -ModuleName DeployUnderTest -CommandName Show-ImageSelection   -MockWith { $null }
        Mock -ModuleName DeployUnderTest -CommandName Invoke-Diskpart       -MockWith { $true }
        Mock -ModuleName DeployUnderTest -CommandName Apply-WindowsImage    -MockWith { $true }
        Mock -ModuleName DeployUnderTest -CommandName Set-BootConfiguration -MockWith { $true }
    }

    AfterEach {
        Remove-Variable -Scope Global -Name CapturedLogs, UnattendPath -ErrorAction SilentlyContinue
    }

    It "Rejects -UnattendFile pointing at a nonexistent path before any destructive op" {
        # Path under TestDrive but no file created there — Test-Path -PathType
        # Leaf returns $false and the gate exits with the "not found" message.
        $Global:UnattendPath = Join-Path $TestDrive 'does-not-exist.xml'
        $result = & $script:DeployModule {
            $UnattendFile = $Global:UnattendPath
            Start-Deployment
        }
        $result | Should -BeFalse
        ($Global:CapturedLogs | Where-Object { $_.Message -match 'UnattendFile not found' }) |
            Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart    -Times 0
        Should -Invoke -ModuleName DeployUnderTest -CommandName Apply-WindowsImage -Times 0
    }

    It "Rejects -UnattendFile that is not well-formed XML before any destructive op" {
        # Unclosed tags — the [xml] cast throws System.Xml.XmlException, the
        # catch block turns that into the operator-facing error path.
        $Global:UnattendPath = Join-Path $TestDrive 'bad.xml'
        Set-Content -Path $Global:UnattendPath -Value '<unattend><settings>' -Encoding UTF8
        $result = & $script:DeployModule {
            $UnattendFile = $Global:UnattendPath
            Start-Deployment
        }
        $result | Should -BeFalse
        ($Global:CapturedLogs | Where-Object { $_.Message -match 'not well-formed XML' }) |
            Should -Not -BeNullOrEmpty
        # Drift guard: the "why this matters" follow-up must still fire so a
        # future refactor doesn't silently drop the recovery hint that
        # explains the wipe-and-re-deploy loop this gate exists to prevent.
        ($Global:CapturedLogs | Where-Object { $_.Message -match 'Windows Setup silently ignores' }) |
            Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart    -Times 0
        Should -Invoke -ModuleName DeployUnderTest -CommandName Apply-WindowsImage -Times 0
    }

    It "Passes the well-formed-XML gate for a valid -UnattendFile" {
        $Global:UnattendPath = Join-Path $TestDrive 'good.xml'
        Set-Content -Path $Global:UnattendPath -Value @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem"/>
</unattend>
'@ -Encoding UTF8
        & $script:DeployModule {
            $UnattendFile = $Global:UnattendPath
            Start-Deployment | Out-Null
        }
        # The gate emits "Unattend file: <path>" only on the success branch;
        # if a refactor short-circuited the XML validation or inverted the
        # try/catch, either this log would be missing or the failure log
        # would be present instead.
        ($Global:CapturedLogs | Where-Object { $_.Message -match 'Unattend file: ' }) |
            Should -Not -BeNullOrEmpty
        ($Global:CapturedLogs | Where-Object { $_.Message -match 'not well-formed XML' }) |
            Should -BeNullOrEmpty
        ($Global:CapturedLogs | Where-Object { $_.Message -match 'UnattendFile not found' }) |
            Should -BeNullOrEmpty
    }

    It "Rejects -TargetDisk that hosts the WIM source drive" {
        # WIM source drive resolves to the same physical disk as the target.
        # Without this guard, diskpart 'clean' would wipe the WIM source before
        # DISM could read it - the target would end up partitioned but empty.
        Mock -ModuleName DeployUnderTest -CommandName Get-DiskNumberForDriveLetter -MockWith { 0 }
        $result = & $script:DeployModule {
            $WimFile    = 'I:\images\Win.wim'
            $TargetDisk =  0   # same physical disk as I:\ per the mock
            $Force      = $true
            $Silent     = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'hosts the WIM source drive' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName New-DiskpartScript -Times 0
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart    -Times 0
        Should -Invoke -ModuleName DeployUnderTest -CommandName Apply-WindowsImage -Times 0
    }

    It "Rejects -DataDiskNumber that hosts the WIM source drive" {
        Mock -ModuleName DeployUnderTest -CommandName Get-DiskNumberForDriveLetter -MockWith { 1 }
        $result = & $script:DeployModule {
            $WimFile        = 'I:\images\Win.wim'
            $TargetDisk     =  0
            $DataDiskNumber =  1   # same physical disk as I:\ per the mock
            $Force          = $true
            $Silent         = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match '-DataDiskNumber .* hosts the WIM source drive' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName New-DiskpartScript -Times 0
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart    -Times 0
    }

    It "Rejects -WipeDisks entry that hosts the WIM source drive" {
        Mock -ModuleName DeployUnderTest -CommandName Get-DiskNumberForDriveLetter -MockWith { 1 }
        # Select-AdditionalWipeDisks normally returns disks chosen via -WipeDisks;
        # mock it to return the disk that also hosts the WIM source.
        Mock -ModuleName DeployUnderTest -CommandName Select-AdditionalWipeDisks -MockWith {
            ,@([PSCustomObject]@{ Number=1; Size=500; Model='Data NVMe'; InterfaceType='SCSI'; HasPartitions=$true; PartitionInfo='Part1:500GB'; IsSystemDisk=$false })
        }
        $result = & $script:DeployModule {
            $WimFile    = 'I:\images\Win.wim'
            $TargetDisk =  0
            $WipeDisks  = '1'
            $Force      = $true
            $Silent     = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match '-WipeDisks contains disk .* hosts the WIM source drive' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName New-DiskpartScript -Times 0
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart    -Times 0
    }

    It "Proceeds when WIM source maps to a disk outside the wipe set (USB case)" {
        # The common case: WIM on a USB stick that Get-SystemDisks filtered out.
        # Get-DiskNumberForDriveLetter returns a number that's not the target,
        # not the data disk, and not in the extra-wipe set. Validation passes.
        Mock -ModuleName DeployUnderTest -CommandName Get-DiskNumberForDriveLetter -MockWith { 9 }
        $result = & $script:DeployModule {
            $WimFile    = 'I:\images\Win.wim'
            $TargetDisk =  0
            $Force      = $true
            $Silent     = $true
            Start-Deployment
        }
        $result | Should -BeTrue
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart -Times 1
    }

    It "Proceeds when WIM source drive doesn't resolve to any physical disk (X: RAM disk)" {
        # WinPE's X: backs onto a RAM disk that has no Win32_DiskDrive, so
        # Get-DiskNumberForDriveLetter returns $null. The guard must skip
        # cleanly and let the deploy continue.
        Mock -ModuleName DeployUnderTest -CommandName Get-DiskNumberForDriveLetter -MockWith { $null }
        $result = & $script:DeployModule {
            $WimFile    = 'I:\images\Win.wim'
            $TargetDisk =  0
            $Force      = $true
            $Silent     = $true
            Start-Deployment
        }
        $result | Should -BeTrue
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart -Times 1
    }
    # --- consolidated from PR #273 ---
    It "Rejects -EnableBitLocker -BitLockerPin with leading or trailing whitespace" {
        # Whitespace gate at unified_winpe_deploy.ps1 (just after the length
        # window check): a stray leading/trailing space bakes into the staged
        # bitlocker-setup.ps1 verbatim, so TPM+PIN unlocks with a PIN the
        # operator cannot type at the invisible BIOS PIN prompt.
        # Realistic mis-config: deploy.args edited in Notepad with trailing
        # whitespace after the quoted PIN, or a space typed at Read-Host.
        # Length passes (' goodpin42' is 10 chars, in 6-20 window) - only the
        # trim comparison catches it.
        $result = & $script:DeployModule {
            $WimFile         = 'I:\images\Win.wim'
            $TargetDisk      =  0
            $Force           = $true
            $Silent          = $true
            $EnableBitLocker = $true
            $BitLockerPin    = ' goodpin42'   # leading space
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'leading or trailing whitespace' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart    -Times 0
        Should -Invoke -ModuleName DeployUnderTest -CommandName Apply-WindowsImage -Times 0
    }

    It "Rejects -EnableBitLocker -BitLockerPin with trailing whitespace (invisible-space case)" {
        $result = & $script:DeployModule {
            $WimFile         = 'I:\images\Win.wim'
            $TargetDisk      =  0
            $Force           = $true
            $Silent          = $true
            $EnableBitLocker = $true
            $BitLockerPin    = 'goodpin42 '   # trailing space
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'leading or trailing whitespace' }) | Should -Not -BeNullOrEmpty
    }


    # --- consolidated from PR #139 ---
    It "Rejects -EnableBitLocker -BitLockerKeyPath with a relative path" {
        # The override is embedded literally into the staged first-boot script.
        # A relative value would resolve against the deployed OS's CWD and
        # silently land somewhere unintended - reject pre-flight.
        $result = & $script:DeployModule {
            $WimFile          = 'I:\images\Win.wim'
            $TargetDisk       =  0
            $Force            = $true
            $Silent           = $true
            $EnableBitLocker  = $true
            $BitLockerPin     = 'goodpin42'
            $BitLockerKeyPath = 'keys'    # relative - the gate
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'BitLockerKeyPath must be an absolute' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart -Times 0
    }

    It "Rejects -EnableBitLocker -BitLockerKeyPath with a drive-relative form (C:keys)" {
        # 'C:keys' is drive-relative on Windows - resolves against the CWD of
        # C: at first boot. Same silent-misplacement footgun as a fully
        # relative path.
        $result = & $script:DeployModule {
            $WimFile          = 'I:\images\Win.wim'
            $TargetDisk       =  0
            $Force            = $true
            $Silent           = $true
            $EnableBitLocker  = $true
            $BitLockerPin     = 'goodpin42'
            $BitLockerKeyPath = 'C:keys'
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'BitLockerKeyPath must be an absolute' }) | Should -Not -BeNullOrEmpty
    }

    It "Accepts -EnableBitLocker -BitLockerKeyPath with a UNC path" {
        $result = & $script:DeployModule {
            $WimFile          = 'I:\images\Win.wim'
            $TargetDisk       =  0
            $Force            = $true
            $Silent           = $true
            $EnableBitLocker  = $true
            $BitLockerPin     = 'goodpin42'
            $BitLockerKeyPath = '\\fileserver\BitLockerKeys'
            Start-Deployment
        }
        $result | Should -BeTrue
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'BitLockerKeyPath must be an absolute' }) | Should -BeNullOrEmpty
    }

    It "Accepts -EnableBitLocker -BitLockerKeyPath with a drive-qualified path" {
        $result = & $script:DeployModule {
            $WimFile          = 'I:\images\Win.wim'
            $TargetDisk       =  0
            $Force            = $true
            $Silent           = $true
            $EnableBitLocker  = $true
            $BitLockerPin     = 'goodpin42'
            $BitLockerKeyPath = 'C:\BitLockerKeys'
            Start-Deployment
        }
        $result | Should -BeTrue
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'BitLockerKeyPath must be an absolute' }) | Should -BeNullOrEmpty
    }


    # --- consolidated from PR #219 ---
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


    # --- consolidated from PR #165 ---

    # -----------------------------------------------------------------------
    # -WipeDisks regex validation (silent-mode gate). The pattern at
    # unified_winpe_deploy.ps1:1714 is the only thing standing between a
    # malformed -WipeDisks string and Select-AdditionalWipeDisks's
    # `[int]$_.Trim()` parse, which would throw a confusing
    # InvalidCastException mid-deploy. A regex regression here (e.g. a
    # refactor that loosens the character class) would let garbage slip
    # through to the parse and surface as a cryptic exception after the
    # operator has already typed -Force.
    # -----------------------------------------------------------------------

    It "Rejects malformed -WipeDisks 'abc' (non-digit) before any destructive op" {
        $result = & $script:DeployModule {
            $WimFile    = 'I:\images\Win.wim'
            $TargetDisk =  0
            $WipeDisks  = 'abc'
            $Force      = $true
            $Silent     = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'comma-separated disk numbers' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart    -Times 0
        Should -Invoke -ModuleName DeployUnderTest -CommandName Apply-WindowsImage -Times 0
    }

    It "Rejects mixed -WipeDisks '1,abc' (one bad token) before any destructive op" {
        $result = & $script:DeployModule {
            $WimFile    = 'I:\images\Win.wim'
            $TargetDisk =  0
            $WipeDisks  = '1,abc'
            $Force      = $true
            $Silent     = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'comma-separated disk numbers' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart -Times 0
    }

    It "Rejects -WipeDisks with trailing comma '1,'" {
        $result = & $script:DeployModule {
            $WimFile    = 'I:\images\Win.wim'
            $TargetDisk =  0
            $WipeDisks  = '1,'
            $Force      = $true
            $Silent     = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'comma-separated disk numbers' }) | Should -Not -BeNullOrEmpty
    }

    It "Accepts canonical -WipeDisks '1,2' and reaches diskpart" {
        $result = & $script:DeployModule {
            $WimFile    = 'I:\images\Win.wim'
            $TargetDisk =  0
            $WipeDisks  = '1,2'
            $Force      = $true
            $Silent     = $true
            Start-Deployment
        }
        $result | Should -BeTrue
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'comma-separated disk numbers' }) | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart -Times 1
    }

    It "Accepts spaced -WipeDisks '1 , 2' (the pattern tolerates inner whitespace)" {
        $result = & $script:DeployModule {
            $WimFile    = 'I:\images\Win.wim'
            $TargetDisk =  0
            $WipeDisks  = '1 , 2'
            $Force      = $true
            $Silent     = $true
            Start-Deployment
        }
        $result | Should -BeTrue
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'comma-separated disk numbers' }) | Should -BeNullOrEmpty
    }

    It "Accepts single-disk -WipeDisks '1'" {
        $result = & $script:DeployModule {
            $WimFile    = 'I:\images\Win.wim'
            $TargetDisk =  0
            $WipeDisks  = '1'
            $Force      = $true
            $Silent     = $true
            Start-Deployment
        }
        $result | Should -BeTrue
    }

    # --- consolidated from PR #271 ---
    It "Rejects overlap between -DataDiskNumber and the extra-wipe list (disk would be cleaned twice)" {
        # Overlap gate at unified_winpe_deploy.ps1 ~line 1826-1833: if
        # -DataDiskNumber matches a disk that Select-AdditionalWipeDisks
        # returns, the diskpart script would clean the same disk twice and
        # end with a bare 'clean' where the data-disk format was expected.
        # Realistic mis-config: silent USB with -DataDiskNumber 1 -WipeDisks '1'.
        Mock -ModuleName DeployUnderTest -CommandName Select-AdditionalWipeDisks -MockWith {
            ,@([PSCustomObject]@{ Number=1; Size=500; Model='Data NVMe'; InterfaceType='SCSI'; HasPartitions=$true; PartitionInfo='Part1:500GB'; IsSystemDisk=$false })
        }
        $result = & $script:DeployModule {
            $WimFile        = 'I:\images\Win.wim'
            $TargetDisk     =  0
            $DataDiskNumber =  1
            $WipeDisks      = '1'
            $Force          = $true
            $Silent         = $true
            Start-Deployment
        }
        $result | Should -BeFalse
        $logs = $Global:CapturedLogs
        ($logs | Where-Object { $_.Message -match 'both -DataDiskNumber and in the additional-wipe list' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName DeployUnderTest -CommandName Invoke-Diskpart    -Times 0
        Should -Invoke -ModuleName DeployUnderTest -CommandName Apply-WindowsImage -Times 0
    }
}
