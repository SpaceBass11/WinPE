#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Import one or more WIM/ESD files into an existing MDT deployment share.
.DESCRIPTION
    Adds new operating systems to an MDT deployment share without rebuilding
    the entire share. Optionally creates a task sequence for each imported OS.

    Equivalent to dropping a new .wim into the USB tool's images/ folder —
    except here you also need to run Update-MDTDeploymentShare afterward
    so the boot.wim picks up any WinPE driver updates.
.PARAMETER SharePath
    Local path to the MDT deployment share.
    Default: C:\MDTDeploymentShare
.PARAMETER WimPaths
    One or more explicit WIM/ESD file paths to import.
.PARAMETER WimFolder
    A folder to scan for *.wim and *.esd files. Ignored if -WimPaths is set.
.PARAMETER CreateTaskSequences
    Create a task sequence for each imported OS.
    Default: true
.PARAMETER OrgName
    Organization name for task sequences.
    Default: My Organization
.PARAMETER UpdateShare
    Run Update-MDTDeploymentShare after import to regenerate boot.wim.
    Default: true
.EXAMPLE
    # Import a single new OS
    .\Import-WimImages.ps1 -WimPaths 'C:\images\Win11_Ent_24H2.wim'

.EXAMPLE
    # Import all WIMs in a folder, skip TS creation
    .\Import-WimImages.ps1 -WimFolder 'C:\images' -CreateTaskSequences:$false
#>

[CmdletBinding()]
param(
    [string]$SharePath = 'C:\MDTDeploymentShare',
    [string[]]$WimPaths = @(),
    [string]$WimFolder,
    [bool]$CreateTaskSequences = $true,
    [string]$OrgName = 'My Organization',
    [bool]$UpdateShare = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Resolve WIM list
if ($WimPaths.Count -eq 0 -and $WimFolder) {
    if (-not (Test-Path $WimFolder)) {
        throw "WimFolder not found: $WimFolder"
    }
    $WimPaths = Get-ChildItem -Path $WimFolder -Include '*.wim','*.esd' -Recurse |
        Select-Object -ExpandProperty FullName
    if ($WimPaths.Count -eq 0) {
        throw "No .wim or .esd files found in: $WimFolder"
    }
}

if ($WimPaths.Count -eq 0) {
    throw 'Provide -WimPaths or -WimFolder.'
}
#endregion

#region Load MDT
$mdtModule = 'C:\Program Files\Microsoft Deployment Toolkit\bin\MicrosoftDeploymentToolkit.psd1'
if (-not (Test-Path $mdtModule)) {
    throw "MDT not installed. Run Initialize-MDTDeploymentShare.ps1 first."
}
Import-Module $mdtModule -Verbose:$false

if (-not (Test-Path $SharePath)) {
    throw "Deployment share not found: $SharePath. Run Initialize-MDTDeploymentShare.ps1 first."
}

$driveName = 'DS001'
if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
    Remove-PSDrive -Name $driveName -Force
}
New-PSDrive -Name $driveName -PSProvider MDTProvider -Root $SharePath `
    -Verbose:$false | Out-Null
#endregion

#region Import each WIM
$imported = @()

foreach ($wimPath in $WimPaths) {
    if (-not (Test-Path $wimPath)) {
        Write-Warning "WIM not found, skipping: $wimPath"
        continue
    }

    # Get edition name from index 1 for folder naming (same /English flag as deploy script)
    $info = & dism.exe /Get-WimInfo /WimFile:"$wimPath" /Index:1 /English 2>&1
    $nameLine = $info | Where-Object { $_ -match '^Name\s*:' } | Select-Object -First 1
    $editionName = if ($nameLine) {
        ($nameLine -replace '^Name\s*:\s*', '').Trim()
    } else {
        [System.IO.Path]::GetFileNameWithoutExtension($wimPath)
    }

    $folderName = ($editionName -replace '[^\w\-]', '_').Trim('_')

    $existingOS = Get-ChildItem "$driveName`:\Operating Systems" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $folderName }

    if ($existingOS) {
        Write-Warning "OS folder already exists, skipping import: $folderName"
        continue
    }

    Write-Host "Importing: $editionName -> Operating Systems\$folderName"
    Import-MDTOperatingSystem -Path "$driveName`:\Operating Systems" `
        -SourceFile $wimPath `
        -DestinationFolder $folderName `
        -Verbose:$false | Out-Null

    $imported += [PSCustomObject]@{
        FolderName  = $folderName
        EditionName = $editionName
    }
    Write-Host "  Done: $editionName"
}
#endregion

#region Create task sequences
if ($CreateTaskSequences -and $imported.Count -gt 0) {
    Write-Host ''
    Write-Host 'Creating task sequences...'

    $templatePath = 'C:\Program Files\Microsoft Deployment Toolkit\Templates\Client.xml'
    if (-not (Test-Path $templatePath)) {
        Write-Warning "MDT template not found: $templatePath — skipping task sequence creation."
    } else {
        foreach ($os in $imported) {
            $tsID = 'DEPLOY-' + ($os.FolderName.ToUpper() -replace '_', '-' -replace '-{2,}', '-')

            $mdtOS = Get-ChildItem "$driveName`:\Operating Systems\$($os.FolderName)" -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.NodeType -eq 'OperatingSystem' } | Select-Object -First 1

            if (-not $mdtOS) {
                Write-Warning "  Cannot find MDT OS object for $($os.FolderName) — skipping TS"
                continue
            }

            Write-Host "  [$tsID] $($os.EditionName)"
            Import-MDTTaskSequence -Path "$driveName`:\Task Sequences" `
                -ID $tsID `
                -Name "Deploy $($os.EditionName)" `
                -Template $templatePath `
                -Comments "Deploy $($os.EditionName) — imported by Import-WimImages.ps1" `
                -OperatingSystemPath $mdtOS.PSPath `
                -FullName 'Windows User' `
                -OrgName $OrgName `
                -HomePage 'about:blank' `
                -Verbose:$false | Out-Null
        }
    }
}
#endregion

#region Update deployment share
if ($UpdateShare) {
    Write-Host ''
    Write-Host 'Updating deployment share (regenerating LiteTouchPE_x64.wim)...'
    Update-MDTDeploymentShare -Path "$driveName`:" -Force -Verbose:$false
    Write-Host 'Done.'
}
#endregion

Write-Host ''
Write-Host "Import complete. $($imported.Count) OS(s) added to $SharePath"
