# CafeLauncher

CafeLauncher is a portable Windows setup launcher for CS2 internet cafés. It runs from a single hybrid `cafe.bat` file and provides a PowerShell/Windows Forms dashboard for player profiles, mouse and display settings, CS2 configuration, app shortcuts, and launcher updates. There is no installer or compiled build step.

[Technical architecture and maintenance notes](./context.md)

<!-- BEGIN GENERATED LAUNCHER RELEASE -->
> Launcher release: **2026.10.15.36**. Features depend on the PC's hardware, installed programs and user permissions.
<!-- END GENERATED LAUNCHER RELEASE -->

## Download and start

1. Download [cafe.bat](https://raw.githubusercontent.com/fabjoncela/Cs-script/main/cafe.bat) or use a previously downloaded copy.
2. Review the script before running it. Windows may show its usual security warning for a downloaded BAT file.
3. Open the launcher and use **Detect PC** to review the detected hardware, Steam/CS2 locations, connected mouse, and available display modes.
4. Choose a player profile and use **Apply**, **Play + Exec**, **Apply Graphics**, or **Edit** for the action you want.

The launcher does not require installation or administrator rights to open. Windows permissions, drivers, installed applications, and the connected hardware can limit individual operations.

## Player profiles

The dashboard keeps separate settings for five profiles:

| Profile | Cloud settings | CS2 config |
| --- | --- | --- |
| FabMode | [profiles/FabMode.json](./profiles/FabMode.json) | [fab.cfg](./fab.cfg) |
| ArliMode | [profiles/ArliMode.json](./profiles/ArliMode.json) | [arli.cfg](./arli.cfg) |
| BrileMode | [profiles/BrileMode.json](./profiles/BrileMode.json) | [brile.cfg](./brile.cfg) |
| ArmlMode | [profiles/ArmlMode.json](./profiles/ArmlMode.json) | [arml.cfg](./arml.cfg) |
| OliMode | [profiles/OliMode.json](./profiles/OliMode.json) | [oli.cfg](./oli.cfg) |

### Apply and launch

- **Apply** refreshes the selected profile, then applies its mouse settings, any enabled display settings, its CS2 config, and configured app actions. It does not start CS2 or change Steam's saved launch options.
- **Play + Exec** installs the selected profile's current CS2 config and asks Steam to launch CS2 with a one-time `+exec <profile>.cfg` argument. It does not apply mouse or display settings, modify persistent launch options, or restart Steam.
- **Apply Graphics** is a separate action for the selected profile's CS2 video settings.
- A failed step is reported in the result summary and LIVE LOGS. Other profile steps can continue where appropriate.

### Save locally and sync

**Save Locally** stores profile settings and the graphics editor snapshot in `%LOCALAPPDATA%\CafeLauncher\profiles.json`. The profile stays marked as pending sync; local app data may be cleared by café PC reset software such as Deep Freeze.

**Save & Sync to GitHub** asks for one-time authorization using a personal access token or GitHub device sign-in. The launcher updates that profile's JSON and graphics preset, and only the recognized CFG commands the user changed, such as sensitivity, crosshair values, or push-to-talk. Other binds and CFG commands are preserved. The launcher reads the saved files back and verifies them before clearing the pending state. Credentials stay in memory during the sync and are not saved to disk. **Never enter a GitHub credential on an untrusted shared PC.**

Before editing or applying a profile with pending local changes, the launcher offers to sync them, discard them and fetch the latest cloud files, or cancel. A failed refresh does not silently replace local values with stale cached data.

## CS2 graphics editor

Each profile has its own canonical preset under [`graphics/`](./graphics/). In the **CS2 / Apps** editor, you can set resolution, aspect ratio, fullscreen mode, refresh rate, NVIDIA scaling mode, and supported CS2 video options such as MSAA, shadows, textures, HDR, Reflex, FSR, VSync, and CMAA.

FabMode, ArliMode, ArmlMode, and OliMode currently use 1280×960 4:3 fullscreen defaults. BrileMode uses 1920×1080 16:9. Presets request the highest refresh rate advertised for the selected game resolution, or can use an exact rate when it is available.

- **Capture CS2** stages saved video settings from the active Steam account after CS2 is closed. It can also read sensitivity and supported crosshair commands from the account's user-convars file. It does not edit those game files; you review captured values before saving or syncing. Missing user-convars are reported and do not replace existing CFG values with invented ones.
- **Copy graphics** copies only graphics fields from another profile. **Reset** reloads the selected profile's canonical preset. Neither saves automatically.
- **Load history** can show the three previous versions of a profile's preset. Restoring loads values into the editor; it does not save or apply them.
- **Apply Graphics** requires CS2 to be closed. It validates the selected profile and active Steam account, backs up the target file, changes recognized settings, verifies the result, and reports fields that were applied, skipped, or could not be verified.

Graphics changes affect only the active Steam account's `userdata/<id>/730/local/cfg/cs2_video.txt`. The launcher preserves unrelated and hardware-specific fields. If an exact display mode is unavailable, it reports the fallback and avoids claiming that an unsupported mode was applied.

## Mouse, NVIDIA, and display settings

Profiles can set Windows pointer speed and acceleration, Logitech live DPI, display resolution/refresh, NVIDIA Digital Vibrance and Hue, NVIDIA driver settings, and GPU scaling. The launcher checks supported operations and reports read-back results; unsupported settings can be skipped. Brightness is not changed. PhysX selection and certain NVIDIA Control Panel checkboxes remain manual.

Live DPI targets the detected PRO X SUPERLIGHT 1 or 2 by device identity. The original SUPERLIGHT has a verified host-mode fallback if the normal live DPI operation fails. Live DPI does not write onboard mouse memory. The **Onboard** control remains disabled. Logitech G HUB can override a live DPI value later; check LIVE LOGS if that happens.

Startup hardware detection is informational and does not change display settings. The launcher does not monitor manual CS2 launches to confirm that CS2 retained NVIDIA scaling; if scaling does not appear as expected, check the display mode and the NVIDIA Control Panel override checkbox manually.

## Tools, shortcuts, and logs

The **Tools & Apps** tab contains less-used shortcuts, and the dashboard can launch configured apps with a profile. **LAUNCH ALL** opens its configured applications; it is not a Steam or FACEIT readiness check.

The dashboard reports profile-step outcomes and includes an API allowance indicator based on responses it already receives; the indicator does not make a separate polling request. Detailed output appears in LIVE LOGS and `%TEMP%\CafeLauncher.log`. Startup parse errors are written to `%TEMP%\CafeLauncher-startup-error.log`.

## Launcher updates

The launcher checks for a newer release at startup and through **Check for Updates**. It compares the running release with `main/cafe.bat`, validates the downloaded file's size, Git blob hash, and PowerShell syntax, normalizes Windows line endings, and keeps a backup before replacing the local BAT. If the newer file is already installed, close and reopen the launcher. Updating the local BAT does not change a Google Drive copy; a Deep Freeze reboot may also remove local updates and cached files.

Backups are stored under `%LOCALAPPDATA%\CafeLauncher\backups`. If the original BAT cannot be replaced, the updated file may be saved to Downloads instead.

## Requirements and offline behavior

- Windows 10 or 11 with Windows PowerShell 5.1, `cmd.exe`, and Windows Forms.
- NVIDIA hardware and a compatible driver are needed for NVIDIA-specific operations. Steam, CS2, FACEIT, and Logitech G HUB are needed only for their related features.
- Online profile refresh and GitHub sync require internet access. **Apply Graphics** can use a validated pending local graphics preset offline; other offline fallbacks require confirmation. Cached files are not treated as proof of current cloud settings.
- The downloaded graphics helper is pinned by a Git blob hash and cached for reuse. CFG downloads also have a local cache for supported offline cases.

## Contributing and validation

The application is a hybrid BAT/PowerShell launcher; there is no compile or install step. Keep `cafe.bat` in Windows CRLF format and increment its `# CAFE_RELEASE` marker for a launcher release. The release line in this README and the one in `context.md` are generated from that marker by [`tools/Update-Context.ps1`](./tools/Update-Context.ps1). Git hooks refresh the generated text, and GitHub Actions checks that it is current.

Windows PowerShell 5.1 regression checks are in [`tools/`](./tools/). GitHub Actions runs the relevant validation jobs for pull requests and pushes to `main`. Automated checks do not replace a real Windows/Steam/CS2/monitor smoke test. See [context.md](./context.md) for the full architecture, safety boundaries, and verification commands.
