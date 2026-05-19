#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Interactive launcher for the MDT Deployment Factory.
.DESCRIPTION
    Guided menu covering the full admin workflow:
      1  Check prerequisites
      2  Configure deployment settings
      3  Initialize deployment share
      4  Import additional WIM
      5  Build operator ISO

    Run via START.bat (handles UAC elevation) or directly:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File Start-MDT.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$mdtScripts = Join-Path $PSScriptRoot 'scripts\mdt'

# Session config -- populated by step 2, consumed by steps 3-5.
# Persists for the lifetime of this menu session.
$script:Cfg = @{
    SharePath       = 'C:\MDTDeploymentShare'
    OutputPath      = 'C:\MDTMedia'
    OrgName         = 'My Organization'
    BDEPin          = ''
    FinishAction    = 'REBOOT'
    OSDComputerName = ''
}

# ---------------------------------------------------------------------------
# Prerequisite detection
# ---------------------------------------------------------------------------

function Get-Prereqs {
    $adkRoot = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
    return [ordered]@{
        MDT   = Test-Path 'C:\Program Files\Microsoft Deployment Toolkit\bin\MicrosoftDeploymentToolkit.psd1'
        ADK   = Test-Path (Join-Path $adkRoot 'Deployment Tools')
        WinPE = Test-Path (Join-Path $adkRoot 'Windows Preinstallation Environment\amd64')
        Share = Test-Path $script:Cfg.SharePath
    }
}

function Write-StatusLine {
    param([bool]$Ok, [string]$Label, [switch]$Newline)
    $tag   = if ($Ok) { '[OK]' } else { '[!!]' }
    $color = if ($Ok) { 'Green' } else { 'Red' }
    $nl    = if ($Newline) { '' } else { '   ' }
    Write-Host ("  {0} {1}{2}" -f $tag, $Label, $nl) -ForegroundColor $color -NoNewline
}

# ---------------------------------------------------------------------------
# Banner -- redrawn before every menu
# ---------------------------------------------------------------------------

