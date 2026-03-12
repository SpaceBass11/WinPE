# Architecture

## Design goals

1. Keep ad-hoc WinPE imaging simple and reliable.
2. Preserve strong operator safety checks before destructive operations.
3. Add optional manifest-driven orchestration without breaking current usage.

## Runtime modes

### Standard discovery mode

Activated when `-ManifestFile` is not provided.

Flow:

1. Discover image files (`.wim`, `.esd`) using either:
   - direct `-WimFile`
   - targeted `-ImagePath`
   - automatic drive scanning
2. Let operator select an image.
3. Validate environment and memory.
4. Let operator select target disk with explicit destructive confirmations.
5. Partition disk (UEFI/GPT default layout), apply image with DISM, run BCDBoot.

### Manifest mode

Activated when `-ManifestFile` is provided.

Flow:

1. Parse JSON manifest and validate required `tasks` node.
2. Select task from:
   - explicit `-TaskName`, or
   - interactive menu (with model-based recommendations if available)
3. Resolve image path from task `wim` value:
   - absolute or relative path
   - fallback lookup in manifest-dir `wim/` folder
4. Continue through same deployment pipeline as standard mode.

## Key principles

- **Safety first**: destructive operations remain interactive and explicit.
- **Backward compatibility**: existing command usage still works unchanged.
- **Single engine**: both modes converge on one deployment path.

