# Visual Assets

This folder adds clean SVG documentation images for the WinPE deployment repo.

These are text-based SVG files so they stay lightweight, source-controlled, diffable, and easy to revise. They are meant to help users understand the repo before reading long command blocks.

## Asset catalog

| Asset | Purpose | Best placement |
|---|---|---|
| `docs/assets/winpe-tool-hero.svg` | Repository hero / overview graphic | Top of `README.md`, after badges and safety warnings |
| `docs/assets/three-loop-workflow.svg` | Shows Loop A/B/C deployment cadence | `README.md` → Workflow Overview |
| `docs/assets/usb-layout.svg` | Explains the dual-partition USB layout | `README.md` → USB Drive Layout; `docs/USB_SETUP.md` before partitioning |
| `docs/assets/runtime-data-flow.svg` | Explains boot-to-deploy runtime flow | `docs/ARCHITECTURE.md` → Runtime Data Flow |
| `docs/assets/target-disk-layout.svg` | Shows GPT/UEFI target disk partitions | `README.md` → Disk Partition Layout on Target |
| `docs/assets/safety-confirmation-chain.svg` | Explains destructive typed confirmations | `README.md` → Safety Features; `docs/ARCHITECTURE.md` → Safety Model |
| `docs/assets/bitlocker-first-boot-flow.svg` | Shows SetupComplete/BitLocker/escrow behavior | `docs/BITLOCKER.md` → How the first-boot stage works |
| `docs/assets/end-user-rufus-flow.svg` | Plain-English ISO-to-Rufus-to-USB user flow | `docs/END_USER_DEPLOY.md`, near the top |
| `docs/assets/winpe-tui-mockup.svg` | Synthetic operator console preview | `README.md` → Loop C or `docs/SCRIPT_REFERENCE.md` |

## Suggested Markdown inserts

### README hero

```md
<p align="center">
  <img src="docs/assets/winpe-tool-hero.svg" alt="WinPE Image Deployment Tool overview" width="100%">
</p>
```

### Workflow Overview

```md
![Three-loop WinPE deployment workflow](docs/assets/three-loop-workflow.svg)
```

### USB Drive Layout

```md
![Dual-partition WinPE USB layout](docs/assets/usb-layout.svg)
```

### Runtime Data Flow in `docs/ARCHITECTURE.md`

```md
![WinPE runtime data flow](assets/runtime-data-flow.svg)
```

### Target Disk Layout

```md
![Target disk GPT UEFI partition layout](docs/assets/target-disk-layout.svg)
```

### Safety Features

```md
![Typed confirmation safety chain](docs/assets/safety-confirmation-chain.svg)
```

### BitLocker guide

```md
![BitLocker first-boot flow and recovery-key escrow paths](assets/bitlocker-first-boot-flow.svg)
```

### End-user deploy guide

```md
![End-user ISO to Rufus to USB deployment flow](assets/end-user-rufus-flow.svg)
```

### TUI mockup

```md
![Synthetic WinPE TUI mockup](docs/assets/winpe-tui-mockup.svg)
```

## Accuracy note

`winpe-tui-mockup.svg` is a synthetic visual mockup, not a captured production screenshot. Label it that way anywhere it is used.
