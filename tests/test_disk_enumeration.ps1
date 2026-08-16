<#
.SYNOPSIS
    Fixture test for Get-SystemDisks disk filtering + partition enumeration
    in unified_winpe_deploy.ps1.
.DESCRIPTION
    Get-SystemDisks decides which physical disks are *eligible* deploy
    targets and what each disk's partition state looks like in the TUI
    menu. Two safety properties are critical:

      1. USB / removable / CD-ROM disks must be excluded from the
         eligible list. A regression that lets a USB pass the filter
         would offer the boot drive itself as a target.
      2. Disks with partitions invisible to Windows (Linux ext/xfs/LVM)
         must report `partitionCount > 0` so the operator sees the
         "WILL BE ERASED" warning in `Show-DiskMenu`. The fix uses
         `Win32_DiskDrive.Partitions` (which reads the partition table
         directly) as the source of truth instead of
         `Win32_DiskPartition.Count` (which silently omits non-Windows
         partitions). A refactor that flipped that precedence back would
         silently report Linux disks as empty.

    No real WMI calls, no real disks. PSCustomObject stand-ins exercise
    the filter predicate and the partition-info rendering logic mirrored
    from Get-SystemDisks. A drift guard at the bottom of this file
    confirms the safety-critical code shapes still live in the deploy
    script; if either side moves, the guard fails and forces the test
    to be updated.

    Works with both PowerShell 5.1 and 7+. Returns exit code 0 on
    success, 1 on failure.
#>

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..' 'unified_winpe_deploy.ps1'
$passed = 0
$failed = 0

