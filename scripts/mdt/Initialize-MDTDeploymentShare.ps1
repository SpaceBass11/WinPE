#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Create an MDT deployment share ("kitchen") on the admin workstation.
.DESCRIPTION
    One-time setup. Creates the deployment share, imports WIM(s), and
    creates a task sequence per OS pre-configured for zero-touch UEFI
    deployment (EFI 300 MB + MSR 16 MB + Windows  -- same layout as the
    USB tool's diskpart script).

    After running this, build the operator payload with:
        scripts/mdt/New-MDTMedia.ps1

    Add more WIMs later with:
        scripts/mdt/Import-WimImages.ps1
.PARAMETER SharePath
    Local path for the deployment share. Default: C:\MDTDeploymentShare
.PARAMETER WimPaths
    One or more .wim / .esd files to import. Each becomes an OS + task sequence.
.PARAMETER OrgName
    Organization name embedded in task sequences. Default: My Organization
.PARAMETER TimeZone
    Windows time-zone name. Run `tzutil /l` to list valid names.
    Default: Central Standard Time
.EXAMPLE
    .\Initialize-MDTDeploymentShare.ps1 `
        -WimPaths 'C:\images\Win11_Pro_24H2.wim' `
        -OrgName  'Contoso IT'
#>

[CmdletBinding()]
param(
    [string]   $SharePath       = 'C:\MDTDeploymentShare',
    [string[]] $WimPaths        = @(),
    [string]   $OrgName         = 'My Organization',
    [string]   $TimeZone        = 'Coordinated Universal Time',
    [string]   $BDEPin          = '',
    [string]   $FinishAction    = 'REBOOT',
    [string]   $OSDComputerName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helpers

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Assert-MDTInstalled {
    $module = 'C:\Program Files\Microsoft Deployment Toolkit\bin\MicrosoftDeploymentToolkit.psd1'
    if (-not (Test-Path $module)) {
        throw "MDT not installed. Download MDT 8456 from https://www.microsoft.com/en-us/download/details.aspx?id=54259"
    }
    return $module
}

function Get-WimEditionName {
    param([string]$WimPath)
    # /English flag for locale-safe parsing
    $info = & dism.exe /Get-WimInfo /WimFile:"$WimPath" /Index:1 /English 2>&1
    $line = $info | Where-Object { $_ -match '^Name\s*:' } | Select-Object -First 1
    if ($line) { return ($line -replace '^Name\s*:\s*', '').Trim() }
    return [IO.Path]::GetFileNameWithoutExtension($WimPath)
}

function ConvertTo-SafeName {
    param([string]$Name)
    return ($Name -replace '[^\w\-]', '_').Trim('_')
}

function Invoke-MDTWin11AdkFixes {
    <#
        Applies three compatibility fixes required when using MDT 8456 with
        Windows 11 ADK (22H2 / 24H2 / 26H1).  All three are idempotent  -- safe
        to call on an already-patched machine.

        Fix 1  -- x86 WinPE_OCs placeholder folder
            ADK for Windows 11 no longer ships 32-bit WinPE.  MDT probes for
            the x86\WinPE_OCs directory and throws
            System.IO.DirectoryNotFoundException if it is absent.  Creating
            the empty folder is sufficient  -- MDT never reads its contents.

        Fix 2  -- DeploymentTools.xml WSIM path (best-effort)
            MDT's Bin\DeploymentTools.xml hard-codes the WSIM (imgmgr.exe)
            path without an architecture sub-folder.  Modern ADK ships only
            an amd64 build of imgmgr.exe under WSIM\amd64.  Patching the
            single <tool name="imgmgr.exe"> line to append \amd64 lets MDT
            open unattend files and generate .clg catalogs.

        Fix 3  -- Disable x86 boot image generation
            Written into Control\Settings.xml after the share is created.
            Prevents Update-MDTDeploymentShare from attempting to build a
            32-bit LiteTouch boot image (which would fail on modern ADK).
            Call this overload with -SettingsXmlPath after the PSDrive is
            mounted.
    #>
    param(
        # When provided, writes SupportX86=False into Settings.xml.
        # Omit on first call (before the share exists); supply on second call.
        [string]$SettingsXmlPath = ''
    )

    # --- Fix 1: x86 WinPE_OCs placeholder ---
    $adkWinPERoot = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment'
    $x86OCs = Join-Path $adkWinPERoot 'x86\WinPE_OCs'
    if (-not (Test-Path $x86OCs)) {
        try {
            New-Item -Path $x86OCs -ItemType Directory -Force | Out-Null
            Write-Host '  Applied: x86\WinPE_OCs placeholder folder created'
        } catch {
            Write-Warning "  ADK x86 WinPE_OCs fix skipped  -- could not create folder: $_"
        }
    }

    # --- Fix 2: DeploymentTools.xml WSIM path ---
    $dtXml = 'C:\Program Files\Microsoft Deployment Toolkit\Bin\DeploymentTools.xml'
    if (Test-Path $dtXml) {
        try {
            $raw = Get-Content $dtXml -Raw
            # Match the imgmgr.exe tool line that ends with \WSIM but NOT already \WSIM\amd64
            # Pattern: <tool name="imgmgr.exe">...WSIM</tool>  (no trailing \amd64)
            if ($raw -match '(?i)<tool\s+name="imgmgr\.exe">[^<]*\\WSIM\s*</tool>' -and
                $raw -notmatch '(?i)<tool\s+name="imgmgr\.exe">[^<]*\\WSIM\\amd64\s*</tool>') {
                $patched = $raw -replace '(?i)(<tool\s+name="imgmgr\.exe">(?:[^<]*)\\WSIM)\s*(</tool>)', '$1\amd64$2'
                Set-Content -Path $dtXml -Value $patched -Encoding UTF8 -NoNewline
                Write-Host '  Applied: DeploymentTools.xml imgmgr.exe path patched to WSIM\amd64'
            }
        } catch {
            Write-Warning "  DeploymentTools.xml WSIM fix skipped  -- patch failed: $_"
        }
    }

    # --- Fix 3: Disable x86 boot image + configure WinPE boot image settings ---
    if ($SettingsXmlPath -ne '' -and (Test-Path $SettingsXmlPath)) {
        try {
            [xml]$xml = Get-Content $SettingsXmlPath -Raw

            # Helper: set or create a child element on the Settings root.
            # Uses local-name() XPath so dots in element names are unambiguous.
            $setNode = {
                param([string]$Name, [string]$Value)
                $node = $xml.SelectSingleNode("/Settings/*[local-name()='$Name']")
                if (-not $node) {
                    $node = $xml.CreateElement($Name)
                    [void]$xml.DocumentElement.AppendChild($node)
                }
                if ($node.InnerText -ne $Value) { $node.InnerText = $Value }
            }

            # Disable x86 boot image generation (Win11 ADK has no 32-bit WinPE)
            & $setNode 'SupportX86' 'False'

            # Scratch space: max out at 512 MB -- USB media is large, system RAM is not a concern
            & $setNode 'Boot.x64.ScratchSpace' '512'

            # WinPE optional components required for MDT LiteTouch:
            #   winpe-scripting  -- LiteTouch.wsf and all MDT VBScript helpers
            #   winpe-wmi        -- hardware detection queries during WinPE phase
            #   winpe-hta        -- progress/wizard dialogs
            & $setNode 'Boot.x64.FeaturePacks' 'winpe-scripting,winpe-wmi,winpe-hta'

            # Include all imported drivers and packages in the boot image.
            # No-op if nothing is imported yet; automatically picks up new drivers on rebuild.
            & $setNode 'Boot.x64.IncludeAllDrivers'  'True'
            & $setNode 'Boot.x64.IncludeAllPackages' 'True'

            $xml.Save($SettingsXmlPath)
            Write-Host '  Applied: WinPE boot image configured (512 MB scratch, scripting+WMI+HTA, all drivers/packages, x86 disabled)'
        } catch {
            Write-Warning "  Settings.xml update skipped: $_"
        }
    }
}

function Add-BitLockerTsStep {
    <#
        Appends an "Enable BitLocker" Run Command Line step to the State Restore
        group in ts.xml. The step calls Enable-BitLocker.ps1 with the BDEPin
        MDT variable and is conditional  -- it is a no-op when BDEPin is empty.

        Note: Opening and saving the task sequence in MDT Workbench regenerates
        ts.xml and overwrites this step. Re-run Initialize-MDTDeploymentShare.ps1
        or add the step manually in Workbench afterward.
    #>
    param([string]$TsXmlPath)
    if (-not (Test-Path $TsXmlPath)) { return }

    [xml]$xml = Get-Content $TsXmlPath -Raw

    # Idempotent  -- don't add the step twice
    if ($xml.SelectSingleNode("//*[@name='Enable BitLocker']")) { return }

    # Target the State Restore group; fall back to the root sequence element
    $parent = $xml.SelectSingleNode("//group[@name='State Restore']")
    if (-not $parent) { $parent = $xml.SelectSingleNode('//sequence') }
    if (-not $parent) { $parent = $xml.DocumentElement }

    $stepDoc = New-Object System.Xml.XmlDocument
    $stepDoc.LoadXml('<step
      type="SMS_TaskSequence_RunCommandLineAction"
      name="Enable BitLocker"
      description="Encrypt C: with TPM+PIN and data drives. Skipped when BDEPin is empty."
      disable="false"
      continueOnError="false"
      successCodeList="0 3010">
  <action>powershell.exe -ExecutionPolicy Bypass -NonInteractive -File "%SCRIPTROOT%\Enable-BitLocker.ps1" -Pin "%BDEPin%"</action>
  <defaultVarList>
    <variable name="RunAsUser" property="RunAsUser">false</variable>
    <variable name="WorkingDirectory" property="WorkingDirectory">%SCRIPTROOT%</variable>
    <variable name="Timeout" property="Timeout">0</variable>
  </defaultVarList>
  <condition>
    <expression type="SMS_TaskSequence_VariableConditionExpression">
      <variable name="Variable">BDEPin</variable>
      <variable name="Operator">notEquals</variable>
      <variable name="Value"></variable>
    </expression>
  </condition>
</step>')

    [void]$parent.AppendChild($xml.ImportNode($stepDoc.DocumentElement, $true))
    $xml.Save($TsXmlPath)
}

function Add-StigAccountsTsSteps {
    <#
        Appends three STIG account-hardening steps to the State Restore group
        in ts.xml. Steps run in order after BitLocker so all accounts are
        available for the full task sequence, then locked down at the end:

          1. Rename built-in Administrator -> X_Admin  (DoD STIG WN11-SO-000030)
          2. Rename built-in Guest        -> Visitor   (DoD STIG WN11-SO-000040)
          3. Disable X_Admin                          (DoD STIG WN11-SO-000025)
             Must use the renamed account name  -- rename runs first.

        Note: Opening and saving the task sequence in MDT Workbench regenerates
        ts.xml and overwrites these steps. Re-run Initialize-MDTDeploymentShare.ps1
        or add the steps manually in Workbench afterward.
    #>
    param([string]$TsXmlPath)
    if (-not (Test-Path $TsXmlPath)) { return }

    [xml]$xml = Get-Content $TsXmlPath -Raw

    # Idempotent  -- skip if already injected
    if ($xml.SelectSingleNode("//*[@name='STIG: Rename Built-in Administrator']")) { return }

    $parent = $xml.SelectSingleNode("//group[@name='State Restore']")
    if (-not $parent) { $parent = $xml.SelectSingleNode('//sequence') }
    if (-not $parent) { $parent = $xml.DocumentElement }

    $steps = @(
        @{
            name        = 'STIG: Rename Built-in Administrator'
            description = 'DoD STIG WN11-SO-000030: rename built-in Administrator to X_Admin.'
            action      = 'powershell.exe -NonInteractive -Command "Rename-LocalUser -Name Administrator -NewName X_Admin"'
        },
        @{
            name        = 'STIG: Rename Built-in Guest'
            description = 'DoD STIG WN11-SO-000040: rename built-in Guest to Visitor.'
            action      = 'powershell.exe -NonInteractive -Command "Rename-LocalUser -Name Guest -NewName Visitor"'
        },
        @{
            name        = 'STIG: Disable X_Admin'
            description = 'DoD STIG WN11-SO-000025: disable the renamed built-in Administrator account.'
            action      = 'net user X_Admin /active:no'
        }
    )

    foreach ($s in $steps) {
        $stepDoc = New-Object System.Xml.XmlDocument
        $stepDoc.LoadXml(('<step
          type="SMS_TaskSequence_RunCommandLineAction"
          name="{0}"
          description="{1}"
          disable="false"
          continueOnError="false"
          successCodeList="0">
      <action>{2}</action>
      <defaultVarList>
        <variable name="RunAsUser" property="RunAsUser">false</variable>
        <variable name="WorkingDirectory" property="WorkingDirectory">%SystemRoot%\System32</variable>
        <variable name="Timeout" property="Timeout">0</variable>
      </defaultVarList>
    </step>' -f $s.name, $s.description, $s.action))
        [void]$parent.AppendChild($xml.ImportNode($stepDoc.DocumentElement, $true))
    }

    $xml.Save($TsXmlPath)
}

function Set-UEFIPartitionScheme {
    <#
        Patches the Format and Partition Disk step in a task sequence XML to
        GPT standard layout:
            EFI  300 MB  FAT32  S:
            MSR   16 MB  (no letter)
            Windows  remainder  NTFS  C:

        MDT ts.xml stores partition config as individual indexed scalar variables
        (OSDPartitions0Type, OSDPartitions1Size, etc.)  -- not as a blob array.
        Do NOT edit the task sequence in MDT Workbench after running this script;
        Workbench regenerates ts.xml from its internal representation and will
        overwrite these variables. Re-run this script after any Workbench edits.
    #>
    param([string]$TsXmlPath)
    if (-not (Test-Path $TsXmlPath)) { return }

    [xml]$xml = Get-Content $TsXmlPath -Raw
    $step = $xml.SelectSingleNode("//step[@type='BDD_FormatDisk']")
    if (-not $step) { return }

    $varList = $step.SelectSingleNode('defaultVarList')
    if (-not $varList) {
        $varList = $xml.CreateElement('defaultVarList')
        [void]$step.AppendChild($varList)
    }

    # Helper: set or create a <variable name="..."> node in $varList
    $setVar = {
        param([string]$VarName, [string]$VarValue)
        $node = $varList.SelectSingleNode("variable[@name='$VarName']")
        if (-not $node) {
            $node = $xml.CreateElement('variable')
            $node.SetAttribute('name', $VarName)
            $node.SetAttribute('property', $VarName)
            [void]$varList.AppendChild($node)
        }
        $node.InnerText = $VarValue
    }

    & $setVar 'OSDPartitionStyle'  'GPT'
    & $setVar 'OSDPartitionsCount' '3'

    # Partition 0  -- EFI (300 MB, FAT32, S:)
    & $setVar 'OSDPartitions0Type'        'EFI'
    & $setVar 'OSDPartitions0Bootable'    'TRUE'
    & $setVar 'OSDPartitions0DriveLetter' 'S:'
    & $setVar 'OSDPartitions0FileSystem'  'FAT32'
    & $setVar 'OSDPartitions0QuickFormat' 'TRUE'
    & $setVar 'OSDPartitions0Size'        '300'
    & $setVar 'OSDPartitions0SizeUnits'   'MB'
    & $setVar 'OSDPartitions0VolumeName'  'EFI'

    # Partition 1  -- MSR (16 MB, no drive letter)
    & $setVar 'OSDPartitions1Type'      'MSR'
    & $setVar 'OSDPartitions1Size'      '16'
    & $setVar 'OSDPartitions1SizeUnits' 'MB'

    # Partition 2  -- Windows (remainder, NTFS, C:)
    & $setVar 'OSDPartitions2Type'        'Primary'
    & $setVar 'OSDPartitions2Bootable'    'TRUE'
    & $setVar 'OSDPartitions2DriveLetter' 'C:'
    & $setVar 'OSDPartitions2FileSystem'  'NTFS'
    & $setVar 'OSDPartitions2QuickFormat' 'TRUE'
    & $setVar 'OSDPartitions2Size'        '100'
    & $setVar 'OSDPartitions2SizeUnits'   '%'
    & $setVar 'OSDPartitions2VolumeName'  'Windows'

    $xml.Save($TsXmlPath)
}

#endregion

#region Validate

Write-Step 'Checking prerequisites'

$mdtModule = Assert-MDTInstalled

# Normalize: PS collapses empty array returns to $null; @() is always safe under StrictMode
if ($null -eq $WimPaths) { $WimPaths = @() }

foreach ($w in $WimPaths) {
    if (-not (Test-Path $w)) { throw "WIM not found: $w" }
}

Import-Module $mdtModule -Verbose:$false

Write-Step 'Applying MDT + Windows 11 ADK compatibility fixes'
Invoke-MDTWin11AdkFixes

#endregion

#region Create share

Write-Step "Creating deployment share: $SharePath"

if (-not (Test-Path $SharePath)) {
    New-Item -Path $SharePath -ItemType Directory -Force | Out-Null
}

# SMB share is used by MDT Workbench on the same machine  -- not exposed to operators
$shareName = 'MDTDeploymentShare$'
if (-not (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name $shareName -Path $SharePath -FullAccess 'Administrators' | Out-Null
    Write-Host "  Share created: $shareName"
}

#endregion

#region Mount PSDrive

$drive = 'DS001'
if (Get-PSDrive -Name $drive -ErrorAction SilentlyContinue) {
    Remove-PSDrive -Name $drive -Force
}
New-PSDrive -Name $drive -PSProvider MDTProvider -Root $SharePath `
    -NetworkPath "\\$env:COMPUTERNAME\$shareName" `
    -Verbose:$false | Add-MDTPersistentDrive | Out-Null

Write-Host "  DS001: mounted -> $SharePath"

# Fix 3 requires the share to exist  -- apply SupportX86=False now
$settingsXml = Join-Path $SharePath 'Control\Settings.xml'
Invoke-MDTWin11AdkFixes -SettingsXmlPath $settingsXml

#endregion

#region Import WIMs

$imported = @()

if ($WimPaths.Count -gt 0) {
    Write-Step "Importing $($WimPaths.Count) WIM(s)"
}

foreach ($wimPath in $WimPaths) {
    $edition    = Get-WimEditionName -WimPath $wimPath
    $folderName = ConvertTo-SafeName -Name $edition

    Write-Host "  $edition  ->  Operating Systems\$folderName"

    # -SourceFile is undocumented on Import-MDTOperatingSystem but empirically
    # works on MDT 8456 to import a single .wim without pulling the whole folder.
    Import-MDTOperatingSystem -Path "${drive}:\Operating Systems" `
        -SourceFile $wimPath `
        -DestinationFolder $folderName `
        -Verbose:$false | Out-Null

    $imported += [PSCustomObject]@{ Edition = $edition; Folder = $folderName }
}

#endregion

#region Create task sequences for newly imported WIMs

if ($imported.Count -gt 0) {
    Write-Step 'Creating task sequences'

    foreach ($os in $imported) {
        $tsID   = 'DEPLOY-' + ($os.Folder.ToUpper() -replace '[_]{1,}', '-')
        $tsName = "Deploy $($os.Edition)"

        # Find the imported OS object -- leaf items are OS entries, containers are folders
        $mdtOS = Get-ChildItem "${drive}:\Operating Systems\$($os.Folder)" `
            -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            Select-Object -First 1

        # Fallback: search the full OS tree in case DestinationFolder was adjusted by MDT
        if (-not $mdtOS) {
            $mdtOS = Get-ChildItem "${drive}:\Operating Systems" -Recurse `
                -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and $_.PSPath -like "*$($os.Folder)*" } |
                Select-Object -First 1
        }

        if (-not $mdtOS) {
            Write-Warning "  OS object not found for $($os.Folder)  -- skipping TS"
            continue
        }

        # -Template takes the filename only; MDT resolves it from its own Templates directory.
        # Passing a full path causes MDT to silently fall back to a bare <tss /> stub.
        Import-MDTTaskSequence -Path "${drive}:\Task Sequences" `
            -ID $tsID -Name $tsName -Template 'Client.xml' `
            -Comments '' `
            -OperatingSystemPath $mdtOS.PSPath `
            -FullName 'Windows User' -OrgName $OrgName `
            -HomePage 'about:blank' `
            -Verbose:$false | Out-Null

        Write-Host "  Created: [$tsID] $tsName"
    }
}

#endregion

#region Patch all task sequences (UEFI + BitLocker + STIG)

# Runs for every DEPLOY-* control folder whether WIMs were imported or not.
# Repairs stub ts.xml files left by earlier runs with the wrong template parameter.

Write-Step 'Patching task sequences (UEFI / BitLocker / STIG)'

$mdtTemplatePath = 'C:\Program Files\Microsoft Deployment Toolkit\Templates\Client.xml'
$tsDirs = @(Get-ChildItem (Join-Path $SharePath 'Control') -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^DEPLOY-' })

if ($tsDirs.Count -eq 0) {
    Write-Warning '  No task sequences found. Run step 3 with a WIM path to create one.'
} else {
    foreach ($tsDir in $tsDirs) {
        $tsXml = Join-Path $tsDir.FullName 'ts.xml'
        if (-not (Test-Path $tsXml)) {
            Write-Warning "  ts.xml missing for $($tsDir.Name)  -- skipping"
            continue
        }

        # A stub ts.xml has no <group> or <step> elements.
        # Replace it with the Client.xml template so there are steps to patch.
        $tsContent = Get-Content $tsXml -Raw -ErrorAction SilentlyContinue
        if ($tsContent -notmatch '<group|<step') {
            if (Test-Path $mdtTemplatePath) {
                Copy-Item $mdtTemplatePath $tsXml -Force
                Write-Host "  Repaired stub ts.xml: $($tsDir.Name)"
            } else {
                Write-Warning "  Stub ts.xml and Client.xml template not found  -- skipping $($tsDir.Name)"
                continue
            }
        }

        Set-UEFIPartitionScheme -TsXmlPath $tsXml
        Add-BitLockerTsStep     -TsXmlPath $tsXml
        Add-StigAccountsTsSteps -TsXmlPath $tsXml
        Write-Host "  Patched: $($tsDir.Name)  (UEFI + BitLocker + STIG)"
    }
}

#endregion

#region Write zero-touch CustomSettings.ini

Write-Step 'Writing zero-touch CustomSettings.ini'

# Use the first newly imported TS, or fall back to first existing DEPLOY-* dir
if ($imported.Count -gt 0) {
    $firstTsID = 'DEPLOY-' + ($imported[0].Folder.ToUpper() -replace '[_]{1,}', '-')
} else {
    $existingTs = Get-ChildItem (Join-Path $SharePath 'Control') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^DEPLOY-' } | Select-Object -First 1
    $firstTsID = if ($existingTs) { $existingTs.Name } else { 'DEPLOY-WIN11-PRO' }
}

# All wizard pages suppressed  -- operator sees only the progress bar.
# See configs/mdt/CustomSettings.ini for the annotated version.
$cs = @"
[Settings]
Priority=Default
Properties=

[Default]
OSInstall=Y
_SMSTSORGNAME=$OrgName

; Task sequence to run automatically (no selection prompt)
TaskSequenceID=$firstTsID

; Suppress every wizard page
SkipBDDWelcome=YES
SkipTaskSequence=YES
SkipComputerName=YES
SkipUserData=YES
SkipLocaleSelection=YES
SkipTimeZone=YES
SkipApplications=YES
SkipPackageDisplay=YES
SkipRoles=YES
SkipBitLocker=YES
SkipSummary=YES
SkipFinalSummary=YES

; Target disk 0 (first physical disk)
OSDDiskIndex=0

; Locale
KeyboardLocale=en-US
UserLocale=en-US
SystemLocale=en-US
TimeZoneName=$TimeZone

; Computer name. Blank = Windows random. %SerialNumber% = service tag.
OSDComputerName=$OSDComputerName

; BitLocker startup PIN (alphanumeric enhanced PIN  -- letters + numbers allowed)
; Same value used for C: startup PIN and data drive password.
; Leave blank to skip BitLocker  -- useful for VMs or non-TPM hardware.
BDEPin=$BDEPin

; Action after deployment completes: REBOOT or SHUTDOWN
FinishAction=$FinishAction
"@

Set-Content -Path (Join-Path $SharePath 'Control\CustomSettings.ini') -Value $cs -Encoding ASCII
Write-Host "  Control\CustomSettings.ini written (zero-touch defaults)"

#endregion

#region Write Bootstrap.ini for standalone media

Write-Step 'Writing Bootstrap.ini'

# DeployRoot=. is the key line: tells LiteTouch WinPE to look on the
# same media it booted from. No network, no server, no credentials.
$bs = @"
[Settings]
Priority=Default

[Default]
; Look on the booted media  -- no network needed
DeployRoot=.
SkipBDDWelcome=YES
KeyboardLocale=en-US
"@

Set-Content -Path (Join-Path $SharePath 'Control\Bootstrap.ini') -Value $bs -Encoding ASCII
Write-Host "  Control\Bootstrap.ini written (standalone media)"

#endregion

#region Copy MDT runtime scripts into deployment share Scripts folder

# Enable-BitLocker.ps1 must live in the share's Scripts\ folder so that the
# task sequence step can reference it via %SCRIPTROOT%.
$scriptsDir = Join-Path $SharePath 'Scripts'
if (-not (Test-Path $scriptsDir)) {
    New-Item -Path $scriptsDir -ItemType Directory -Force | Out-Null
}

$runtimeScripts = @('Enable-BitLocker.ps1')
foreach ($rs in $runtimeScripts) {
    $src = Join-Path $PSScriptRoot $rs
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $scriptsDir -Force
        Write-Host "  Scripts\$rs copied to deployment share"
    } else {
        Write-Warning "  $rs not found at $src  -- task sequence step will fail at runtime"
    }
}

#endregion

#region Update deployment share (only when new WIMs were imported)

if ($imported.Count -gt 0) {
    Write-Step 'Updating deployment share (generating LiteTouchPE_x64.wim  -- a few minutes)'
    Update-MDTDeploymentShare -Path "${drive}:" -Force -Verbose:$false

    $bootWim = Join-Path $SharePath 'Boot\LiteTouchPE_x64.wim'
    if (Test-Path $bootWim) {
        $mb = [math]::Round((Get-Item $bootWim).Length / 1MB, 1)
        Write-Host "  Boot WIM ready: Boot\LiteTouchPE_x64.wim ($mb MB)"
    }
} else {
    Write-Host ''
    Write-Host '  Boot WIM not regenerated (no new WIMs imported -- skipping Update-MDTDeploymentShare).' -ForegroundColor DarkGray
}

#endregion

#region Summary

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Green
Write-Host ' Deployment share ready' -ForegroundColor Green
Write-Host '=====================================================' -ForegroundColor Green
Write-Host "  Path : $SharePath"
Write-Host ''
Write-Host '  Task sequences:'
$tsDirsAll = @(Get-ChildItem (Join-Path $SharePath 'Control') -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^DEPLOY-' })
foreach ($d in $tsDirsAll) { Write-Host "    [$($d.Name)]" }
Write-Host ''
Write-Host '  Next: run step 5 (Start-MDT.ps1) to build the operator ISO.'
Write-Host '=====================================================' -ForegroundColor Green

#endregion
