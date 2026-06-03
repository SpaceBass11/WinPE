# Installers

Third-party installers staged for the build. These binaries are **not**
committed (they are git-ignored); drop the real files here before sysprep so
the whole `ManualClonezilla\` tree can be copied straight to
`C:\ProgramData\ManualClonezilla\` on the gold image.

| File | Consumed by | Notes |
|------|-------------|-------|
| `npp-installer.exe` | `Scripts\Install-NotepadPP.ps1` (via `Apply-GoldHardening.ps1`) | Notepad++ silent (`/S`) installer. Run in the **gold**, before sysprep; the install is **non-fatal** so a missing or failing installer never aborts the hardening run. |

See `docs/RUNBOOK.md` for the full staging sequence.