function Write-Result {
    param([string]$Test, [bool]$Pass, [string]$Detail = '')
    if ($Pass) {
        Write-Host "  [PASS] $Test" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $Test - $Detail" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host "`n=== WinPE Deploy - Disk Enumeration Tests ===" -ForegroundColor Cyan

# --- Filter predicate (mirrors the Where-Object block in Get-SystemDisks) ---
function Test-DiskEligible {
    param($Disk)
    return (
        $Disk.InterfaceType -ne 'USB' -and
        $Disk.MediaType -notlike '*removable*' -and
        $Disk.MediaType -notlike '*cd*' -and
        $Disk.Model -notlike '*cd*' -and
        ([double]$Disk.Size -gt 0)
    )
}

# --- Partition rendering (mirrors the $partitionInfo block in Get-SystemDisks) ---
function Get-PartitionState {
    param(
        $WmiDisk,
        [array]$WindowsPartitions
    )
    # Critical: prefer Win32_DiskDrive.Partitions (raw partition table count)
    # over Win32_DiskPartition.Count (Windows-recognized only) so Linux/LVM
    # disks aren't silently reported as empty.
    $partitionCount = if ($null -ne $WmiDisk.Partitions) {
        [int]$WmiDisk.Partitions
    } else {
        $WindowsPartitions.Count
    }
    $hasPartitions = $partitionCount -gt 0

    $partitionInfo = if (-not $hasPartitions) {
        "No partitions"
    } elseif ($WindowsPartitions.Count -gt 0) {
        $detail = ($WindowsPartitions | ForEach-Object { "Part$($_.Index):$([Math]::Round([double]$_.Size/1GB,1))GB" }) -join ", "
        if ($partitionCount -gt $WindowsPartitions.Count) {
            "$detail (+$($partitionCount - $WindowsPartitions.Count) non-Windows)"
        } else {
            $detail
        }
    } else {
        "$partitionCount partition(s) (non-Windows - e.g. Linux/LVM)"
    }

    return [PSCustomObject]@{
        HasPartitions  = $hasPartitions
        PartitionCount = $partitionCount
        PartitionInfo  = $partitionInfo
    }
}

# ---------------------------------------------------------------------------
# Filter predicate
# ---------------------------------------------------------------------------

Write-Host "`n--- Disk filter (USB / removable / CD / zero-size excluded) ---" -ForegroundColor Cyan

$diskFixtures = @(
    [PSCustomObject]@{ Label = 'Internal SATA SSD';    InterfaceType='SCSI'; MediaType='Fixed hard disk media'; Model='Samsung SSD 980'; Size=500GB; Expected=$true  },
    [PSCustomObject]@{ Label = 'Internal NVMe';        InterfaceType='SCSI'; MediaType='Fixed hard disk media'; Model='WDC NVMe';        Size=1TB;   Expected=$true  },
    [PSCustomObject]@{ Label = 'USB thumb drive';      InterfaceType='USB';  MediaType='Removable Media';       Model='SanDisk USB';    Size=64GB;  Expected=$false },
    [PSCustomObject]@{ Label = 'USB SATA enclosure';   InterfaceType='USB';  MediaType='Fixed hard disk media'; Model='Seagate Backup'; Size=2TB;   Expected=$false },
    [PSCustomObject]@{ Label = 'SD-card reader';       InterfaceType='SCSI'; MediaType='Removable Media';       Model='Generic SD';     Size=32GB;  Expected=$false },
    [PSCustomObject]@{ Label = 'CD-ROM via MediaType'; InterfaceType='IDE';  MediaType='CD-ROM';                Model='Generic Disc';   Size=700MB; Expected=$false },
    [PSCustomObject]@{ Label = 'DVD via Model';        InterfaceType='SCSI'; MediaType='Format is unknown';     Model='HL-DT-ST DVDRAM';Size=0;     Expected=$false },
    [PSCustomObject]@{ Label = 'Empty card slot';      InterfaceType='SCSI'; MediaType='Fixed hard disk media'; Model='Generic';        Size=0;     Expected=$false }
)

foreach ($d in $diskFixtures) {
    $actual = Test-DiskEligible -Disk $d
    Write-Result -Test "Filter: $($d.Label) -> $([bool]$d.Expected)" -Pass ($actual -eq $d.Expected) `
        -Detail "got=$actual interface=$($d.InterfaceType) media='$($d.MediaType)' model='$($d.Model)' size=$($d.Size)"
}

# ---------------------------------------------------------------------------
# Partition rendering
# ---------------------------------------------------------------------------

Write-Host "`n--- Partition rendering ---" -ForegroundColor Cyan

# 1) Pure Windows disk: every partition is in Win32_DiskPartition.
$winDisk = [PSCustomObject]@{ Index=0; Partitions=2; Size=500GB }
$winParts = @(
    [PSCustomObject]@{ DiskIndex=0; Index=0; Size=314572800    }  # 300 MB EFI
    [PSCustomObject]@{ DiskIndex=0; Index=1; Size=499000000000 }  # ~464 GB primary
)
$s = Get-PartitionState -WmiDisk $winDisk -WindowsPartitions $winParts
Write-Result -Test "Pure Windows disk: HasPartitions=true"  -Pass ($s.HasPartitions -eq $true)
Write-Result -Test "Pure Windows disk: PartitionCount=2"    -Pass ($s.PartitionCount -eq 2) -Detail "got $($s.PartitionCount)"
Write-Result -Test "Pure Windows disk: PartitionInfo has both indexes" `
    -Pass ($s.PartitionInfo -match 'Part0:' -and $s.PartitionInfo -match 'Part1:') `
    -Detail "got '$($s.PartitionInfo)'"
Write-Result -Test "Pure Windows disk: no '+N non-Windows' suffix" `
    -Pass ($s.PartitionInfo -notmatch 'non-Windows') `
    -Detail "got '$($s.PartitionInfo)'"

# 2) Linux/LVM disk: partition table has 3 partitions, Win32_DiskPartition shows 0.
#    This is the safety-critical case — the operator must see this is NOT empty.
$linuxDisk = [PSCustomObject]@{ Index=1; Partitions=3; Size=1TB }
$s = Get-PartitionState -WmiDisk $linuxDisk -WindowsPartitions @()
Write-Result -Test "Linux/LVM disk: HasPartitions=true (NOT silently empty)" `
    -Pass ($s.HasPartitions -eq $true) `
    -Detail "PartitionCount=$($s.PartitionCount), Info='$($s.PartitionInfo)'"
Write-Result -Test "Linux/LVM disk: PartitionCount=3 (from Win32_DiskDrive.Partitions)" `
    -Pass ($s.PartitionCount -eq 3)
Write-Result -Test "Linux/LVM disk: PartitionInfo flags 'non-Windows - e.g. Linux/LVM'" `
    -Pass ($s.PartitionInfo -like '*non-Windows*Linux/LVM*') `
    -Detail "got '$($s.PartitionInfo)'"

# 3) Mixed disk: 5 partitions on the table, only 2 visible to Windows.
$mixedDisk  = [PSCustomObject]@{ Index=2; Partitions=5; Size=2TB }
$mixedParts = @(
    [PSCustomObject]@{ DiskIndex=2; Index=0; Size=314572800    }
    [PSCustomObject]@{ DiskIndex=2; Index=1; Size=200000000000 }
)
$s = Get-PartitionState -WmiDisk $mixedDisk -WindowsPartitions $mixedParts
Write-Result -Test "Mixed disk: PartitionCount=5 (from Win32_DiskDrive.Partitions, not 2)" `
    -Pass ($s.PartitionCount -eq 5) -Detail "got $($s.PartitionCount)"
Write-Result -Test "Mixed disk: PartitionInfo lists Windows parts + '(+3 non-Windows)' suffix" `
    -Pass ($s.PartitionInfo -match 'Part0:' -and $s.PartitionInfo -match '\+3 non-Windows') `
    -Detail "got '$($s.PartitionInfo)'"

# 4) Empty disk: 0 partitions, 0 Windows partitions.
$emptyDisk = [PSCustomObject]@{ Index=3; Partitions=0; Size=500GB }
$s = Get-PartitionState -WmiDisk $emptyDisk -WindowsPartitions @()
Write-Result -Test "Empty disk: HasPartitions=false"       -Pass ($s.HasPartitions -eq $false)
Write-Result -Test "Empty disk: PartitionCount=0"          -Pass ($s.PartitionCount -eq 0)
Write-Result -Test "Empty disk: PartitionInfo='No partitions'" `
    -Pass ($s.PartitionInfo -eq 'No partitions') -Detail "got '$($s.PartitionInfo)'"

# 5) WMI quirk: Win32_DiskDrive.Partitions is $null (older drivers).
#    Must fall back to the Win32_DiskPartition count rather than crashing.
$nullCountDisk  = [PSCustomObject]@{ Index=4; Partitions=$null; Size=500GB }
$nullCountParts = @(
    [PSCustomObject]@{ DiskIndex=4; Index=0; Size=314572800 }
)
$s = Get-PartitionState -WmiDisk $nullCountDisk -WindowsPartitions $nullCountParts
Write-Result -Test "Null Partitions count: falls back to Windows-partition count" `
    -Pass ($s.PartitionCount -eq 1 -and $s.HasPartitions -eq $true) `
    -Detail "PartitionCount=$($s.PartitionCount) HasPartitions=$($s.HasPartitions)"

# ---------------------------------------------------------------------------
# Integration: cross-disk partition isolation and model normalization
# (mirrors the full ConvertTo-DiskRecord loop in Get-SystemDisks)
# ---------------------------------------------------------------------------

Write-Host "`n--- Cross-disk partition isolation ---" -ForegroundColor Cyan

# Partitions for disk 0 must not appear in disk 1's PartitionInfo and vice versa.
$allPartitions = @(
    [PSCustomObject]@{ DiskIndex=0; Index=1; Size=100GB }
    [PSCustomObject]@{ DiskIndex=1; Index=1; Size=200GB }
)
$d0Parts = @($allPartitions | Where-Object { $_.DiskIndex -eq 0 })
$d1Parts = @($allPartitions | Where-Object { $_.DiskIndex -eq 1 })
$s0 = Get-PartitionState -WmiDisk ([PSCustomObject]@{ Index=0; Partitions=1; Size=500GB }) -WindowsPartitions $d0Parts
$s1 = Get-PartitionState -WmiDisk ([PSCustomObject]@{ Index=1; Partitions=1; Size=1TB   }) -WindowsPartitions $d1Parts
Write-Result -Test "Disk 0 only sees its own partition (100 GB)" `
    -Pass ($s0.PartitionInfo -eq 'Part1:100GB') -Detail "got '$($s0.PartitionInfo)'"
Write-Result -Test "Disk 1 only sees its own partition (200 GB)" `
    -Pass ($s1.PartitionInfo -eq 'Part1:200GB') -Detail "got '$($s1.PartitionInfo)'"

Write-Host "`n--- Model string normalization ---" -ForegroundColor Cyan

$padded = [PSCustomObject]@{ InterfaceType='SCSI'; MediaType='Fixed hard disk media'; Model='  Samsung 980 PRO  '; Size=500GB }
$eligible = Test-DiskEligible -Disk $padded
# Filter passes (whitespace in model doesn't break the -notlike '*cd*' check).
Write-Result -Test "Disk with padded model name passes filter" -Pass ($eligible -eq $true)
# Trim is applied at the Get-SystemDisks level; verify the classifier would
# produce a clean value by mimicking the .Trim() call.
$trimmed = $padded.Model.Trim()
Write-Result -Test "Model .Trim() yields clean string" `
    -Pass ($trimmed -eq 'Samsung 980 PRO') -Detail "got '$trimmed'"

# ---------------------------------------------------------------------------
# Drift guard: safety-critical code shapes must still live in the deploy script
# ---------------------------------------------------------------------------

Write-Host "`n--- Drift guard ---" -ForegroundColor Cyan

if (-not (Test-Path $scriptPath)) {
    Write-Result -Test "Deploy script exists at $scriptPath" -Pass $false
} else {
    Write-Result -Test "Deploy script exists" -Pass $true
    $scriptText = Get-Content $scriptPath -Raw

    Write-Result -Test "Win32_DiskDrive.Partitions precedence still present" `
        -Pass ($scriptText -match '\[int\]\$wmiDisk\.Partitions') `
        -Detail 'expected [int]$wmiDisk.Partitions'

    Write-Result -Test "Non-Windows/Linux/LVM warning string still present" `
        -Pass ($scriptText -match 'non-Windows - e\.g\. Linux/LVM') `
        -Detail "expected 'non-Windows - e.g. Linux/LVM' literal"

    Write-Result -Test "'(+N non-Windows)' suffix logic still present" `
        -Pass ($scriptText -match '\(\+\$\(\$partitionCount - \$partitions\.Count\) non-Windows\)') `
        -Detail 'expected the (+$(...) non-Windows) template'

    Write-Result -Test "'No partitions' label still present" `
        -Pass ($scriptText -match '"No partitions"') `
        -Detail "expected double-quoted 'No partitions' literal"

    Write-Result -Test "USB exclusion still present in disk filter" `
        -Pass ($scriptText -match "InterfaceType -ne 'USB'") `
        -Detail "expected InterfaceType -ne 'USB'"

    Write-Result -Test "Removable-media exclusion still present" `
        -Pass ($scriptText -match 'MediaType -notlike "\*removable\*"') `
        -Detail 'expected $_.MediaType -notlike "*removable*"'

    Write-Result -Test "CD exclusion still present on MediaType" `
        -Pass ($scriptText -match 'MediaType -notlike "\*cd\*"') `
        -Detail 'expected MediaType -notlike "*cd*"'

    Write-Result -Test "CD exclusion still present on Model" `
        -Pass ($scriptText -match 'Model -notlike "\*cd\*"') `
        -Detail 'expected Model -notlike "*cd*"'

    # Zero-size clause guards against empty card-reader slots, offline HBA
    # LUNs, and unreadable drives being surfaced as valid deploy targets.
    # A refactor that drops it would let Size=0 disks reach Show-DiskMenu.
    Write-Result -Test "Zero-size exclusion still present in disk filter" `
        -Pass ($scriptText -match '\[double\]\$_\.Size -gt 0') `
        -Detail 'expected [double]$_.Size -gt 0'
}

# --- Summary ---
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "Passed: $passed" -ForegroundColor Green
Write-Host "Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })

if ($failed -gt 0) {
    exit 1
} else {
    Write-Host "`nAll checks passed!" -ForegroundColor Green
    exit 0
}
