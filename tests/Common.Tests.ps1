# Pester tests for the pure helper functions in scripts/Common.ps1.
# These functions are cross-platform (no Windows-only cmdlets), so they can
# be unit-tested on any runner. Run with: Invoke-Pester -Path tests
#
# Pester 5 syntax.

BeforeAll {
    . (Join-Path $PSScriptRoot '..' | Join-Path -ChildPath 'scripts' | Join-Path -ChildPath 'Common.ps1')
}

Describe 'New-RandomName' {
    It 'returns a string of the requested length' {
        (New-RandomName -Length 12).Length | Should -Be 12
    }
    It 'contains only letters and digits' {
        New-RandomName -Length 64 | Should -Match '^[A-Za-z0-9]+$'
    }
    It 'is non-deterministic across calls' {
        (New-RandomName -Length 24) | Should -Not -Be (New-RandomName -Length 24)
    }
}

Describe 'New-RandomPassword' {
    It 'returns a string of the requested length' {
        (New-RandomPassword -Length 32).Length | Should -Be 32
    }
    It 'honors a different length' {
        (New-RandomPassword -Length 20).Length | Should -Be 20
    }
}

Describe 'New-RecoveryKeyFileName' {
    It 'builds the expected per-host filename' {
        New-RecoveryKeyFileName -ComputerName 'PC1' -Stamp '2026-01-02_030405' |
            Should -Be 'BitLocker-RecoveryKey-PC1-2026-01-02_030405.txt'
    }
}

Describe 'Test-AccountRow' {
    It 'accepts a valid Standard row' {
        Test-AccountRow -Username 'Level 0' -Password 'p@ssw0rd' -Role 'Standard' | Should -BeTrue
    }
    It 'accepts a valid Admin row' {
        Test-AccountRow -Username 'IT_Admin' -Password 'p@ssw0rd' -Role 'Admin' | Should -BeTrue
    }
    It 'throws on an empty username' {
        { Test-AccountRow -Username '' -Password 'p@ssw0rd' -Role 'Standard' } | Should -Throw
    }
    It 'throws on an empty password' {
        { Test-AccountRow -Username 'Level 0' -Password '' -Role 'Standard' } | Should -Throw
    }
    It 'throws on an invalid role' {
        { Test-AccountRow -Username 'Level 0' -Password 'p@ssw0rd' -Role 'Wheel' } | Should -Throw
    }
}
