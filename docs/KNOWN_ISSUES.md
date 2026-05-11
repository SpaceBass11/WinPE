# Known Issues & Audit Findings

Current status for `unified_winpe_deploy.ps1` (v4.6.0), `scripts/prepare_wim.ps1`, and `scripts/build_boot_wim.ps1`.

## Active Warnings

### 1. PowerShell runtime availability in CI/dev containers
- **Impact:** Repo validation scripts (`tests/test_parse.ps1`, `scripts/validate_script.ps1`) require `pwsh` and cannot run in environments where PowerShell is absent.
- **Workaround:** Run validation from WinPE/Windows or any runner with PowerShell installed.

### 2. USB disks are intentionally excluded from target list
- **Impact:** External USB SSD/HDD targets cannot be selected by default — this also means USB disks can never be picked as additional-wipe targets in the multi-disk wipe stage.
- **Assessment:** Safety-first behavior to avoid wiping the deployment USB itself.

### 3. 100MB discovery filter hides tiny lab images
- **Impact:** Very small test WIM/ESD files (<100MB) are skipped during auto-discovery.
- **Assessment:** Intentional to avoid accidental selection of boot/system artifacts.

### 4. build_boot_wim.ps1 assumes default ADK install path
- **Impact:** Builder throws if the Windows ADK + WinPE add-on is installed somewhere other than `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit`.
- **Workaround:** Pass `-AdkPath` with the correct root.

### 5. Capture commands in USB_SETUP.md assume default capabilities
- **Impact:** The `Dism /Capture-Image` examples use `/Compress:max` and `/CheckIntegrity /verify`. `/verify` re-reads every file — capture is slower but catches bad source reads at capture time. ESD-style `/compress:recovery` is intentionally not used for master images because it doesn't support `/CheckIntegrity`.

### 6. CCTK passwords sit in plaintext on the IMAGES partition
- **Impact:** Anyone with physical access to the USB can read setup/system passwords from `<IMAGES>\cctk\*.ini`.
- **Assessment:** Inherent to unattended WinPE flows — no cryptographic protection is possible without runtime input. Mitigation is physical security of the USB and rotating BIOS passwords post-deploy. See `docs/CCTK.md`.

### 7. CCTK is not redistributable
- **Impact:** Dell's EULA for Command | Configure does not allow shipping `cctk.exe` or HAPI driver in this repo. The repo never ships CCTK; users supply their own via `-CctkSource` on the builder.
- **Workaround:** Install Dell Command | Configure on your admin workstation, point `-CctkSource` at it. `.gitignore` blocks accidental commits (`cctk.exe`, `hapint*.inf/.sys`, `/vendor/`, `/cctk-source/`).

## Recently Fixed

### G. Dell CCTK pre-apply BIOS configuration (v4.5.0)
- **Change:** Builder gains `-CctkSource` to embed CCTK + HAPI driver into `boot.wim`. Deploy script runs `cctk --infile=<config>` before disk selection, picking from `<IMAGES>\cctk\` by service tag → model → `default.ini` precedence. Non-zero CCTK exit aborts the deploy.
- **Benefit:** Fresh Dell hardware (RAID-by-default, no setup password) can be flipped to AHCI + passwords + boot order in the same pass that applies Windows. One reboot at the end activates BIOS and first-boots the new OS together. See `docs/CCTK.md`.

### H. Multi-disk wipe stage (v4.5.0)
- **Change:** After the primary target is confirmed, an optional menu lists remaining non-USB fixed disks. User enters comma-separated numbers; a single `WIPE ALL` confirmation covers the whole set. Each gets a `diskpart clean` (no repartition) before the primary deploy, in the same diskpart session. New `-WipeDisks "1,2"` for silent automation.
- **Benefit:** Fixes the "vendor OEM appeared as D: on the second NVMe" problem without a separate WinPE round-trip.

### A. Silent unattended safety contract tightened
- **Change:** `-Silent` deployment runs now require `-WimFile`, `-TargetDisk`, and `-Force` (unless using `-ListOnly`).
- **Benefit:** Prevents unexpected interactive prompts during automation.

### B. Direct image path validation improved
- **Change:** `-WimFile` now validates that the file exists and has a supported extension (`.wim`/`.esd`).
- **Benefit:** Fails fast on invalid inputs instead of attempting downstream operations.

### C. Diskpart resilience: `attributes disk clear readonly` now uses `noerr` (v4.4.0)
- **Change:** If clearing the disk's read-only attribute fails (common on some hardware, exit code `-2147211247` / `0x80042811`), diskpart now proceeds to `clean` instead of aborting.
- **Benefit:** Deploys succeed on hardware where the read-only flag can't be cleared but `clean` still works. Added targeted guidance for disks where both steps fail (physical write-protect, firmware/SED locks).

### D. Non-Windows (Linux/LVM) partitions now detected in disk menu (v4.4.0)
- **Change:** `Get-SystemDisks` now uses `Win32_DiskDrive.Partitions` (raw partition-table count) instead of relying on `Win32_DiskPartition`, which silently omits Linux ext/xfs/LVM partitions.
- **Benefit:** Disks with RHEL/Ubuntu/LVM installs correctly show as `[HAS DATA - WILL BE ERASED!]` instead of misleadingly appearing as "No partitions".

### E. DISM apply now runs with `/CheckIntegrity` + exit-1 guidance (v4.4.0)
- **Change:** `dism /apply-image` adds `/CheckIntegrity`, surfacing WIM corruption up front with a clear error rather than cryptic mid-apply "Incorrect function" messages. On exit code 1, the script now emits targeted recovery steps (verify WIM, re-copy from source, try different USB port, `/NoRpFix` fallback).

### F. Reproducible boot.wim builder added (v4.4.0)
- **Change:** `scripts/build_boot_wim.ps1` automates `copype` → component install → `NtfsEnableDirCaseSensitivity` registry tweak → embed deploy script → `startnet.cmd` → commit.
- **Benefit:** Any contributor can rebuild a compatible boot.wim from source. The `NtfsEnableDirCaseSensitivity` tweak is the fix for the DISM apply "Incorrect function" failure at ~19% on images containing Windows Containers / Hyper-V layer files.

## Notes

- `Get-WmiObject` remains in use intentionally for WinPE/PowerShell 5.1 compatibility.
- File logging is implemented and enabled (deployment logs are written to the active temp path).
- The builder's component list (`$Components` at the top of `build_boot_wim.ps1`) and registry tweaks (`$RegTweaks`) are the only places to update if new WinPE capabilities are needed in the future.
