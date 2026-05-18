#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Create an MDT deployment share ("kitchen") on the admin workstation.
.DESCRIPTION
    One-time setup. Creates the deployment share, imports WIM(s), and
    creates a task sequence per OS pre-configured for zero-touch UEFI
    deployment (EFI 300 MB + MSR 16 MB + Windows — same layout as the
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
    [string]   $SharePath = 'C:\MDTDeploymentShare',
    [string[]] $WimPaths  = @(),
    [string]   $OrgName   = 'My Organization',
    [string]   $TimeZone  = 'Central Standard Time'
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
    # /English flag for locale-safe parsing (same approach as unified_winpe_deploy.ps1)
    $info = & dism.exe /Get-WimInfo /WimFile:"$WimPath" /Index:1 /English 2>&1
    $line = $info | Where-Object { $_ -match '^Name\s*:' } | Select-Object -First 1
    if ($line) { return ($line -replace '^Name\s*:\s*', '').Trim() }
    return [IO.Path]::GetFileNameWithoutExtension($WimPath)
}

function ConvertTo-SafeName {
    param([string]$Name)
    return ($Name -replace '[^\w\-]', '_').Trim('_')
}

function Set-UEFIPartitionScheme {
    <#
        Patches the Format and Partition Disk step in a task sequence XML to
        GPT with the same layout as unified_winpe_deploy.ps1:
            EFI  300 MB  FAT32  S:
            MSR   16 MB  (no letter)
            Windows  remainder  NTFS  C:

        MDT ts.xml stores partition config as individual indexed scalar variables
        (OSDPartitions0Type, OSDPartitions1Size, etc.) — not as a blob array.
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

    # Partition 0 — EFI (300 MB, FAT32, S:)
    & $setVar 'OSDPartitions0Type'        'EFI'
    & $setVar 'OSDPartitions0Bootable'    'TRUE'
    & $setVar 'OSDPartitions0DriveLetter' 'S:'
    & $setVar 'OSDPartitions0FileSystem'  'FAT32'
    & $setVar 'OSDPartitions0QuickFormat' 'TRUE'
    & $setVar 'OSDPartitions0Size'        '300'
    & $setVar 'OSDPartitions0SizeUnits'   'MB'
    & $setVar 'OSDPartitions0VolumeName'  'EFI'

    # Partition 1 — MSR (16 MB, no drive letter)
    & $setVar 'OSDPartitions1Type'      'MSR'
    & $setVar 'OSDPartitions1Size'      '16'
    & $setVar 'OSDPartitions1SizeUnits' 'MB'

    # Partition 2 — Windows (remainder, NTFS, C:)
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

foreach ($w in $WimPaths) {
    if (-not (Test-Path $w)) { throw "WIM not found: $w" }
}

Import-Module $mdtModule -Verbose:$false

#endregion

#region Create share

Write-Step "Creating deployment share: $SharePath"

if (-not (Test-Path $SharePath)) {
    New-Item -Path $SharePath -ItemType Directory -Force | Out-Null
}

# SMB share is used by MDT Workbench on the same machine — not exposed to operators
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

#region Create task sequences

if ($imported.Count -gt 0) {
    Write-Step 'Creating task sequences'

    $template = 'C:\Program Files\Microsoft Deployment Toolkit\Templates\Client.xml'
    if (-not (Test-Path $template)) {
        throw "MDT task sequence template not found: $template"
    }

    foreach ($os in $imported) {
        $tsID   = 'DEPLOY-' + ($os.Folder.ToUpper() -replace '[_]{1,}', '-')
        $tsName = "Deploy $($os.Edition)"

        $mdtOS = Get-ChildItem "${drive}:\Operating Systems\$($os.Folder)" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.NodeType -eq 'OperatingSystem' } | Select-Object -First 1

        if (-not $mdtOS) {
            Write-Warning "  OS object not found for $($os.Folder) — skipping TS"
            continue
        }

        Import-MDTTaskSequence -Path "${drive}:\Task Sequences" `
            -ID $tsID -Name $tsName -Template $template `
            -Comments '' `
            -OperatingSystemPath $mdtOS.PSPath `
            -FullName 'Windows User' -OrgName $OrgName `
            -HomePage 'about:blank' `
            -Verbose:$false | Out-Null

        $tsXml = Join-Path $SharePath "Control\$tsID\ts.xml"
        Set-UEFIPartitionScheme -TsXmlPath $tsXml

        Write-Host "  [$tsID] $tsName  (UEFI partitioning applied)"
    }
}

#endregion

#region Write zero-touch CustomSettings.ini

Write-Step 'Writing zero-touch CustomSettings.ini'

$firstTsID = if ($imported.Count -gt 0) {
    'DEPLOY-' + ($imported[0].Folder.ToUpper() -replace '[_]{1,}', '-')
} else {
    'DEPLOY-WIN11-PRO'
}

# All wizard pages suppressed — operator sees only the progress bar.
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

; Reboot immediately after deploy (activates any queued BIOS changes)
FinishAction=REBOOT
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
; Look on the booted media — no network needed
DeployRoot=.
SkipBDDWelcome=YES
KeyboardLocale=en-US
"@

Set-Content -Path (Join-Path $SharePath 'Control\Bootstrap.ini') -Value $bs -Encoding ASCII
Write-Host "  Control\Bootstrap.ini written (standalone media)"

#endregion

#region Update deployment share

Write-Step 'Updating deployment share (generating LiteTouchPE_x64.wim — a few minutes)'
Update-MDTDeploymentShare -Path "${drive}:" -Force -Verbose:$false

$bootWim = Join-Path $SharePath 'Boot\LiteTouchPE_x64.wim'
if (Test-Path $bootWim) {
    $mb = [math]::Round((Get-Item $bootWim).Length / 1MB, 1)
    Write-Host "  Boot WIM ready: Boot\LiteTouchPE_x64.wim ($mb MB)"
}

#endregion

#region Summary

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Green
Write-Host ' Deployment share ready' -ForegroundColor Green
Write-Host '=====================================================' -ForegroundColor Green
Write-Host "  Path : $SharePath"
if ($imported.Count -gt 0) {
    Write-Host ''
    Write-Host '  Task sequences:'
    foreach ($os in $imported) {
        $tsID = 'DEPLOY-' + ($os.Folder.ToUpper() -replace '[_]{1,}', '-')
        Write-Host "    [$tsID]  $($os.Edition)"
    }
}
Write-Host ''
Write-Host '  Next: build the operator payload ISO:'
Write-Host "  PS> .\scripts\mdt\New-MDTMedia.ps1 -OutputPath 'C:\MDTMedia'"
Write-Host '=====================================================' -ForegroundColor Green

#endregion
