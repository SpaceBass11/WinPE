## Summary
<!-- What does this PR change and why? One paragraph. -->

## Type of change
- [ ] Script fix or improvement (`ManualClonezilla/Scripts/`)
- [ ] Configuration change (`ManualClonezilla/Config/` or `configs/`)
- [ ] Documentation update (`docs/`)
- [ ] CI / tooling

## Testing
<!-- How did you test this? -->
- [ ] PowerShell syntax check: `pwsh -NoProfile -Command "[System.Management.Automation.PSParser]::Tokenize((Get-Content ManualClonezilla/Scripts/<file>.ps1 -Raw), [ref]\$null)"`
- [ ] Bench-tested on a sysprep VM with virtual TPM (for BitLocker changes)
- [ ] Validated on hardware (describe model + BIOS version below)
- [ ] CI masterize checks pass locally (the grep block from `.github/workflows/ci.yml`)

## Checklist
- [ ] No CCTK binaries or vendor DLLs committed
- [ ] No plaintext PIN, recovery key, or BIOS password committed
- [ ] CHANGELOG.md updated under `[Unreleased]`
- [ ] Docs updated if behavior or staging paths changed
