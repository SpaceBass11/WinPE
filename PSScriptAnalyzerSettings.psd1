# PSScriptAnalyzer settings for the Clonezilla first-boot scripts.
#
# The ps-analyze CI job points -Settings here. It keeps the PS 5.1
# compatibility check (PSUseCompatibleSyntax) and fails the build on
# Error-severity findings, but excludes a small set of rules that flag
# patterns this workflow uses *by design*. Each exclusion is the
# documented, accepted-risk trust model spelled out in README.md /
# CLAUDE.md -- not an oversight. Do NOT extend these exclusions to new
# code paths; if a script trips one of these rules for a *different*
# reason, fix the script instead of widening the exclusion.

@{
    Rules = @{
        # The whole point of the Windows job: catch syntax that wouldn't
        # parse on the Windows PowerShell 5.1 that runs SetupComplete.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
    }

    ExcludeRules = @(
        # The BitLocker PIN, the accounts.csv passwords, and the rotated
        # built-in-Administrator password are all handled as plaintext on
        # purpose -- the staged Config\ files are plaintext by design and
        # wiped by Finalize-Cleanup. ConvertTo-SecureString -AsPlainText is
        # the only way to hand those values to Enable-BitLocker /
        # New-LocalUser / Set-LocalUser. The accepted-risk model is
        # documented in README.md ("BitLocker PIN trust model" and "Account
        # password trust model").
        'PSAvoidUsingConvertToSecureStringWithPlainText',

        # Test-AccountRow in Common.ps1 is a pure validator for one
        # accounts.csv row (Username,Password,Role). It does not accept or
        # transmit a live credential, so a PSCredential parameter would be
        # the wrong shape. The plaintext-credential trust model is the same
        # accepted risk documented above.
        'PSAvoidUsingUsernameAndPasswordParams'
    )
}
