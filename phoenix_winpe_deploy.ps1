#Requires -RunAsAdministrator
<#+
.SYNOPSIS
    PhoenixPE/WinPE Universal Image Deployment Script
.DESCRIPTION
    Deploys a Windows WIM/ESD image to a chosen disk. Designed for minimal
    WinPE environments such as PhoenixPE and compatible with PowerShell 5.0.
    The script searches for image files, partitions the target disk using
    diskpart, applies the image with DISM, and configures UEFI boot files.
.NOTES
    Author: ChatGPT Master Architect
    Version: 1.0
#>

[CmdletBinding()]
param(
    [string]$ImagePath,
    [string]$WimFile,
    [int]$Index = 1,
    [int]$Disk = -1,
    [switch]$ListOnly,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# region Logging ---------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Info','Warn','Error','Success')] [string]$Level = 'Info'
    )
    $colorMap = @{ Info='Cyan'; Warn='Yellow'; Error='Red'; Success='Green' }
    $timestamp = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$timestamp] $Message" -ForegroundColor $colorMap[$Level]
}
# endregion Logging -----------------------------------------------------------

# region Environment ----------------------------------------------------------
function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TempPath {
    $candidates = @($env:TEMP,'X:\Temp','C:\Temp')
    foreach($p in $candidates){
        try {
            if (-not [string]::IsNullOrEmpty($p)) {
                if(-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
                return $p
            }
        } catch {}
    }
    return 'C:\Temp'
}

function Test-WinPE {
    if ($env:SystemDrive -ne 'X:') {
        Write-Log 'Warning: script is intended for WinPE but X: drive was not detected.' -Level Warn
    }
}
# endregion Environment -------------------------------------------------------

# region Image Discovery ------------------------------------------------------
function Find-WimFiles {
    if ($WimFile) {
        if (Test-Path $WimFile) {
            return @(Get-Item $WimFile)
        } else {
            Write-Log "Specified WIM file not found: $WimFile" -Level Error
            return @()
        }
    }

    $searchRoots = @()
    if ($ImagePath -and (Test-Path $ImagePath)) {
        $searchRoots += Get-Item $ImagePath
    } else {
        # Enumerate fixed disks (excluding USB)
        $disks = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
        foreach($d in $disks){ $searchRoots += Get-Item ($d.DeviceID + '\') }
    }

    $patterns = '*.wim','*.esd'
    $results = @()
    foreach($root in $searchRoots){
        foreach($pattern in $patterns){
            try {
                $results += Get-ChildItem -Path $root.FullName -Filter $pattern -Recurse -ErrorAction SilentlyContinue
            } catch {}
        }
    }
    return ($results | Sort-Object Length -Descending)
}

function Select-Image {
    param([array]$Files)
    if ($Files.Count -eq 0) { return $null }
    if ($ListOnly -or $Files.Count -eq 1) { return $Files[0] }
    for($i=0;$i -lt $Files.Count;$i++){
        $size = [math]::Round($Files[$i].Length/1GB,2)
        Write-Host "[$($i+1)] $($Files[$i].FullName) - $size GB"
    }
    do {
        $choice = Read-Host "Select image number"
        if([int]::TryParse($choice,[ref]$null)){
            $idx = [int]$choice - 1
            if($idx -ge 0 -and $idx -lt $Files.Count){ return $Files[$idx] }
        }
    } while ($true)
}
# endregion Image Discovery ---------------------------------------------------

# region Disk Management ------------------------------------------------------
function Get-SystemDisks {
    $list = @()
    $wmiDisks = Get-WmiObject Win32_DiskDrive | Where-Object { $_.InterfaceType -ne 'USB' }
    foreach($d in $wmiDisks){
        $size = if($d.Size){ [math]::Round($d.Size/1GB,2) } else { 0 }
        $list += [pscustomobject]@{
            Number = $d.Index
            SizeGB = $size
            Model = ($d.Model -replace '\s+',' ').Trim()
        }
    }
    return $list
}

function Select-TargetDisk {
    param([array]$Disks)
    if ($Disks.Count -eq 0) { return $null }
    if ($Disk -ge 0) {
        return ($Disks | Where-Object { $_.Number -eq $Disk })
    }
    Write-Host ''
    Write-Host 'Available Disks:' -ForegroundColor Cyan
    foreach($d in $Disks){
        Write-Host "  [$($d.Number)] $($d.Model) - $($d.SizeGB) GB" -ForegroundColor Yellow
    }
    do {
        $choice = Read-Host 'Enter disk number'
        if([int]::TryParse($choice,[ref]$null)){
            $sel = $Disks | Where-Object { $_.Number -eq [int]$choice }
            if($sel){ return $sel }
        }
    } while ($true)
}

function Confirm-DiskWipe {
    param([psobject]$DiskInfo)
    Write-Host ''
    Write-Host "WARNING: Disk $($DiskInfo.Number) will be wiped." -ForegroundColor Red
    if ($Force) { return $true }
    $confirm = Read-Host "Type YES to continue"
    return ($confirm -eq 'YES')
}

function New-DiskpartScript {
    param([int]$DiskNumber)
    @"
select disk $DiskNumber
clean
convert gpt
create partition efi size=300
format quick fs=fat32 label=System
assign letter=S
create partition msr size=16
create partition primary
format quick fs=ntfs label=Windows
assign letter=C
exit
"@ | Set-Content -Path $script:DiskpartFile -Force
}

function Invoke-Diskpart {
    Write-Log 'Partitioning disk...' -Level Warn
    $p = Start-Process diskpart.exe -ArgumentList "/s `"$script:DiskpartFile`"" -PassThru -Wait -WindowStyle Hidden
    return ($p.ExitCode -eq 0)
}
# endregion Disk Management ---------------------------------------------------

# region Imaging --------------------------------------------------------------
function Apply-Image {
    param([string]$Image,[string]$Target,[int]$Idx)
    Write-Log "Applying image index $Idx from $(Split-Path -Leaf $Image)" -Level Info
    $args = @('/apply-image',"/imagefile:$Image", "/index:$Idx", "/applydir:$Target")
    $p = Start-Process dism.exe -ArgumentList $args -PassThru -Wait -WindowStyle Hidden
    return ($p.ExitCode -eq 0)
}

function Configure-Boot {
    Write-Log 'Setting up boot files...' -Level Info
    $args = @('C:\Windows','/s','S:','/f','UEFI')
    $p = Start-Process bcdboot.exe -ArgumentList $args -PassThru -Wait -WindowStyle Hidden
    return ($p.ExitCode -eq 0)
}
# endregion Imaging -----------------------------------------------------------

# region Main -----------------------------------------------------------------
$script:DiskpartFile = Join-Path (Get-TempPath) 'deploy_diskpart.txt'

if (-not (Test-Administrator)) { Write-Log 'Administrator rights required.' -Level Error; exit 1 }
Test-WinPE

$images = Find-WimFiles
if ($images.Count -eq 0) { Write-Log 'No image files found.' -Level Error; exit 1 }

if ($ListOnly) {
    $images | ForEach-Object { Write-Host $_.FullName }
    exit 0
}

$image = Select-Image -Files $images
if (-not $image) { Write-Log 'No image selected.' -Level Error; exit 1 }

$disks = Get-SystemDisks
$target = Select-TargetDisk -Disks $disks
if (-not $target) { Write-Log 'No disk selected.' -Level Error; exit 1 }

if (-not (Confirm-DiskWipe -DiskInfo $target)) { Write-Log 'Operation cancelled.' -Level Error; exit 1 }

New-DiskpartScript -DiskNumber $target.Number
if (-not (Invoke-Diskpart)) { Write-Log 'Diskpart failed.' -Level Error; exit 1 }

if (-not (Apply-Image -Image $image.FullName -Target 'C:\' -Idx $Index)) { Write-Log 'Image apply failed.' -Level Error; exit 1 }

if (-not (Configure-Boot)) { Write-Log 'BCDBoot failed.' -Level Error; exit 1 }

Write-Log 'Deployment completed successfully.' -Level Success
# endregion Main --------------------------------------------------------------
