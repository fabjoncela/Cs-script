# CafeLauncher — Technical Context

Maintainer / coding-assistant reference for [CafeLauncher](./README.md). This document reflects the `main` implementation of `cafe.bat` at **2026.10.13.11**. Read the actual source before editing; code is the ultimate source of truth.

## Repository structure

```text
cafe.bat                       Hybrid CMD + PowerShell GUI and all runtime logic
fab.cfg, arli.cfg, brile.cfg,
arml.cfg, oli.cfg              Independently managed, public CS2 config sources
profiles/
  FabMode.json                  Public cloud profile preference data
  ArliMode.json
  BrileMode.json
  ArmlMode.json
  OliMode.json
tools/
  Test-CafeLauncher.ps1         BAT formatting / PowerShell parser checks
  Test-ProfileSave.ps1          Profile-save regression smoke test
.github/workflows/
  cafe-syntax.yml               Windows PowerShell 5.1 Actions workflow
.gitattributes                  Prevent BAT LF conversion by Git
README.md                       User-facing instructions
context.md                      This file
```

The UI, event handlers, defaults, profile/cloud logic, encoded original `at.cfg`, and dynamically compiled C# interop types are inside **one** `cafe.bat`. The repository doesn't require building an EXE.

## Runtime/bootstrap

1. `cmd.exe` runs the first few BAT lines: save the current script as `CAFE_SCRIPT=%~f0`, start hidden `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA`, exit the BAT process.
2. The bootstrap reads its own lines and finds the literal `# POWERSHELL_GUI` marker. Remaining lines form the PowerShell source.
3. The PowerShell parser (`System.Management.Automation.Language.Parser`) checks source syntax *before* `Invoke-Expression`. Startup failures produce a Windows dialog where possible and `%TEMP%\CafeLauncher-startup-error.log`.
4. Load WinForms/Drawing, `Write-Log`, Windows mouse/display interop helpers, NVIDIA NVAPI wrapper, profile defaults/local JSON, and the GUI.
5. When the form first appears, a 350-ms one-shot Windows Forms timer runs `Get-PCDiagnostics` (read-only) then `Check-CafeLauncherUpdates`. Running a profile requires a user click.

Do not move executable PowerShell before the marker or remove it. `# CAFE_RELEASE=YYYY.MM.DD.N` near the marker is parsed by the updater. Keep the entire BAT in Windows CRLF form (`.gitattributes` uses `*.bat -text`).

## Core function index

