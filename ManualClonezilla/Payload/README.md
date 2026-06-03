# Payload

Large staged data files consumed at first boot. These are **not** committed
(git-ignored, e.g. `*.vhdx`); drop the real files here before sysprep so the
whole `ManualClonezilla\` tree can be copied straight to
`C:\ProgramData\ManualClonezilla\` on the gold image.

| File | Consumed by | Notes |
|------|-------------|-------|
| `docker_data.vhdx` | `Scripts\Stage-DockerData.ps1` | Docker Desktop WSL data disk seeded into the `Level 1` profile. Staging is **non-fatal** and no-ops if the file is absent. `Finalize-Cleanup` reclaims it only after a successful stage (multi-GB, not a secret). |

See `docs/RUNBOOK.md` for the full staging sequence.
