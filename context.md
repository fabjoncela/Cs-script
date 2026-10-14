# CafeLauncher — Codex Project Context

This file gives Codex and maintainers the operational context needed to work safely in this repository. **Always follow the checked-out source tree.** The generated state block below reports the launcher release marker, not whether that code has shipped to `main`.

<!-- BEGIN GENERATED LAUNCHER STATE -->
- Launcher release: `2026.10.14.4`
- Generated from the unique `# CAFE_RELEASE` marker in `cafe.bat` by `tools/Update-Context.ps1`.
<!-- END GENERATED LAUNCHER STATE -->

## Branch and shipping rules

- Check `git status --short --branch`, `git branch -vv`, and `git diff` before editing. Preserve unrelated user files and changes; never use `git reset --hard` or `git clean`.
- `main` is the production source. A `codex/*`, `feature/*`, or other non-main branch is testing/development until merged. A feature present in a testing branch is **not** shipped just because it is documented here or pushed to GitHub.
- Describe behavior from the current checkout. When discussing release status, compare the current branch with `origin/main`; do not infer production behavior from branch-local code.
- Keep `context.md` useful on both branches: it describes architecture and branch-aware rules rather than claiming every checked-out change is deployed.
- The local Git hooks refresh the generated release block before commit, merge commit, and push. If refresh changes `context.md`, the attempted operation stops so the file can be reviewed and committed. CI also checks that the generated block matches `cafe.bat`.
- For a new clone, run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Install-GitHooks.ps1` once to enable the repository hooks. GitHub Actions checks context freshness even when a merge is performed on GitHub.

## What this project is

CafeLauncher is a portable Windows internet-café setup launcher. The hybrid `cafe.bat` contains the PowerShell/WinForms app, profile actions, and embedded C# display/NVIDIA interop. `graphics/ApplyGraphics.ps1` is a separately hash-pinned module for editing the active Steam account's CS2 video settings. There is no compiled application build step.

Main project files:

- `AGENTS.md` — entry-point instructions Codex automatically reads; directs it to this context file.
- `cafe.bat` — launcher UI, profile persistence and sync, Windows/NVIDIA operations, module loader.
- `profiles/<ProfileName>.json` — cloud profile preferences.
- `graphics/<ProfileName>.json` — canonical CS2 graphics presets; each profile has its own file.
- `graphics/ApplyGraphics.ps1` — validated CS2 video settings editor and backup/replace logic.
- `tools/Test-*.ps1` — Windows PowerShell 5.1 tests, mostly fixture or mock based.
- `.github/workflows/cafe-syntax.yml` — Windows PowerShell validation in CI.

## Profile editor and CS2 graphics UI

`Show-ProfileEditor` contains one tab control. The existing **CS2 / Apps** tab contains CFG sensitivity/URL, app launch options, and per-profile CS2 graphics controls for:

- CS2 resolution width and height, aspect ratio, fullscreen/windowed mode.
- Highest supported refresh or a user-selected exact Hz.
- NVIDIA scaling: stretch to fill, preserve aspect ratio, or center without scaling.
- MSAA, shadows, textures, shaders, particles, ambient occlusion, HDR, Reflex, texture filtering, FSR, VSync, and CMAA.

Each profile's canonical preset is stored independently in `graphics/<ProfileName>.json` (`FabMode`, `ArliMode`, `ArmlMode`, `OliMode`, and `BrileMode`). The editor validates and displays the selected profile's file; Apply Graphics validates that same profile name before using its settings. FabMode, ArliMode, ArmlMode, and OliMode currently use 1280×960 4:3 fullscreen defaults. BrileMode uses 1920×1080 16:9 fullscreen. Presets request the highest advertised refresh for the selected CS2 resolution; a saved 360 Hz value is not treated as proof the monitor supports 360 Hz.

The editor can copy only the CS2 graphics fields from another profile, or reset the current editor values from that profile's canonical preset. These actions do not save automatically. Apply Graphics reports confirmed/applied fields, changed fields, skipped fields, display-mode fallback details, NVIDIA scaling verification, and the backup path. A partial result is presented as a warning rather than unconditional success.

The CS2 / Apps editor can load the three previous versions of `graphics/<ProfileName>.json` from GitHub commit history. The commit list is cached per profile for 24 hours; manual refresh bypasses the cache. Restoring fetches the selected file version over the internet, validates it, and fills the editor without saving or applying it. Saving or syncing remains a separate user action. History is not available offline unless it is already listed in the fresh cache; fetching an older preset still requires internet.

Dashboard **Apply Graphics** is a separate action from the normal profile Apply and **Play + Exec** buttons. Saving in the editor does not apply the settings immediately.

### Local and GitHub persistence

- **Save Locally** writes the profile settings and `GraphicsSettings` snapshot to `%LOCALAPPDATA%\CafeLauncher\profiles.json`, and marks that profile `SyncPending`.
- **Apply Graphics** uses a validated pending local `GraphicsSettings` preset first, including while offline. This prevents a cloud fetch from overwriting unsynced edits.
- **Save & Sync to GitHub** confirms the destination, then updates `profiles/<ProfileName>.json` and `graphics/<ProfileName>.json`. If sensitivity is nonblank, it may update only the matching CFG's sensitivity command; other binds and commands are preserved.
- A partial upload reports the files confirmed saved and the files not confirmed. Local settings remain pending until the entire sync succeeds.
- GitHub profile reads and the sync target are configured in `cafe.bat` (`$script:GithubBranch`). Check this before any claim about which remote branch receives profile data.

## Runtime behavior and safety boundaries

- Startup PC detection is informational. It must not change monitor settings.
- A normal profile Apply refreshes public profile values unless the profile has pending local edits, then applies mouse/NVIDIA settings, installs its CFG, and optionally launches configured apps. It does not start CS2 or write persistent Steam launch options.
- Run summaries report total SUCCESS/PARTIAL/SKIPPED/FAILED/PENDING counts. For each partial, failed, or pending step, they also repeat the step name, recorded detail, and a step-specific next action in LIVE LOGS and the status line.
- **Play + Exec** installs the selected CFG and requests a one-time Steam launch argument. It does not persist launch options or apply mouse/display settings.
- **Apply Graphics** requires CS2 to be closed, detects the active Steam account at the write boundary, changes only recognized keys in that account's `cs2_video.txt`, backs up before replacing, verifies the result, and restores on failure where possible.
- The CS2 refresh choice applies to the selected **game resolution**, independently of Windows desktop resolution. `Highest` chooses the highest advertised progressive rate for that resolution. `Exact` applies only if the exact resolution/Hz is advertised; otherwise it preserves existing display values and reports why.
- NVIDIA scaling and display writes depend on the connected display, driver, NVAPI availability, permissions, and hardware. Tests do not prove live hardware behavior. Do not perform live mouse, DPI, display, or other device writes as a test without user authorization.
- Never store GitHub tokens in files, logs, or profile JSON. Do not enter a token on a shared café PC.

## Editing rules

1. Inspect the current branch, status, relevant functions, and applicable tests before changing code.
2. Keep edits scoped; preserve untracked personal folders and files.
3. If editing `graphics/ApplyGraphics.ps1`, recompute the Git blob SHA used by `Invoke-GraphicsOnly` in `cafe.bat` and bump the BAT release marker.
4. Keep `cafe.bat` Windows CRLF. `tools/Test-CafeLauncher.ps1` checks line endings and parses the embedded PowerShell with Windows PowerShell 5.1.
5. Update this context when architecture, UI, persistence, safety boundaries, or test workflows change. The generated block only tracks the release marker; it cannot infer semantic code changes.
6. Do not push, merge, or change remote profile data unless the user requested that action. Profile **Save & Sync** is separately user-confirmed in the app.

## Verification

Run from the repository root in Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-CafeLauncher.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-ProfileSave.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-CfgSensitivitySync.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-Graphics.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-GraphicsHistory.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-NvidiaCompatibility.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-SteamLaunchOptions.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-StepResults.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Update-Context.ps1 -Check
```

These checks cover parser/formatting, mocked persistence and GitHub sync, graphics fixtures, read-only NVIDIA inventory, mocked Steam launch arguments, and status reporting. A real CS2/Steam account and monitor smoke test is still separate.
