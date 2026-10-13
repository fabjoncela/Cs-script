# CafeLauncher — Technical Context

Maintainer / coding-assistant reference for [CafeLauncher](./README.md). This document reflects the `main` implementation of `cafe.bat` at **2026.10.13.8**. Read the actual source before editing; code is the ultimate source of truth.

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
  -> if CFG installed successfully:
       Set-CS2SteamLaunchOptions(<fixed profile>.cfg)
       locate active Steam account -> safely update game 730 LaunchOptions
       (ask to restart Steam if required; preserve other game flags)
  -> if LaunchApps:
       Launch-All (Steam, FACEIT AC, FACEIT website, Spotify, G HUB,
                   Windows Mouse Pointer Options)
  -> log result of each step
```

`Invoke-GamingProfile` loops over named action scriptblocks and catches/logs exceptions per step. A log saying **"full routine finished"** means the sequence returned, **not** that every NVIDIA/Steam/config task succeeded. Individual functions can also internally log errors and return without throwing.

**No automatic CS2 game launch, and no verification that Steam/FACEIT sign-in or anti-cheat is ready** in this version. Steam loads the CFG on game startup when `+exec <profile>.cfg` was set successfully. If Steam settings could not be changed, the developer-console fallback `exec oli` still works.

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

## Steam CS2 launch options

The `Set-CS2SteamLaunchOptions` helper runs only after `Install-AtCfg` returns a successful installation status. Steam launch options are *per local Steam account*, stored in `Steam/userdata/<Steam3-account-id>/config/localconfig.vdf` under `UserLocalConfigStore/Software/Valve/Steam/apps/730/LaunchOptions`. The launcher obtains the active account ID from the current-user Steam `ActiveProcess/ActiveUser` registry value, or uses the single-account fallback. It **refuses to guess** when multiple accounts are present without a reliable active match.

`Update-CS2LaunchOptionsVdfText` parses quoted tokens and braces, replaces a previous `+exec` launch argument, retains unrelated launch flags and other game sections, and can add the CS2 `LaunchOptions` field or game-730 section when the containing Steam apps section exists. A separate dry-run regression test validates this against in-memory VDF fixtures.

Steam caches/re-saves this file: if it is running and an edit is required, a WinForms Yes/No dialog requests permission to perform Steam's normal `-shutdown` and restart. If CS2 is running, the account is ambiguous, Steam refuses to close, or the user declines, it logs the manual `+exec <filename>.cfg` option instead. When writing, a timestamped `.cafe-backup-*` copy is saved beside `localconfig.vdf`; the edited file is read back for verification. Steam is restarted when previously running and consented to shutdown. This is a local Steam preference and does not sync to GitHub, and it does not launch CS2 by itself.

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
```

- [CI workflow](./.github/workflows/cafe-syntax.yml) runs tests for relevant changes on push to `main` and on pull requests. The syntax test checks CRLF, marker, release metadata, parser, and invalid-variable self-test; the save test checks captured callback state and JSON round-tripping.
- For a new launcher release: preserve the `# POWERSHELL_GUI` header contract; keep BAT CRLF; bump `CAFE_RELEASE`; run both tests; check GitHub Actions; do an authorized live Windows smoke test (GUI launch, local save, optional token sync on your own PC, CFG install, mouse/display/NVIDIA); then distribute.
- CI tests are not proof of runtime GPU, FACEIT, login, game launch, network, WinForms, or administrator behavior. Required CI enforcement needs branch protection/rules configured separately.

## Boundaries and future work

Not yet implemented: automatic CS2 game startup, readiness gating for Steam/FACEIT AC, automatic Github CFG *writeback*, fully controlling NVIDIA's remaining manual GUI options, preserving Deep Freeze local changes, or guaranteed warning-free execution of downloaded BAT files. Keep existing five profiles, offline fallbacks, optional app launch, explicit update consent, no token persistence, and recoverable backups when evolving the code.
