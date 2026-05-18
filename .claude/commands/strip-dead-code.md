Read all scripts in scripts/mdt/ completely (Initialize-MDTDeploymentShare.ps1, Import-WimImages.ps1, New-MDTMedia.ps1, Enable-BitLocker.ps1). Find and remove:

1. **Commented-out code blocks** — blocks of code that have been disabled with `#` but are not explanatory comments (e.g., an old implementation left behind)
2. **Unused parameters** — parameters declared in a `param()` block but never referenced in the script body
3. **Dead variables** — variables assigned a value that is never subsequently read
4. **Unreachable branches** — `if`/`else` conditions that can never be true given the script's logic or surrounding guards
5. **Uncalled helper functions** — functions defined in the script but never invoked anywhere in the same file

For each finding, explain WHY it is dead or unreachable (show the execution path or logic that proves it).

Do NOT remove:
- Intentional no-ops or placeholder stubs
- Safety guards and idempotency checks (e.g., `if (-not (Test-Path ...))`)
- Comments that explain why something is done, not what is done
- `#Requires` directives

After removing dead code, run `pwsh -NoProfile -File ./tests/test_parse.ps1` to confirm syntax is clean.
