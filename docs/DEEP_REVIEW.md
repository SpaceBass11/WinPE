# Deep Review Report (Workflow + Environment + Failure Tracing)

## Scope
- Primary script: `unified_winpe_deploy.ps1`.
- Review method: used the project’s documented `/review` checklist from `CLAUDE.md` and then manually traced every function for edge cases and external-command failures.
- Focus filter: **only wrong behavior or silent-failure risks** (no style/commentary items).

## Workflow Check
- The implementation in `Start-Deployment` follows the documented workflow sequence: admin check, path initialization, image discovery/selection, WIM index selection, environment + memory checks, disk selection, size validation, diskpart, image apply, verification, and bcdboot.
- Recovery guidance is present for DISM apply failures and BCDBoot failures.

### Workflow findings
1. **`-ListOnly` returns success even when no images are found**
   - Path: `Start-Deployment`.
   - Behavior: in `-ListOnly`, the script runs `Show-ImageSelection` and unconditionally returns `$true`; if no images are found, `Show-ImageSelection` logs error and returns `$null`, but exit code is still success.
   - Impact: automation can treat "no images found" as success.

2. **WIM index enumeration failure can silently deploy the wrong edition/index**
   - Path: `Get-WimImageInfo` + `Select-ImageIndex`.
   - Behavior: if `dism /Get-WimInfo` fails, indexes are empty and the flow defaults to index `1` (in silent mode, no prompt).
   - Impact: wrong edition (or even recovery index in `.esd`) can be deployed while workflow still "succeeds."

## Environment Check
Commands run:
- `uname -a`
- `bash --version | head -n 1`
- `git --version`
- `which pwsh || true`
- `which powershell || true`
- `pwsh -NoProfile -Command "& ./tests/test_parse.ps1"`

Results:
- Linux container, bash and git available.
- PowerShell (`pwsh`/`powershell`) is not installed in this environment.
- Script-native PowerShell validations cannot be executed here.

## Function-by-function failure tracing (only wrong/silent issues)

### Core Functions
- `Write-Log`
  - **Silent failure risk:** file logging failures are intentionally swallowed (`catch { }`), so log persistence can fail without a visible warning.
- `Write-Banner`
  - No wrong-behavior issue found for requested edge cases.
- `Test-Administrator`
  - No wrong-behavior issue found for requested edge cases.
- `Show-MessageBox`
  - No wrong-behavior issue found for requested edge cases.

### System Discovery
- `Initialize-SystemPaths`
  - No wrong-behavior issue found for requested edge cases.
- `Find-ImageFiles`
  - No wrong-behavior issue found for empty arrays/null paths; returns empty array on missing path/file.
- `Search-DirectoryForImages`
  - No wrong-behavior issue found for requested edge cases.
- `Show-ImageSelection`
  - No function-local silent failure; returns `$null` on empty list as expected.

### System Validation
- `Test-WinPEEnvironment`
  - No wrong-behavior issue found for requested edge cases.
- `Test-SystemMemory`
  - No wrong-behavior issue found for requested edge cases.

### Disk Management
- `Get-SystemDisks`
  - Potential wrong behavior: relies on `MediaType -like "*fixed*"`; if WinPE returns blank/unexpected media types for internal disks, valid target disks can be omitted.
- `Show-DiskMenu`
  - No wrong-behavior issue found for requested edge cases.
- `Select-TargetDisk`
  - No wrong-behavior issue found for missing/invalid selected disk (it fails safely with `$null`).

### Image Index Selection
- `Get-WimImageInfo`
  - External command failure (`dism /Get-WimInfo`) is converted to empty index set.
  - Combined with `Select-ImageIndex`, this enables default-to-index-1 behavior.
- `Select-ImageIndex`
  - **Wrong behavior risk:** empty index list defaults to `1`; this can silently choose wrong image in silent deployments.

### Image Deployment
- `New-DiskpartScript`
  - No wrong-behavior issue found for requested edge cases.
- `Invoke-Diskpart`
  - External command failures are handled via exit code and catch.
  - Partial diskpart-success scenarios are mitigated later by explicit S:/C: verification in `Start-Deployment`.
- `Apply-WindowsImage`
  - External DISM failures handled by exit code/catch and abort.
- `Set-BootConfiguration`
  - External BCDBoot failures handled by exit code/catch and abort.

### Main Orchestrator
- `Start-Deployment`
  - Contains the two workflow-level wrong-behavior findings above:
    1) `-ListOnly` success on empty image set.
    2) default-to-index-1 path after WIM metadata failure.

## External command failure summary
- `diskpart`: hard failure handled; plus post-check verifies `S:` and `C:`.
- `dism /apply-image`: hard failure handled and recovery guidance shown.
- `bcdboot`: hard failure handled and recovery guidance shown.
- `dism /Get-WimInfo`: failure currently degrades to default index 1, which can cause wrong deployment target.


## Remediation updates
The following issues from this review have now been fixed in `unified_winpe_deploy.ps1`:
- `-ListOnly` now returns failure when no images are discovered.
- Empty WIM index enumeration no longer defaults to index `1`; deployment now stops to avoid wrong-edition installs.
- Disk enumeration now accepts non-USB disks with blank/unknown `MediaType` metadata, reducing false omissions.
- `Write-Log` now emits a visible warning if file append fails, avoiding silent log-loss.


## Phase 2 deep-dive findings and fixes
Additional deep-dive review identified and fixed these behavior bugs:
- `Write-Log` previously used `Add-Content -ErrorAction SilentlyContinue`, which could suppress append errors and bypass the warning path. It now uses `-ErrorAction Stop` so failures are surfaced once.
- `-ListOnly` previously called interactive selection UI (`Show-ImageSelection`), causing an unexpected prompt when multiple images existed. It now uses non-interactive `Show-ImageList`.
- `Invoke-Diskpart` now captures both stdout and stderr logs so error-only output is not missed during failure diagnosis.


## Phase 3 deep-dive findings and fixes
- `Get-SystemDisks` previously relied on `MediaType` matching `*fixed*`, which can omit valid internal drives in some WinPE/WMI variants (for example `Unspecified` media labels). Filtering now excludes USB/removable media and keeps non-USB disks with non-zero size.
- GPT failure guidance now explicitly mentions clearing read-only disk attributes before `clean/convert gpt`, improving recovery for error `-2147024809` scenarios.
