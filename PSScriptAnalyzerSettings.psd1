@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # TUI output is intentional — users read the deployment progress
        # directly in the WinPE console. Write-Output would break the
        # color-coded safety prompts.
        'PSAvoidUsingWriteHost',

        # The safety chain is a typed-confirmation prompt, not a pipeline
        # ShouldProcess. Pipeline -WhatIf / -Confirm would not match the
        # "type ERASE / DESTROY SYSTEM" UX.
        'PSUseShouldProcessForStateChangingFunctions',

        # Function names like Apply-WindowsImage follow diskpart / DISM
        # vocabulary, not PowerShell approved verbs. Renaming would break
        # the mental mapping between the script and the Microsoft tools.
        'PSUseApprovedVerbs',

        # Get-WmiObject is used deliberately for WinPE / PowerShell 5.1
        # compatibility. Get-CimInstance is not reliable in all WinPE
        # builds. Documented in CLAUDE.md.
        'PSAvoidUsingWMICmdlet',

        # Plain-text passwords / convert-to-secure-string are not used.
        # This rule fires on build_boot_wim.ps1 string literals that
        # look like credentials but are registry path fragments.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
}