function Show-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  =================================================' -ForegroundColor Cyan
    Write-Host '     MDT Deployment Factory' -ForegroundColor Cyan
    Write-Host '  =================================================' -ForegroundColor Cyan
    Write-Host ''

    $p = Get-Prereqs

    Write-Host '  System' -ForegroundColor DarkGray
    Write-StatusLine $p.MDT   'MDT 8456'
    Write-StatusLine $p.ADK   'Windows ADK'
    Write-StatusLine $p.WinPE 'WinPE add-on' -Newline
    Write-Host ''

    $shareLabel = if ($p.Share) {
        "Share: $($script:Cfg.SharePath)"
    } else {
        "Share: not found at $($script:Cfg.SharePath)  (run step 3)"
    }
    Write-StatusLine $p.Share $shareLabel -Newline
    Write-Host ''

    if ($script:Cfg.BDEPin -ne '') {
        Write-Host "  BitLocker: enabled (PIN set)   Finish: $($script:Cfg.FinishAction)" -ForegroundColor DarkGray
    } else {
        Write-Host "  BitLocker: disabled            Finish: $($script:Cfg.FinishAction)" -ForegroundColor DarkGray
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Shared input helpers
# ---------------------------------------------------------------------------

function Read-Default {
    param([string]$Prompt, [string]$Default)
    $v = (Read-Host "  $Prompt [$Default]").Trim()
    return if ($v) { $v } else { $Default }
}

function Read-WimPaths {
    $list = [System.Collections.Generic.List[string]]::new()
    Write-Host '  Enter the full path to each WIM or ESD file.' -ForegroundColor DarkGray
    Write-Host '  Leave the prompt blank and press Enter when finished.' -ForegroundColor DarkGray
    Write-Host ''
    $i = 1
    while ($true) {
        $p = (Read-Host "  WIM #$i").Trim()
        if ($p -eq '') {
            if ($list.Count -eq 0) {
                Write-Host '  At least one WIM is required.' -ForegroundColor Yellow
                continue
            }
            break
        }
        if (-not (Test-Path $p)) {
            Write-Host "  File not found -- try again: $p" -ForegroundColor Yellow
            continue
        }
        if ([IO.Path]::GetExtension($p).ToLower() -notin '.wim','.esd') {
            Write-Host "  Not a .wim or .esd file: $p" -ForegroundColor Yellow
            continue
        }
        $list.Add($p)
        Write-Host "  Added: $p" -ForegroundColor Green
        $i++
    }
    return $list.ToArray()
}

function Wait-ForKey {
    Write-Host ''
    Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# ---------------------------------------------------------------------------
# Step 1 -- Prerequisites
# ---------------------------------------------------------------------------

function Invoke-CheckPrereqs {
    Show-Banner
    Write-Host '  [1] Prerequisites' -ForegroundColor Cyan
    Write-Host '      Install in the order listed below.' -ForegroundColor DarkGray
    Write-Host ''

    $p = Get-Prereqs
    $allOk = $true

    if ($p.ADK) {
        Write-Host '  [OK] Windows ADK' -ForegroundColor Green
    } else {
        $allOk = $false
        Write-Host '  [!!] Windows ADK -- not found' -ForegroundColor Red
        Write-Host '       Install: select "Deployment Tools" only.'
        Write-Host '       https://learn.microsoft.com/windows-hardware/get-started/adk-install'
        Write-Host ''
    }

    if ($p.WinPE) {
        Write-Host '  [OK] WinPE add-on' -ForegroundColor Green
    } else {
        $allOk = $false
        Write-Host '  [!!] WinPE add-on -- not found' -ForegroundColor Red
        Write-Host '       Separate installer on the same ADK download page.'
        Write-Host '       https://learn.microsoft.com/windows-hardware/get-started/adk-install'
        Write-Host ''
    }

    if ($p.MDT) {
        Write-Host '  [OK] MDT 8456' -ForegroundColor Green
    } else {
        $allOk = $false
        Write-Host '  [!!] MDT 8456 -- not found' -ForegroundColor Red
        Write-Host '       https://www.microsoft.com/en-us/download/details.aspx?id=54259'
        Write-Host ''
        Write-Host '       After installing MDT, also apply hotfix KB4564442'
        Write-Host '       (required for Windows 11 UEFI deployments):'
        Write-Host '       https://support.microsoft.com/kb/4564442'
        Write-Host ''
    }

    Write-Host ''
    if ($allOk) {
        Write-Host '  All prerequisites met. Proceed to step 2.' -ForegroundColor Green
    } else {
        Write-Host '  Install order: ADK -> WinPE add-on -> MDT -> KB4564442' -ForegroundColor Yellow
        Write-Host '  Re-run this check after each install to confirm.' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Step 2 -- Configure
# ---------------------------------------------------------------------------

function Invoke-Configure {
    Show-Banner
    Write-Host '  [2] Configure deployment settings' -ForegroundColor Cyan
    Write-Host '      These are baked into the ISO. Re-run steps 3 and 5 to apply changes.' -ForegroundColor DarkGray
    Write-Host ''

    $script:Cfg.SharePath  = Read-Default 'Deployment share path          ' $script:Cfg.SharePath
    $script:Cfg.OutputPath = Read-Default 'ISO output folder               ' $script:Cfg.OutputPath
    $script:Cfg.OrgName    = Read-Default 'Organization name               ' $script:Cfg.OrgName

    Write-Host ''
    Write-Host '  -- BitLocker --' -ForegroundColor DarkGray
    Write-Host '  Alphanumeric startup PIN used for C: (TPM+PIN) and data drives.' -ForegroundColor DarkGray
    Write-Host '  Leave blank to disable BitLocker (useful for VMs / no TPM).' -ForegroundColor DarkGray
    $pin = (Read-Host '  BDEPin (blank = disabled)').Trim()
    $script:Cfg.BDEPin = $pin
    if ($pin) {
        Write-Host '  BitLocker enabled. C: gets TPM+PIN; data drives get auto-unlock.' -ForegroundColor Green
    } else {
        Write-Host '  BitLocker disabled.' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '  -- Computer naming --' -ForegroundColor DarkGray
    Write-Host '  Leave blank  = Windows random name (WIN-XXXXXX)' -ForegroundColor DarkGray
    Write-Host '  %SerialNumber%  = machine service tag / serial' -ForegroundColor DarkGray
    Write-Host '  Fixed string  = same name on every machine (test only)' -ForegroundColor DarkGray
    $script:Cfg.OSDComputerName = (Read-Host '  OSDComputerName (blank = random)').Trim()

    Write-Host ''
    Write-Host '  -- Post-deploy action --' -ForegroundColor DarkGray
    $fa = Read-Default 'FinishAction (REBOOT / SHUTDOWN)' $script:Cfg.FinishAction
    $script:Cfg.FinishAction = $fa.ToUpper()

    Write-Host ''
    Write-Host '  Settings saved for this session.' -ForegroundColor Green
    Write-Host '  Run step 3 to apply them to the deployment share.' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Step 3 -- Initialize
# ---------------------------------------------------------------------------

function Invoke-Initialize {
    Show-Banner
    Write-Host '  [3] Initialize deployment share' -ForegroundColor Cyan
    Write-Host '      Imports your WIM, creates the task sequence, writes zero-touch config.' -ForegroundColor DarkGray
    Write-Host '      Safe to re-run -- existing share is updated, not replaced.' -ForegroundColor DarkGray
    Write-Host ''

    $p = Get-Prereqs
    if (-not ($p.MDT -and $p.ADK -and $p.WinPE)) {
        Write-Host '  Prerequisites missing. Complete step 1 before continuing.' -ForegroundColor Red
        return
    }

    $wimPaths = Read-WimPaths
    Write-Host ''

    $script:Cfg.SharePath = Read-Default 'Deployment share path' $script:Cfg.SharePath
    $script:Cfg.OrgName   = Read-Default 'Organization name    ' $script:Cfg.OrgName

    Write-Host ''
    Write-Host '  Starting -- this takes a few minutes...' -ForegroundColor DarkGray
    Write-Host ''

    try {
        & "$mdtScripts\Initialize-MDTDeploymentShare.ps1" `
            -WimPaths        $wimPaths `
            -SharePath       $script:Cfg.SharePath `
            -OrgName         $script:Cfg.OrgName `
            -BDEPin          $script:Cfg.BDEPin `
            -FinishAction    $script:Cfg.FinishAction `
            -OSDComputerName $script:Cfg.OSDComputerName
        Write-Host ''
        Write-Host '  Deployment share ready.' -ForegroundColor Green
        Write-Host '  Next: run step 5 to build the operator ISO.' -ForegroundColor DarkGray
    } catch {
        Write-Host "  Initialize failed: $_" -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# Step 4 -- Import WIM
# ---------------------------------------------------------------------------

function Invoke-ImportWim {
    Show-Banner
    Write-Host '  [4] Import additional WIM' -ForegroundColor Cyan
    Write-Host '      Adds a new image to an existing share and creates a task sequence.' -ForegroundColor DarkGray
    Write-Host '      Run step 5 afterwards to rebuild the ISO with the new image.' -ForegroundColor DarkGray
    Write-Host ''

    if (-not (Test-Path $script:Cfg.SharePath)) {
        Write-Host "  Deployment share not found at $($script:Cfg.SharePath)." -ForegroundColor Red
        Write-Host '  Run step 3 (Initialize) first.' -ForegroundColor Red
        return
    }

    $wimPaths = Read-WimPaths
    Write-Host ''

    $script:Cfg.SharePath = Read-Default 'Deployment share path' $script:Cfg.SharePath

    Write-Host ''
    try {
        & "$mdtScripts\Import-WimImages.ps1" `
            -WimPaths  $wimPaths `
            -SharePath $script:Cfg.SharePath `
            -OrgName   $script:Cfg.OrgName
        Write-Host ''
        Write-Host '  Import complete. Run step 5 to rebuild the ISO.' -ForegroundColor Green
    } catch {
        Write-Host "  Import failed: $_" -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# Step 5 -- Build ISO
# ---------------------------------------------------------------------------

function Invoke-BuildIso {
    Show-Banner
    Write-Host '  [5] Build operator ISO' -ForegroundColor Cyan
    Write-Host '      Generates LiteTouchMedia_x64.iso from the deployment share.' -ForegroundColor DarkGray
    Write-Host '      First run takes 10-30 minutes -- this is normal, not a hang.' -ForegroundColor DarkGray
    Write-Host ''

    if (-not (Test-Path $script:Cfg.SharePath)) {
        Write-Host "  Deployment share not found at $($script:Cfg.SharePath)." -ForegroundColor Red
        Write-Host '  Run step 3 (Initialize) first.' -ForegroundColor Red
        return
    }

    $script:Cfg.SharePath  = Read-Default 'Deployment share path' $script:Cfg.SharePath
    $script:Cfg.OutputPath = Read-Default 'ISO output folder    ' $script:Cfg.OutputPath

    Write-Host ''
    Write-Host '  Building -- do not close this window...' -ForegroundColor DarkGray
    Write-Host ''

    try {
        & "$mdtScripts\New-MDTMedia.ps1" `
            -SharePath  $script:Cfg.SharePath `
            -OutputPath $script:Cfg.OutputPath
    } catch {
        Write-Host "  Build failed: $_" -ForegroundColor Red
        return
    }

    # Locate the ISO -- path varies by MDT version
    $isoPath = @(
        (Join-Path $script:Cfg.OutputPath 'ISO\LiteTouchMedia_x64.iso'),
        (Join-Path $script:Cfg.OutputPath 'LiteTouchMedia_x64.iso')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    Write-Host ''
    Write-Host '  =================================================' -ForegroundColor Green
    Write-Host '   ISO READY' -ForegroundColor Green
    Write-Host '  =================================================' -ForegroundColor Green
    Write-Host ''

    if ($isoPath) {
        $mb = [math]::Round((Get-Item $isoPath).Length / 1MB)
        Write-Host "  File : $isoPath"
        Write-Host "  Size : $mb MB"
    } else {
        Write-Host "  Output folder: $($script:Cfg.OutputPath)"
    }

    Write-Host ''
    Write-Host '  Next steps' -ForegroundColor Cyan
    Write-Host '  1. Upload the ISO to your file server or shared drive.'
    Write-Host '  2. Send operators the download link and these instructions:'
    Write-Host ''
    Write-Host '  ---- Operator instructions (copy / paste or print) ------'
    Write-Host '  1. Download the ISO from [your link here]'
    Write-Host '  2. Download Rufus from https://rufus.ie'
    Write-Host '  3. Open Rufus -- select the ISO, select the USB -- click START'
    Write-Host '     (~20 min to write)'
    Write-Host '  4. Plug USB into target laptop, press F12 at POST for boot menu'
    Write-Host '  5. Select the USB -- walk away (~20 min to deploy)'
    Write-Host '  ---------------------------------------------------------'
    Write-Host ''
    Write-Host '  To update the image later:'
    Write-Host '  Import new WIM (step 4) -> rebuild ISO (step 5) -> update download link.'
    Write-Host '  Operators use the same Rufus process -- no instructions change.'
}

# ---------------------------------------------------------------------------
# Main menu loop
# ---------------------------------------------------------------------------

while ($true) {
    Show-Banner

    Write-Host '  First time  ->  1  2  3  5  (in order)' -ForegroundColor DarkGray
    Write-Host '  New image   ->  4  5  then update your download link' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  1  Check prerequisites'
    Write-Host '  2  Configure deployment settings  (BitLocker, naming, finish action)'
    Write-Host '  3  Initialize deployment share    (one-time; safe to re-run)'
    Write-Host '  4  Import additional WIM'
    Write-Host '  5  Build operator ISO'
    Write-Host ''
    Write-Host '  Q  Quit'
    Write-Host ''

    $choice = (Read-Host '  Select').Trim().ToUpper()

    switch ($choice) {
        '1'     { Invoke-CheckPrereqs; Wait-ForKey }
        '2'     { Invoke-Configure;    Wait-ForKey }
        '3'     { Invoke-Initialize;   Wait-ForKey }
        '4'     { Invoke-ImportWim;    Wait-ForKey }
        '5'     { Invoke-BuildIso;     Wait-ForKey }
        'Q'     { exit 0 }
        default { Write-Host "  Unknown option: $choice" -ForegroundColor Yellow; Start-Sleep 1 }
    }
}
