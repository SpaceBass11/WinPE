#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Build the operator payload ISO from the MDT deployment share.
.DESCRIPTION
    Creates (or updates) an MDT standalone media object and generates a
    bootable ISO at OutputPath\LiteTouchMedia_x64.iso.

    That ISO is your payload:
      - Upload it to a download link for operators
      - Operator: Rufus -> USB -> boot laptop -> fully automated deploy

    Run this every time you want to publish an updated payload (new WIM,
    new drivers, changed settings). The ISO is completely self-contained  --
    no network required when operators use it.
.PARAMETER SharePath
    Local path to the MDT deployment share.
    Default: C:\MDTDeploymentShare
.PARAMETER OutputPath
    Where to write the media files and the final ISO.
    Default: C:\MDTMedia
.PARAMETER MediaName
    Internal MDT media object name. Changing this creates a separate
    media entry in Workbench  -- leave at default unless you manage
    multiple media targets.
    Default: MEDIA001
.PARAMETER SelectionProfile
    Which content to include in the media. 'Everything' includes all OSes,
    drivers, and applications. Create a named selection profile in MDT
    Workbench to limit media size (e.g., one OS only).
    Default: Everything
.EXAMPLE
    # Standard build  -- generates C:\MDTMedia\LiteTouchMedia_x64.iso
    .\New-MDTMedia.ps1

.EXAMPLE
    # Custom output folder
    .\New-MDTMedia.ps1 -OutputPath 'D:\Payloads\Win11_24H2'
#>

[CmdletBinding()]
param(
    [string]$SharePath       = 'C:\MDTDeploymentShare',
    [string]$OutputPath      = 'C:\MDTMedia',
    [string]$MediaName       = 'MEDIA001',
    [string]$SelectionProfile = 'Everything'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Load MDT

$mdtModule = 'C:\Program Files\Microsoft Deployment Toolkit\bin\MicrosoftDeploymentToolkit.psd1'
if (-not (Test-Path $mdtModule)) {
    throw "MDT not installed. Run Initialize-MDTDeploymentShare.ps1 first."
}
Import-Module $mdtModule -Verbose:$false

if (-not (Test-Path $SharePath)) {
    throw "Deployment share not found: $SharePath. Run Initialize-MDTDeploymentShare.ps1 first."
}

$drive = 'DS001'
if (Get-PSDrive -Name $drive -ErrorAction SilentlyContinue) {
    Remove-PSDrive -Name $drive -Force
}
New-PSDrive -Name $drive -PSProvider MDTProvider -Root $SharePath `
    -Verbose:$false | Out-Null

#endregion

#region Ensure output folder exists

if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    Write-Host "Created output folder: $OutputPath"
}

#endregion

#region Create or locate MDT media object

$mediaPath = "${drive}:\Media\$MediaName"

$existing = Get-ChildItem "${drive}:\Media" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq $MediaName }

if (-not $existing) {
    Write-Host "Creating MDT media object: $MediaName"
    New-Item -Path "${drive}:\Media" -Enable $true -Name $MediaName `
        -Comments 'Operator payload  -- standalone USB media' `
        -Root $OutputPath `
        -SelectionProfile $SelectionProfile | Out-Null
    Write-Host "  Media object created at $mediaPath"
} else {
    Write-Host "Media object exists: $mediaPath"

    # Update root path in case OutputPath changed
    $mediaItem = Get-Item $mediaPath
    if ($mediaItem.Root -ne $OutputPath) {
        Set-ItemProperty $mediaPath -Name 'Root' -Value $OutputPath
        Write-Host "  Updated media root -> $OutputPath"
    }
}

#endregion

#region Build the media

Write-Host ''
Write-Host 'Building media  -- this copies the full WIM and WinPE files.' -ForegroundColor Cyan
Write-Host 'First build takes 10-30 min depending on WIM size. Subsequent builds are faster.' -ForegroundColor Cyan
Write-Host ''

Update-MDTMedia -Path $mediaPath -Verbose:$false

#endregion

#region Report output

$isoPath = Join-Path $OutputPath 'LiteTouchMedia_x64.iso'

if (Test-Path $isoPath) {
    $sizeMB = [math]::Round((Get-Item $isoPath).Length / 1MB, 0)
    $sizeGB = [math]::Round($sizeMB / 1024, 1)

    Write-Host ''
    Write-Host '=====================================================' -ForegroundColor Green
    Write-Host ' Payload ISO ready' -ForegroundColor Green
    Write-Host '=====================================================' -ForegroundColor Green
    Write-Host "  File : $isoPath"
    Write-Host "  Size : $sizeGB GB ($sizeMB MB)"
    Write-Host ''
    Write-Host '  Operator instructions:'
    Write-Host '    1. Download the ISO'
    Write-Host '    2. Rufus -> select ISO -> select USB -> START'
    Write-Host '    3. Boot laptop from USB. Walk away.'
    Write-Host '=====================================================' -ForegroundColor Green
} else {
    Write-Warning "ISO not found at $isoPath  -- check MDT/ADK installation and try again."
}

#endregion
