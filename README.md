# CafeLauncher

CafeLauncher is a portable Windows setup launcher for CS2 internet cafés. It runs from a single hybrid `cafe.bat` file and provides a PowerShell/Windows Forms dashboard for player profiles, mouse and display settings, CS2 configuration, app shortcuts, and launcher updates. There is no installer or compiled build step.

[Technical architecture and maintenance notes](./context.md)

<!-- BEGIN GENERATED LAUNCHER RELEASE -->
> Launcher release: **2026.11.08.6**. Features depend on the PC's hardware, installed programs and user permissions.
<!-- END GENERATED LAUNCHER RELEASE -->

## Download and start

1. Download [cafe.bat](https://raw.githubusercontent.com/fabjoncela/Cs-script/main/cafe.bat) or use a previously downloaded copy.
2. Review the script before running it. Windows may show its usual security warning for a downloaded BAT file.
3. Open the launcher and use **Detect PC** to review the detected hardware, Steam/CS2 locations, connected mouse, and available display modes.
4. Choose a player profile and use **Apply**, **Play + Exec**, **Apply Graphics**, or **Edit** for the action you want.

The launcher does not require installation or administrator rights to open. Windows permissions, drivers, installed applications, and the connected hardware can limit individual operations.

## Player profiles

The dashboard keeps separate settings for six profiles:

| Profile | Cloud settings | CS2 config |
| --- | --- | --- |
| FabMode | Backend API (public GitHub mirror fallback) | Backend API (public GitHub mirror fallback) |
| ArliMode | Backend API (public GitHub mirror fallback) | Backend API (public GitHub mirror fallback) |
| BrileMode | Backend API (public GitHub mirror fallback) | Backend API (public GitHub mirror fallback) |
| ArmlMode | Backend API (public GitHub mirror fallback) | Backend API (public GitHub mirror fallback) |
| OliMode | Backend API (public GitHub mirror fallback) | Backend API (public GitHub mirror fallback) |
| Provmode | Backend API (public GitHub mirror fallback) | Backend API (public GitHub mirror fallback) |

### Apply and launch

- **Apply** refreshes the selected profile, then applies its mouse settings, any enabled display settings, its CS2 config, and configured app actions. It does not start CS2 or change Steam's saved launch options.
- **Play + Exec** installs a CafeLauncher baseline containing captured defaults for profile-managed binds, radar, sensitivity, FPS, and visibility, with the developer console enabled. The baseline leaves crosshair settings to the selected profile CFG. Play + Exec installs that CFG and launches with `+exec cafelauncher_profile_baseline.cfg +exec <profile>.cfg`; the profile CFG runs last, using the backend and then its verified public mirror fallback. This clears profile leftovers such as ArliMode's CapsLock bind or another profile's MWHEELDOWN jump before applying the selection. It does not apply mouse or display settings, modify persistent launch options, or restart Steam.
- **Apply Graphics** is a separate action for the selected profile's CS2 video settings.
- A failed step is reported in the result summary and LIVE LOGS. Other profile steps can continue where appropriate.

### Save locally and sync

**Save Locally** stores profile settings and the graphics editor snapshot in `%LOCALAPPDATA%\CafeLauncher\profiles.json`. The profile stays marked as pending sync; local app data may be cleared by café PC reset software such as Deep Freeze.

**Save & Sync to Backend** asks for a backend sync token for the current session. The launcher sends the profile, graphics preset, and selected CFG changes as one revision-checked bundle, then reads the result back before clearing the pending state. If a write fails, the edit stays in a local queue and can retry while the launcher remains open and the session token is available. The token is kept in memory and is not saved to disk. The public GitHub mirror is read-only; pending edits from an older GitHub-based launcher must be resolved before backend sync.

Before editing or applying a profile with pending local changes, the launcher offers to sync them, discard them and fetch the latest cloud files, or cancel. A failed refresh does not silently replace local values with stale cached data.

If the backend is unavailable, profile reads can use the public GitHub mirror. The launcher rejects a mirror revision older than the latest revision this PC has verified and asks before using mirror-sourced values for Edit, Apply, Play + Exec, or Apply Graphics. The mirror may still be behind a backend update this PC has not yet seen, so retry against the backend when it is available.

## CS2 graphics editor

Each profile has its own graphics preset in the backend, with the verified public GitHub mirror as a read fallback. In the **CS2 / Apps** editor, you can set resolution, aspect ratio, fullscreen mode, refresh rate, NVIDIA scaling mode, and supported CS2 video options such as MSAA, shadows, textures, HDR, Reflex, FSR, VSync, and CMAA.

FabMode, ArliMode, ArmlMode, OliMode, and Provmode currently use 1280×960 4:3 fullscreen defaults. Provmode currently copies OliMode's profile and graphics values. BrileMode uses 1920×1080 16:9. Presets request the highest refresh rate advertised for the selected game resolution, or can use an exact rate when it is available.

- **Capture CS2** lets you choose graphics, sensitivity, crosshair, viewmodel, HUD/radar, audio, and bind groups (jump, voice, reload, grenade keys, and scroll wheel). After CS2 is closed, it reads the active Steam account's saved files and shows a before/after review with CS2 names and bind replacement warnings. Import only the rows you select; Capture does not edit game files or save/sync automatically. Save Locally or Save & Sync keeps the staged changes for the selected profile.
- **Preview & Import** in **Edit → Mouse** decodes a pasted CS2 crosshair share code and opens a local visual preview with stone, dark, light, and foliage-like backgrounds. Static Quadrant is drawn as four short arcs around a square center dot, following current CS2 geometry. A local per-pixel raster applies smooth edge coverage and color blending at game-pixel size before nearest-neighbor enlargement. Dragging the crosshair only checks visibility. **Import** stages the values for the selected profile; canceling does not change staged settings. Dynamic styles are shown at rest. The reference rendering model is publicly reconstructed, so an exact in-game pixel match has not been confirmed.
- **Copy graphics** copies only graphics fields from another profile. **Reset** reloads the selected profile's canonical preset. Neither saves automatically.
- **Load history** can show the three previous versions of a profile's preset. Restoring loads values into the editor; it does not save or apply them.
- **Apply Graphics** requires CS2 to be closed. If it must use the GitHub mirror because the backend is unavailable, the launcher asks before applying that possibly older preset. It validates the selected profile and active Steam account, backs up the target file, changes recognized settings, verifies the result, and reports fields that were applied, skipped, or could not be verified.

Graphics changes affect only the active Steam account's `userdata/<id>/730/local/cfg/cs2_video.txt`. The launcher preserves unrelated and hardware-specific fields. If an exact display mode is unavailable, it reports the fallback and avoids claiming that an unsupported mode was applied.

## Mouse, NVIDIA, and display settings

Profiles can set Windows pointer speed and acceleration, Logitech live DPI, display resolution/refresh, NVIDIA Digital Vibrance and Hue, NVIDIA driver settings, and GPU scaling. The launcher checks supported operations and reports read-back results; unsupported settings can be skipped. Brightness is not changed. PhysX selection and certain NVIDIA Control Panel checkboxes remain manual.

Live DPI targets the detected PRO X SUPERLIGHT 1 or 2 by device identity. The original SUPERLIGHT has a verified host-mode fallback if the normal live DPI operation fails. Live DPI does not write onboard mouse memory. The **Onboard** control remains disabled. Logitech G HUB can override a live DPI value later; check LIVE LOGS if that happens.

Startup hardware detection is informational and does not change display settings. The launcher does not monitor manual CS2 launches to confirm that CS2 retained NVIDIA scaling; if scaling does not appear as expected, check the display mode and the NVIDIA Control Panel override checkbox manually.

## Tools, shortcuts, and logs

The **Tools & Apps** tab contains less-used shortcuts, and the dashboard can launch configured apps with a profile. **LAUNCH ALL** opens its configured applications; it is not a Steam or FACEIT readiness check.

- **Workshop Cleanup** previews installed CS2 Workshop items against the signed-in Steam account's subscriptions. It protects subscribed items, removes only selected safe local folders, and clears matching stale Steam manifest entries after confirmation. Manifest edits get a timestamped backup; subscriptions are unchanged. Steam must be running and signed in, CS2 must be closed, and Steam's manifest/download state must be readable and stable.

The **Startup & API Timings** tool reports app-observed dashboard readiness, total startup time, detailed local startup stages, dashboard layout/control setup phases, and each observed HTTP/API request. Startup profile requests identify their commit-check or content-fetch operation and profile. It keeps the latest 500 timing entries in memory for the current run; query strings and credentials are excluded, and refreshing the view makes no request. The dashboard also reports profile-step outcomes and an API allowance indicator based on responses it already receives; the indicator does not make a separate polling request. LIVE LOGS loads available retained history the first time it opens while keeping all entries from the current session; use its horizontal scrollbar to read long messages. Statuses and key values are color-coded. `%TEMP%\CafeLauncher.log` retains the last 2,000 lines across launches, including detailed errors and stack traces. Startup errors are also written to `%TEMP%\CafeLauncher-startup-error.log`.

**Send Logs** uploads the current `CafeLauncher.log` to the configured Sentry project only when pressed. It needs no player login and shows a report ID when Sentry accepts the upload. The log remains on the PC. During testing, the launcher sends the raw file without filtering local paths or usernames or applying its own size limit; Sentry may still reject an oversized report. Sentry email alerts link to the report and its log attachment.

## Launcher updates

After the dashboard appears, the launcher checks for a newer release in the background and stays quiet when it is up to date. If a different verified build is available, it asks before downloading. **Check for Updates** in Tools & Apps remains manual and shows an up-to-date message when appropriate. Update downloads are checked for size, Git blob hash, and PowerShell syntax, normalized to Windows line endings, and backed up before replacing the local BAT. If the newer file is already installed, close and reopen the launcher. Updating the local BAT does not change a Google Drive copy; a Deep Freeze reboot may also remove local updates and cached files.

**Detect PC** runs the read-only hardware/software inventory on demand; the launcher no longer scans the PC during startup.

Backups are stored under `%LOCALAPPDATA%\CafeLauncher\backups`. If the original BAT cannot be replaced, the updated file may be saved to Downloads instead.

## Requirements and offline behavior

- Windows 10 or 11 with Windows PowerShell 5.1, `cmd.exe`, and Windows Forms.
- NVIDIA hardware and a compatible driver are needed for NVIDIA-specific operations. Steam, CS2, FACEIT, and Logitech G HUB are needed only for their related features.
- Profile reads use the backend API and can fall back to its verified public GitHub mirror. Profile sync writes only to the backend and requires internet access plus a session sync token. **Apply Graphics** can use a validated pending local graphics preset offline; other offline fallbacks require confirmation. Cached files are not treated as proof of current cloud settings.
- The downloaded graphics helper is pinned by a Git blob hash and cached for reuse. CFG downloads also have a local cache for supported offline cases.

## Contributing and validation

The application is a hybrid BAT/PowerShell launcher; there is no compile or install step. Keep `cafe.bat` in Windows CRLF format and increment its `# CAFE_RELEASE` marker for a launcher release. The release line in this README and the one in `context.md` are generated from that marker by [`tools/Update-Context.ps1`](./tools/Update-Context.ps1). Git hooks refresh the generated text, and GitHub Actions checks that it is current.

Windows PowerShell 5.1 regression checks are in [`tools/`](./tools/). GitHub Actions runs the relevant validation jobs for pull requests and pushes to `main`. Automated checks do not replace a real Windows/Steam/CS2/monitor smoke test. See [context.md](./context.md) for the full architecture, safety boundaries, and verification commands.
