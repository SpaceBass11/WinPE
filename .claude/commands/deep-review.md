Run a multi-angle deep review of unified_winpe_deploy.ps1 and docs. Use parallel agents for each analysis pass, then fix everything found.

## Phase 1: Research (run ALL of these in parallel as separate agents)

### Agent 1: Execution Path Trace
For each function in unified_winpe_deploy.ps1, trace what happens with: empty arrays, null paths, missing disks, failed external commands (diskpart, dism, bcdboot). Only list things that would cause wrong behavior or silent failures — no style issues.

### Agent 2: Adversarial User Input
Imagine a user who types wrong things at every Read-Host prompt: empty strings, spaces, negative numbers, special characters, paths with spaces and quotes. Trace what each Read-Host and parameter input does with garbage input. Only report inputs that cause crashes, hangs, or bypass safety checks.

### Agent 3: Environment Mismatch
This script is meant for WinPE. List every assumption it makes about the environment (available commands, drive letters, PowerShell version, loaded modules, registry state) and identify which assumptions would break on: (a) a minimal WinPE build missing optional packages, (b) a full Windows desktop after CONTINUE ANYWAY, (c) Windows Server Core.

### Agent 4: Docs vs Code Drift
Compare every claim in CLAUDE.md, SCRIPT_REFERENCE.md, USB_SETUP.md, and README.md against the actual code in unified_winpe_deploy.ps1. List every mismatch: parameters that exist in docs but not code, features described differently, version numbers, file paths, command syntax that doesn't match.

### Agent 5: Safety Audit
You are a QA tester trying to destroy data on the wrong disk. Find every combination of parameters (-Force, -Silent, -TargetDisk, -ListOnly) and user inputs that could bypass safety confirmations or wipe an unintended disk. Map every code path from parameter input to diskpart execution.

### Agent 6: Workflow End-to-End
Walk through the complete USB creation workflow in USB_SETUP.md from a fresh Windows machine. At each step, what can go wrong? What if the user has a different ADK version, different USB hardware, or does steps out of order?

### Agent 7: PowerShell Gotchas
Read the script as a PowerShell language expert. Find: single-element array unwrapping, $null vs empty array differences, string comparison case sensitivity, pipeline behavior with zero/single/multiple items, -match vs -eq on collections, and any place where PowerShell's implicit type coercion produces wrong results.

## Phase 2: Fix

After all agents report back:
1. Compile findings into a single prioritized list (bugs first, then safety, then workflow, then docs)
2. Remove duplicates across agents
3. Discard style-only issues
4. Fix every real bug and safety issue found
5. Update any stale docs
6. Run syntax validation after all changes
7. Commit with a clear summary of what was fixed and which analysis pass found it
