# Claude Routine Maintenance Log

Lightweight, one-entry-per-run log so the autonomous maintenance agent
doesn't keep re-investigating the same areas. Newest entries on top.

---

## 2026-05-16 — Expand DISM exit-code recovery guidance

**Investigated:** Both prior maintenance entries (the two open PRs that
preceded this one) flagged the same next item: `Apply-WindowsImage`
had bespoke recovery guidance only for DISM exit code 1. Every other
non-zero exit got the bare line "DISM failed with exit code N" and
nothing else. `docs/TROUBLESHOOTING.md` already documents meanings for
codes 1, 2, 11, 87, 112, 1168, 1392 in its DISM-error table, so the
script was lagging behind the docs.

**Changed:**

- `unified_winpe_deploy.ps1` — replaced the single `if ($process.ExitCode
  -eq 1)` block in `Apply-WindowsImage` with a `switch` that covers exit
  codes 1, 2, 11, 50, 87, 112, 1168, 1392, plus a `default` arm that
  points the operator at `docs/TROUBLESHOOTING.md` and `dism.log`. The
  exit-1 branch keeps its existing five-step recovery list verbatim;
  every other branch is purely additive (where previously nothing was
  printed). `$dismLog` is now declared once at the top of the block so
  every arm can reference it.
- `docs/TROUBLESHOOTING.md` — added a row for exit code 50 (Request not
  supported) to the DISM-error table. The script will now surface this
  code by name, so the docs table should list it too.

**Verification:**

- Brace count on `unified_winpe_deploy.ps1` after edits: 327 open / 327
  close (matches Test 3 in `tests/test_parse.ps1`).
- Region count: 10 `#region` / 10 `#endregion` (matches Test 4).
- Diff brace delta: `+9 {` / `+9 }` net — balanced.
- Visual inspection of lines 1029-1121: `try { ... switch { ... } ...
  return $false } catch { ... }` is correctly nested; surrounding
  `Set-BootConfiguration` and the `#endregion` at 1141 are unchanged.
- Pure additive operator-facing logging — no destructive code paths
  touched, no change to the success path (`return $true` at line 1051)
  or to the existing failure return (`return $false` at line 1116).
- `pwsh` is not installed in this Linux session, so `tests/test_parse.ps1`
  can't run locally — same constraint flagged in the deep-review's
  Validation Notes and the two prior routine entries. CI's `syntax` job
  on `windows-latest` runs the real `PSParser::Tokenize` on push.

**Risks:**

- Minimal. Only `Write-Log` calls were added inside an existing
  function; no new behavior, no new branches in destructive code
  (diskpart, DISM args, BCDBoot), no new parameters.
- The `switch` matches on `$process.ExitCode`, which is an `int`; the
  numeric arms are integer literals. No type-coercion edge case.

**Next recommended improvement:**

- A fixture test for `Get-SystemDisks` partition enumeration (called out
  as a less-urgent follow-up in PR #24's body). It would guard against
  regressions in the Linux/LVM-disk-as-empty mitigation.
- The BCDBoot failure path at line 1133 only logs `exit code N`. A
  similar small expansion (the common BCDBoot failures are EFI partition
  not S:, target not bootable, and `bcdboot.exe` missing from PATH) would
  bring it to parity with the DISM block.
- The two prior open PRs (#23 log-path reminder, #24 WIM parser test)
  both add `docs/claude-routine-log.md`. Whichever PR merges second
  needs a trivial rebase that keeps all three entries in time order.
