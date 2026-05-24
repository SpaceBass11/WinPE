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

        # Excluded because the project intentionally stages an operator-
        # supplied BitLocker PIN via ConvertTo-SecureString -AsPlainText
        # in Initialize-BitLockerSetup (unified_winpe_deploy.ps1). This
        # is the air-gapped operator USB trust model documented in
        # docs/BITLOCKER.md, with the PIN guarded only by Windows' 6-20
        # character window at deploy time (PIN content policy is the
        # admin's call). Do NOT extend plaintext-secret usage to any
        # other code path.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
}
