# WinPE Universal Deployment Toolkit

A safety-first PowerShell deployment workflow for imaging Windows from WinPE.

## What this project provides

- A single deployment script: `unified_winpe_deploy.ps1`
- Safe, explicit disk destruction confirmations before imaging
- Automatic image discovery (`.wim`, `.esd`) for ad-hoc usage
- Optional **manifest mode** for repeatable task-based deployments

## Quick start

### 1) Ad-hoc image deployment

```powershell
.\unified_winpe_deploy.ps1
```

Optional shortcuts:

```powershell
.\unified_winpe_deploy.ps1 -WimFile "D:\wim\win11.wim" -TargetDisk 0
.\unified_winpe_deploy.ps1 -ImagePath "D:\images"
.\unified_winpe_deploy.ps1 -ListOnly
```

### 2) Manifest-driven deployment

```powershell
.\unified_winpe_deploy.ps1 -ManifestFile ".\examples\manifest.sample.json"
```

List manifest tasks only:

```powershell
.\unified_winpe_deploy.ps1 -ManifestFile ".\examples\manifest.sample.json" -ListTasks
```

Run a specific task:

```powershell
.\unified_winpe_deploy.ps1 -ManifestFile ".\examples\manifest.sample.json" -TaskName "Win11-Standard"
```

## Repository layout

- `unified_winpe_deploy.ps1` – main deploy script
- `docs/` – architecture and operations notes
- `examples/` – sample manifest and layout guidance

## Safety model

This script is destructive by design when imaging:

- It prompts with strong warnings before wiping selected disks.
- It requires explicit confirmation text for destructive actions.
- It supports specifying `-TargetDisk` but still validates selection.

## Documentation

- [Architecture overview](docs/ARCHITECTURE.md)
- [Manifest mode guide](docs/MANIFEST_MODE.md)
- [Project roadmap](docs/ROADMAP.md)

## Future enhancements

See [ROADMAP](docs/ROADMAP.md) for staged feature evolution (drivers, unattend, optional capture mode, and policy controls).
