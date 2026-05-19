#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Interactive launcher for the MDT Deployment Factory scripts.
.DESCRIPTION
    Presents a menu to initialize the deployment share, import additional
    WIMs, or build the operator ISO. Wraps the three scripts in scripts\mdt\
    so the admin never needs to type parameters manually.

    Run via START.bat (handles UAC elevation automatically) or directly:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File Start-MDT.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$mdtScripts = Join-Path $PSScriptRoot 'scripts\mdt'

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

function Show-Banner {
    Clear-Host
    Write-Host '=================================================' -ForegroundColor Cyan
    Write-Host '   MDT Deployment Factory' -ForegroundColor Cyan
    Write-Host '=================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Read-Default {
    param([string]$Prompt, [string]$Default)
    $answer = (Read-Host "  $Prompt [$Default]").Trim()
    if ($answer -eq '') { return $Default }
    return $answer
}

function Read-WimPaths {
    $paths = [System.Collections.Generic.List[string]]::new()
    Write-Host '  Enter WIM path(s). Leave blank and press Enter when done.'
    Write-Host ''
    $i = 1
    while ($true) {
        $p = (Read-Host "  WIM #$i").Trim()
        if ($p -eq '') {
            if ($paths.Count -eq 0) {
                Write-Host '  At least one WIM path is required.' -ForegroundColor Yellow
                continue
            }
            break
        }
        if (-not (Test-Path $p)) {
            Write-Host "  Not found -- skipping: $p" -ForegroundColor Yellow
            continue
        }
        $ext = [IO.Path]::GetExtension($p).ToLower()
        if ($ext -notin '.wim', '.esd') {
            Write-Host "  Not a .wim or .esd file -- skipping: $p" -ForegroundColor Yellow
            continue
        }
        $paths.Add($p)
        Write-Host "  OK: $p" -ForegroundColor Green
        $i++
    }
    return $paths.ToArray()
}

function Wait-ForKey {
    Write-Host ''
    Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# ---------------------------------------------------------------------------
# Menu actions
# ---------------------------------------------------------------------------

function Invoke-Initialize {
    Show-Banner
    Write-Host '  [1] Initialize Deployment Share' -ForegroundColor Cyan
    Write-Host '      Creates the share, imports WIM(s), builds task sequences.'
    Write-Host '      Run once per admin workstation; safe to re-run.'
    Write-Host ''

    $wimPaths = Read-WimPaths
    Write-Host ''

    $sharePath = Read-Default -Prompt 'Deployment share path' -Default 'C:\MDTDeploymentShare'
    $orgName   = Read-Default -Prompt 'Organization name'     -Default 'My Organization'

    Write-Host ''
    & "$mdtScripts\Initialize-MDTDeploymentShare.ps1" `
        -WimPaths  $wimPaths `
        -SharePath $sharePath `
        -OrgName   $orgName
}

function Invoke-ImportWim {
    Show-Banner
    Write-Host '  [2] Import Additional WIM' -ForegroundColor Cyan
    Write-Host '      Adds WIM(s) to an existing share and creates task sequences.'
    Write-Host ''

    $wimPaths = Read-WimPaths
    Write-Host ''

    $sharePath = Read-Default -Prompt 'Deployment share path' -Default 'C:\MDTDeploymentShare'
    $orgName   = Read-Default -Prompt 'Organization name'     -Default 'My Organization'

    Write-Host ''
    & "$mdtScripts\Import-WimImages.ps1" `
        -WimPaths  $wimPaths `
        -SharePath $sharePath `
        -OrgName   $orgName
}

function Invoke-BuildIso {
    Show-Banner
    Write-Host '  [3] Build Operator ISO' -ForegroundColor Cyan
    Write-Host '      Generates LiteTouchMedia_x64.iso from the deployment share.'
    Write-Host '      Takes 10-30 min on first run -- normal, not a hang.'
    Write-Host ''

    $sharePath  = Read-Default -Prompt 'Deployment share path' -Default 'C:\MDTDeploymentShare'
    $outputPath = Read-Default -Prompt 'ISO output folder'     -Default 'C:\MDTMedia'

    Write-Host ''
    & "$mdtScripts\New-MDTMedia.ps1" `
        -SharePath  $sharePath `
        -OutputPath $outputPath
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

while ($true) {
    Show-Banner
    Write-Host '  Typical first-time flow:  1 -> 3 -> done.' -ForegroundColor DarkGray
    Write-Host '  For a new image later:    2 -> 3 -> replace the download link.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  1  Initialize deployment share  (one-time setup)'
    Write-Host '  2  Import additional WIM'
    Write-Host '  3  Build operator ISO'
    Write-Host ''
    Write-Host '  Q  Quit'
    Write-Host ''

    $choice = (Read-Host '  Select').Trim().ToUpper()

    switch ($choice) {
        '1'     { Invoke-Initialize; Wait-ForKey }
        '2'     { Invoke-ImportWim;  Wait-ForKey }
        '3'     { Invoke-BuildIso;   Wait-ForKey }
        'Q'     { exit 0 }
        default { Write-Host "  Unknown option: $choice" -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
    }
}