| Concern | Functions |
| --- | --- |
| GUI actions | `New-Tile`, `Show-ProfileEditor` |
| Profile orchestration | `Invoke-GamingProfile`, `Invoke-FabModeFull` |
| Preference state | `Import-ProfileValues`, `Load-ProfileSettings`, `Export-ProfileValues`, `Save-ProfileSettings` |
| Cloud read/write | `Refresh-ProfileFromGitHub`, `Get-GitHubSyncToken`, `Sync-ProfileToGitHub` |
| Mouse | `Apply-ProfileMouse`, `Open-MousePointerOptions` |
| NVIDIA and display | `Apply-NvidiaGamingSettings`, `Open-NvidiaControlPanel`, `FabDisplayNative` and `FabNvApi` (inline C# types) |
| Steam and CS2 | `Get-SteamLibraryRoots`, `Find-CS2ConfigFolder`, `Get-AtCfgSource`, `Get-FriendConfigFallback`, `Install-AtCfg` |
| App launch / diagnostics | `Launch-All`, `Start-DetectedSteam`, `Get-PCDiagnostics`, `Show-PCDiagnostics` |
| Updater | `Check-CafeLauncherUpdates`, `Test-LauncherIsCurrent`, `Get-GitBlobSha` |
| Logs | `Write-Log` → GUI LIVE LOGS and `%TEMP%\CafeLauncher.log` |

## Profile execution pipeline

```text
Click FabMode / ArliMode / BrileMode / ArmlMode / OliMode
  -> Refresh-ProfileFromGitHub(name)
       - if SyncPending: keep unsynced local values
       - else: GET public profiles/<name>.json, validate/import/cache
  -> Apply-ProfileMouse(pointer speed, acceleration)
  -> if ApplyNvidia:
       Apply-NvidiaGamingSettings(resolution, Hz, vibrance)
         Windows display modes + NVAPI global settings + scaling
  -> Install-AtCfg(<fixed profile>.cfg, cloud URL, optional sensitivity)
       download -> validate -> offline fallback -> compare -> backup/copy -> verify
  -> no persistent Steam Launch Options write and no CS2 launch
  -> if LaunchApps:
       Launch-All (Steam, FACEIT AC, FACEIT website, Spotify, G HUB,
                   Windows Mouse Pointer Options)
  -> log result of each step
```

`Invoke-GamingProfile` loops over named action scriptblocks and catches/logs exceptions per step. A log saying **"full routine finished"** means the sequence returned, **not** that every NVIDIA/Steam/config task succeeded. Individual functions can also internally log errors and return without throwing.

**Normal profile Apply does not launch CS2 or edit saved Steam launch options.** The independent **Play + Exec** button downloads/installs that profile CFG and requests a one-time `steam.exe -applaunch 730 +exec <profile>.cfg` game launch. Steam/FACEIT readiness is not checked. If CS2 is running, the button explains the developer-console fallback `exec oli`.

## Preferences and precedence

`$script:GamingProfiles` is an ordered map of five named hashtables. `ConfigFile` is fixed in code and read-only in the editor; the other values are editable. Default initial profiles request 1920x1080 at 360 Hz and 75% vibrance, but cloud JSON may override them (e.g. OliMode cloud JSON has previously been changed to 300 Hz).

Cloud JSON files use `SchemaVersion` = 1, `ProfileName`, and these settings:

| Key | Allowed / behavior |
| --- | --- |
| `PointerSpeed` | Integer 1–20; 10 corresponds to Windows 6/11 |
| `DisableAcceleration` | Boolean; true disables Windows acceleration |
| `ApplyNvidia` | Boolean toggle for NVIDIA/display step |
| `Width`, `Height` | Requested resolution; 640–7680 wide, 480–4320 high |
| `RefreshHz` | Integer 30–600 |
| `Vibrance` | Integer 0–100 percent |
| `CS2Sensitivity` | Blank = CFG value; otherwise decimal greater than 0 up to 20 |
| `CfgDownloadUrl` | Direct HTTPS raw.githubusercontent.com link ending in `.cfg` |
| `LaunchApps` | Boolean toggle for `Launch-All` |

Local file: `%LOCALAPPDATA%\CafeLauncher\profiles.json`. This is a map of *all* profiles with an additional local-only `SyncPending` Boolean per player. The remote `profiles/<name>.json` does **not** include `SyncPending`.

### Load / sync lifecycle

1. Define profile defaults in the BAT and initialize all `PendingSync` entries to false.
2. `Load-ProfileSettings` reads local `profiles.json` if present; validates known fields, imports them, and restores `SyncPending`. Legacy local values without a `SyncPending` field are treated as pending to avoid overwriting older changes.
3. Opening an editor or clicking a profile calls `Refresh-ProfileFromGitHub`. A pending local profile is **not** fetched from GitHub. Otherwise GET JSON from the public repo's `main`, validate `ProfileName` and `SchemaVersion`, import allowed fields, and write a local cache.
4. **Save Locally** reads the editor controls, sets this profile's pending flag to true, and calls `Save-ProfileSettings`. That writes a snapshot of all five profiles to a temporary file and moves it over the local settings JSON.
5. **Save & Sync to GitHub** first does the same local save. Then it opens a PAT dialog, GETs the existing cloud JSON blob SHA, PUTs new JSON to GitHub's Contents API, and (on success only) sets this profile's pending flag to false and saves again. Cancel or failure preserves the local edits.

**Save is not Apply.** Editor saves persist settings; they do not instantly change Windows/display/CS2. Use the main profile button to apply.

`Sync-ProfileToGitHub` sends a UTF-8 Base64 JSON payload to `https://api.github.com/repos/fabjoncela/Cs-script/contents/profiles/<ProfileName>.json` on `main`, using a short-lived fine-grained token (Contents: Read and write, this repository). Token should **never** be committed, logged, written into local settings, or entered on a shared café PC. The code clears token UI contents/variables best-effort; this is not equivalent to hardened secret storage.

## Known callback / PowerShell parser pitfalls

Two real launcher failures have already occurred:

- **PowerShell variable followed by colon:** interpolating `$name:` or `$ProfileName:` directly inside a double-quoted string causes a parse error. Use curly-braced PowerShell variable syntax when punctuation touches variable names. `Test-CafeLauncher.ps1` is designed to catch syntax regressions before release.
- **"Cannot index into a null array" in profile saves:** `.GetNewClosure()` used by WinForms handlers creates a captured dynamic-module scope. `$script:PendingSync[$ProfileName]` inside that captured handler can point at a different script scope and be null. `Show-ProfileEditor` therefore captures `$pendingSyncState = $script:PendingSync` before creating callbacks, and callbacks use `$pendingSyncState[$ProfileName]`. `Test-ProfileSave.ps1` guards this pattern and exercises local save JSON persistence.

Do not remove either regression check when refactoring. Syntax validation alone cannot detect every runtime scope bug.

## CS2 config source, installation and fallback

- The default per-profile GitHub files are `fab.cfg`, `arli.cfg`, `brile.cfg`, `arml.cfg`, `oli.cfg`. Their source is **separate** from cloud profile JSON.
- `Get-SteamLibraryRoots` discovers likely Steam installs through registry values, processes, common locations and Steam library metadata. `Find-CS2ConfigFolder` looks for CS2 app 730 (`appmanifest_730.acf`) and its `game\csgo\cfg` directory, with a sensible fallback if the manifest is missing.
- If a profile has `CfgDownloadUrl`, source selection is **cloud first**. `Assert-ConfigUrl` requires HTTPS, `raw.githubusercontent.com`, and a valid `.cfg` path.
- Download uses a temporary file (up to 2 MiB), rejects apparent HTML/API error responses and NUL bytes, and applies a blank/nonblank CS2 sensitivity override only to a temporary **local** copy. It does not edit GitHub CFG content.
- On a failed cloud fetch: use the cached `%LOCALAPPDATA%\CafeLauncher\cfg-cache\<filename>.cfg`, then adjacent `.cfg` beside the BAT, then an existing CS2-installed file. **FabMode only** can fall back to the original embedded `at.cfg` bytes and install them as `fab.cfg`.
- Installing compares SHA-256 hashes, skips already matching files, backs up changed installed files using a timestamp, copies/validates the target, and caches successful GitHub downloads.
- CS2 installed path usually looks like `<Steam library>\steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg\<filename>.cfg`, but it is discovered dynamically.

**Save & Sync uploads only `profiles/<ProfileName>.json`.** To modify binds/crosshair/content in `arli.cfg` etc., push that CFG separately through Git or GitHub. Public read requires no login.

## CS2 Play + Exec without persistent Steam changes

In release 2026.10.13.9, the old `Set-CS2SteamLaunchOptions`, `Update-CS2LaunchOptionsVdfText`, and `Get-ActiveCS2SteamConfigPath` functions were **removed**. Applying a profile (or using **Install CS2 fab.cfg**) never writes `Steam/userdata/<account-id>/config/localconfig.vdf` or restarts Steam.

`New-Tile` creates a smaller main Apply button and an adjacent green **Play + Exec** button for each of the five profiles, with the original editor button beneath them. The Play callback captures `$selectedProfile` with `.GetNewClosure()` and calls `Start-CS2WithProfileCfg`.

**Play + Exec execution flow:**

1. If CS2 is already running, do not try to inject launch arguments into the game. Show the manual developer-console command `exec <profile>.cfg` or ask the user to relaunch CS2.
2. `Refresh-ProfileFromGitHub` (unless unsynced local edits), install the latest selected CFG with `Install-AtCfg -Silent`, including optional local-only sensitivity override.
3. If installation fails, do not start the game.
4. Use `Get-SteamExecutable` and `Get-CS2SteamLaunchArguments` (validated CFG filename) to call `Start-Process -FilePath <steam.exe> -ArgumentList @('-applaunch','730','+exec','<profile>.cfg')`.
5. Log that this is a **one-time game launch request**. It does not persist a new launch option and does not apply mouse/NVIDIA settings; those belong to the original profile Apply button.

**Migration warning:** Some PCs still have `+exec old.cfg` in saved Steam launch options from older CafeLauncher versions. This release deliberately does not alter that field; users should remove obsolete saved `+exec` flags once in Steam → CS2 → Properties → General → Launch Options to prevent duplicate/conflicting CFG execution.

## Independent CS2 graphics architecture

The GUI's `New-Tile` creates an independent third `Apply Graphics` button beside each mode and `Play + Exec`. It calls `Invoke-GraphicsOnly -ModeName <name>`. No invocation exists in `Invoke-GamingProfile`, `Start-CS2WithProfileCfg`, `Launch-All`, the existing profile editor, or startup. Selecting a mode never changes CS2 video graphics.

Each mode has a **separate** public `graphics/<ModeName>.json` with `SchemaVersion=1`, matching `ProfileName` and a `Settings` object. `null` = preserve that video setting. FabMode now explicitly requests 1280x960, 4:3, fullscreen, 360 Hz based on the user's provided settings. The four other profiles leave Width/Height/RefreshHz/Fullscreen/AspectRatioMode null by default to preserve each PC's existing game resolution. These graphics files are not `profiles/<ModeName>.json` and are not affected by Save & Sync.

`graphics/ApplyGraphics.ps1` implements video-file editing separately from `cafe.bat`. `Invoke-GraphicsOnly` downloads the module only on click, checks its exact Git blob SHA and PowerShell parse result, caches it at `%LOCALAPPDATA%\CafeLauncher\graphics-module.ps1`, checks the cached hash again, then dot-sources it. When editing this module, **update the pinned module Git blob SHA in cafe.bat** and bump the BAT release marker. Hash pinning is not a digital signature.

The graphics-only module:
1. Fetches `graphics/<ModeName>.json` from GitHub (or validated offline cache), validating the schema and an allowlist of numeric graphics properties.
2. Reads the active Steam account ID from `HKCU:\Software\Valve\Steam\ActiveProcess\ActiveUser`, resolves the Steam executable dynamically, and targets only `<SteamRoot>\userdata\<ActiveUser>\730\local\cfg\cs2_video.txt`. Missing paths or account ID abort without writes.
3. Refuses to edit while `cs2.exe` is running, including a second check immediately before replacement.
4. Verifies a recognizable `"video.cfg"` file and updates **only existing recognized key/value lines** while preserving encoding/BOM, line endings, unrelated fields, and hardware-specific `VendorID` / `DeviceID` / monitor keys.
5. Handles resolution and refresh as an optional pair via read-only `FabDisplayNative.IsAdvertisedMode`. Unsupported modes are skipped while compatible advanced options may still be applied. Optional NVIDIA Reflex is skipped on systems without a detected NVIDIA GPU.
6. Backs up the original video file to `%LOCALAPPDATA%\CafeLauncher\graphics-backups\<ActiveUser>`, stages a replacement, atomically replaces the target where Windows allows, verifies the result, and attempts recovery using the backup on errors.

`tools/Test-Graphics.ps1` exercises graphics VDF changes against in-memory fixtures (including known hardware-specific fields), validates the five independent JSON presets, checks enum/range validation, and ensures the normal profile code does not call graphics. CI validates these on Windows PowerShell 5.1; a final end-to-end test on a Windows PC with Steam + CS2 remains necessary.

**Graphics save regression fixed (v2026.10.13.11):** Windows PowerShell 5.1 may reject a null third backup path in `[IO.File]::Replace($temp,$target,$null)` with `The path is not of a legal form`. `Save-CS2VideoFileWithBackup` now gives `File.Replace` a legal same-directory backup filename and keeps a separate, permanent timestamped copy under `%LOCALAPPDATA%\CafeLauncher\graphics-backups\<Steam3ID>`. It checks CS2 isn't running just before replacement, verifies the new text, and attempts recovery from the permanent backup on error. The Windows graphics test now exercises this function using real temporary files, checks backup integrity, and ensures temporary/swap files are cleaned up. Update the module blob SHA pinned by the BAT whenever editing the module.

## Windows, NVIDIA and PC detection

- Mouse: `Apply-ProfileMouse` writes `HKCU:\Control Panel\Mouse` values and requests live pointer speed/acceleration via Win32 `SystemParametersInfo`. It logs API and registry verification.
- Display: target `\\.\DISPLAY1`. Enumerates driver-advertised modes, prioritizing (1) exact requested width/height/Hz, (2) highest Hz at requested resolution, or (3) highest Hz at **current** resolution when the requested resolution is unavailable. `ChangeDisplaySettingsEx` tests before apply and reads back afterwards.
- NVIDIA: inline `FabNvApi` requests Digital Vibrance, global driver 3D/performance/G-SYNC-related values, and full-screen GPU scaling. Results depend on NVAPI availability, driver support, PC permissions, and connected display.
- Not automated fully: PhysX GPU choice, scaling override checkbox, actual G-SYNC checkbox state, visual Performance slider. `Start-ColorWatch` exists, but the periodic vibrance watch is **disabled** in the profile apply routine.
- Diagnostics: `Get-PCDiagnostics` checks GPU names, monitor modes, current/registry pointer speed, Steam/CS2, FACEIT AC, Logitech G HUB, Chrome, and NVIDIA Control Panel. Startup inventory is informational, not a blanket readiness guarantee.

## Self-update workflow

`Check-CafeLauncherUpdates` runs after GUI appears and via a manual button:

1. Call GitHub Contents API for `main/cafe.bat`; verify path, size, Git blob SHA and the `# CAFE_RELEASE` marker.
2. Only offer if the GitHub release version is higher than the local version and differs from the local BAT.
3. Require user confirmation (no silent replacement).
4. Download `raw.githubusercontent.com/.../main/cafe.bat` to a temporary file. Verify size + Git blob SHA-1 against GitHub metadata, BAT marker, and embedded PowerShell parser result.
5. Normalize to CRLF, stage a new BAT near the original, replace with backup (atomic replacement attempted; fallback copy), and show an instruction to close/reopen.
6. Backup folder: `%LOCALAPPDATA%\CafeLauncher\backups`. If overwriting fails, launcher can write `%USERPROFILE%\Downloads\CafeLauncher_latest.bat`.

**Updating an old BAT downloaded from Google Drive changes that local file only**, not the source on Drive. On Deep Freeze PCs the next reboot may restore the original copy. Git blob validation is an **integrity check against GitHub**, not code signing or protection against a compromised repository.

## Logging, tests, release checklist

- `%TEMP%\CafeLauncher.log` — main log and on-screen LIVE LOGS. It is normally cleared when the app starts.
- `%TEMP%\CafeLauncher-startup-error.log` — exceptions in the hybrid bootstrap/parser.
- Windows-only local tests from repository root:

```powershell
powershell.exe -NoProfile -File .\tools\Test-CafeLauncher.ps1
powershell.exe -NoProfile -File .\tools\Test-ProfileSave.ps1
powershell.exe -NoProfile -File .\tools\Test-SteamLaunchOptions.ps1
powershell.exe -NoProfile -File .\tools\Test-Graphics.ps1
```

- [CI workflow](./.github/workflows/cafe-syntax.yml) runs tests for relevant changes on push to `main` and on pull requests. The syntax test checks CRLF, marker, release metadata, parser, and invalid-variable self-test; the save test checks captured callback state and JSON round-tripping; the Steam test uses mocked launches to ensure the correct one-time +exec for each profile and no persistent VDF writer.
- For a new launcher release: preserve the `# POWERSHELL_GUI` header contract; keep BAT CRLF; bump `CAFE_RELEASE`; run both tests; check GitHub Actions; do an authorized live Windows smoke test (GUI launch, local save, optional token sync on your own PC, CFG install, mouse/display/NVIDIA); then distribute.
- CI tests are not proof of runtime GPU, FACEIT, login, game launch, network, WinForms, or administrator behavior. Required CI enforcement needs branch protection/rules configured separately.

## Boundaries and future work

Not yet implemented: automatic CS2 startup when pressing the original Apply button, readiness gating for Steam/FACEIT AC, automatic Github CFG *writeback*, fully controlling NVIDIA's remaining manual GUI options, preserving Deep Freeze local changes, or guaranteed warning-free execution of downloaded BAT files. Keep existing five profiles, offline fallbacks, optional app launch, explicit update consent, no token persistence, and recoverable backups when evolving the code.
