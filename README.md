# CafeLauncher

A portable Windows **CS2 internet-café setup launcher**. A single hybrid `cafe.bat` provides a PowerShell/Windows Forms GUI for player profiles, mouse and NVIDIA/display setup, CS2 CFG installation, app shortcuts, PC detection, and GitHub updates.

[Technical architecture and maintenance notes](./context.md)

> Documents the current main-branch launcher at **2026.10.13.11**. Some features depend on PC hardware, installed programs and user permissions.

## Quick start

1. Download [cafe.bat](https://raw.githubusercontent.com/fabjoncela/Cs-script/main/cafe.bat) or open a previously downloaded Google Drive copy.
2. Review/trust the script before double-clicking it. Windows may show a normal security warning on a downloaded BAT.
3. Use **Detect PC** or check the automatic **LIVE LOGS** inventory.
4. Click **FabMode**, **ArliMode**, **BrileMode**, **ArmlMode**, or **OliMode**. This applies that profile's mouse settings, optionally NVIDIA/display settings, installs its CS2 CFG, and optionally opens gaming apps.
5. A separate **Play + Exec** button now appears beside each profile. It downloads/installs that profile's latest CFG and requests a Steam CS2 launch with a one-time argument like `steam.exe -applaunch 730 +exec oli.cfg`. It does **not** alter Steam's saved launch options or restart Steam.

**Important:** Clicking a profile button only applies settings and installs its CFG, without starting CS2 or editing Steam launch options. **Play + Exec** launches CS2 with the selected CFG; it does *not* apply mouse/NVIDIA profile settings on its own. If CS2 is already running, the button shows instructions to use the developer console (`exec oli`) or restart the game. Old `+exec` values saved by earlier CafeLauncher versions will **remain in Steam's Launch Options** until you remove them once in **Steam → Library → Counter-Strike 2 → Properties → General → Launch Options**; otherwise those older commands may conflict.

## Independent Apply Graphics buttons

Each player row now contains **the original mode**, **Play + Exec**, and **Apply Graphics**. The graphics button does **not** trigger mouse/NVIDIA settings, Steam launch options, CS2 startup, or Launch All. Likewise, mode selection and Play + Exec do **not** automatically edit CS2 graphics.

Graphics presets are **separate JSON files**, independent of the normal profile preferences:

| Button | Editable graphics preset |
| --- | --- |
| FabMode → Apply Graphics | [graphics/FabMode.json](./graphics/FabMode.json) |
| ArliMode → Apply Graphics | [graphics/ArliMode.json](./graphics/ArliMode.json) |
| BrileMode → Apply Graphics | [graphics/BrileMode.json](./graphics/BrileMode.json) |
| ArmlMode → Apply Graphics | [graphics/ArmlMode.json](./graphics/ArmlMode.json) |
| OliMode → Apply Graphics | [graphics/OliMode.json](./graphics/OliMode.json) |

On click, CafeLauncher downloads the corresponding public JSON (or a previously cached copy), detects the signed-in Steam account via the Windows registry, and edits **only recognized fields** in that account's `userdata/<Steam3ID>/730/local/cfg/cs2_video.txt`. It backs up the original under `%LOCALAPPDATA%\CafeLauncher\graphics-backups\<Steam3ID>` before any change and verifies the result. It refuses to edit while CS2 is running.

Supported JSON fields are `Width`, `Height`, `RefreshHz`, `AspectRatioMode`, `Fullscreen`, `MSAASamples`, `ShadowQuality`, `DynamicShadows`, `TextureDetail`, `ShaderQuality`, `ParticleDetail`, `AmbientOcclusion`, `HDRDetail`, `NvidiaReflex`, `TextureFiltering`, `FSRDetail`, `VSync`, and `CMAA`. Change each mode's JSON independently on GitHub; **Save & Sync to GitHub in the normal profile editor does not update these files**.

**Graphics presets:** **FabMode, ArliMode, ArmlMode, and OliMode** currently share identical graphics preferences: **1280×960, 4:3, fullscreen, 360 Hz**, 8× MSAA and the same advanced-video options. Each still has its **own editable JSON file**, so they can be customized independently later. **BrileMode is unchanged:** its resolution, refresh rate, aspect ratio and fullscreen settings stay `null` (preserve the PC's existing CS2 values), with its original advanced-video defaults. The launcher checks requested modes against the PC's advertised DISPLAY1 modes and skips unsupported resolution/refresh entries. Missing CS2 keys are skipped; unrelated and hardware-specific fields (`Version`, `VendorID`, `DeviceID`, monitor index) are preserved.

If CS2 isn't installed/signed in yet, open and save its video settings at least once to create `cs2_video.txt`. Close CS2 before applying graphics; the game writes these settings itself and could overwrite edits while running.

The graphics-only PowerShell module is downloaded only when needed, checked against a **Git blob hash embedded in the BAT** (not code signing), and cached for offline reuse. Launch CS2 afterward to read the new graphics settings.

**Graphics save fix (v2026.10.13.11):** Corrected a Windows PowerShell 5.1 file-replacement error (`The path is not of a legal form`). The graphics module now supplies a real same-directory backup path to `.NET File.Replace`, keeps the permanent CafeLauncher backup, verifies the result, and attempts restoration if replacement fails. Neither normal profile buttons nor Play + Exec changed.

## Logitech mouse DPI (v2026.10.13.12)

The **Set DPI 800 (Live)** button uses the portable [better-logihub](https://github.com/cUDGk/better-logihub) Windows executable. CafeLauncher downloads the pinned v0.1.0 executable **asynchronously** on first use and validates its published SHA-256 before executing it. Other profile actions and the GUI remain responsive during download. Multiple clicks share one download; the most recently requested DPI is applied when the download finishes. Nothing needs to be installed manually. The executable is cached in `%LOCALAPPDATA%\CafeLauncher\logihub`; a Deep Freeze reboot may clear that cache.

**All five normal profile buttons** automatically attempt a *live* DPI setting using the individually editable `LogitechDPI` value (800 by default), preserving all other profile actions. Change it in **Edit [Mode] settings**, then Save Locally or Save & Sync to GitHub. Play + Exec and Apply Graphics do not set DPI. The LIVE LOGS show G HUB detection, command output, and any failures. G HUB is not stopped and may override the result. The live DPI operation does **not** write onboard memory.

The **Onboard button is currently commented out/disabled** pending hardware testing. Its implementation is retained in the source and would ask for confirmation, runs `onboard dump --out <backup>`, checks for a nonempty backup, then runs `onboard set-dpi 800 --default 1 --shift 800` and `onboard mode set on`. It writes to mouse memory, which Deep Freeze does **not** restore. Backups are stored in `%LOCALAPPDATA%\CafeLauncher\logihub\onboard-backups` and may themselves be erased by Deep Freeze; copy them to a safe place before reboot. Only use the onboard button with a verified supported mouse model and after confirming the backup is accessible. If G HUB competes with live DPI, review LIVE LOGS rather than forcing process termination.

## Profile files

| Profile button | Cloud settings JSON | GitHub CS2 config |
| --- | --- | --- |
| FabMode | [FabMode.json](./profiles/FabMode.json) | [fab.cfg](./fab.cfg) |
| ArliMode | [ArliMode.json](./profiles/ArliMode.json) | [arli.cfg](./arli.cfg) |
| BrileMode | [BrileMode.json](./profiles/BrileMode.json) | [brile.cfg](./brile.cfg) |
| ArmlMode | [ArmlMode.json](./profiles/ArmlMode.json) | [arml.cfg](./arml.cfg) |
| OliMode | [OliMode.json](./profiles/OliMode.json) | [oli.cfg](./oli.cfg) |

`fab.cfg` was created from the older embedded `at.cfg`; the embedded content still serves as an offline fallback. Current cloud preferences may differ from the hardcoded starter defaults.

## Edit a profile

Click **Edit ArliMode settings** (or the equivalent button for any other profile) to change:

- Windows pointer speed (1–20), mouse acceleration.
- Requested resolution, refresh rate, NVIDIA Digital Vibrance.
- Whether to apply NVIDIA settings and launch apps.
- Optional CS2 sensitivity override (blank uses the value inside the CFG).
- Direct GitHub `.cfg` download URL. Each profile's CFG filename is fixed.

**Save Locally:** saves to `%LOCALAPPDATA%\CafeLauncher\profiles.json`. No GitHub login. Changes remain local and may be erased by Deep Freeze.

**Save & Sync to GitHub:** saves locally, then asks for a **fine-grained GitHub personal access token** restricted to this repository with **Contents: Read and write**. On success, the launcher updates `profiles/<ProfileName>.json` on `main`. It does not intentionally save the token. **Never enter a GitHub token on a shared café PC.**

The launcher fetches public cloud JSON when editing or applying a profile **unless it has unsynced local edits**. Those local edits take precedence until synced. Saving an edit does not immediately apply the PC settings: click the profile button to apply.

### Updating CFG binds and crosshair

**Save & Sync updates the profile's JSON settings, not the original `.cfg` file.** To update Arli's binds, crosshair, or other CS2 commands, edit `arli.cfg` in your local Git clone and push:

```powershell
git add arli.cfg
git commit -m "Update Arli config"
git push origin main
```

On the next ArliMode run with internet access, CafeLauncher fetches the latest public `arli.cfg` and installs it. No GitHub account/login is needed on that café PC. An optional JSON sensitivity override only changes the *installed copy*, not GitHub's source CFG.

## Additional features

- **Display fallback:** if exact width/height/Hz is not advertised, choose the highest advertised Hz at the preferred resolution; otherwise consider the current resolution. The launcher tests the candidate and logs whether it applied.
- **NVIDIA:** request Digital Vibrance, driver performance/G-SYNC-related values, and GPU full-screen scaling. PhysX GPU selection, scaling override checkbox, and confirmation of NVIDIA GUI state may still need manual action.
- **Detected apps:** Steam and libraries, CS2 (app 730) CFG folder, FACEIT AC, G HUB, Chrome, NVIDIA Control Panel, GPUs, monitor modes, mouse settings.
- **Play + Exec:** five independent green buttons beside the player profiles. Each button installs the current CFG then starts CS2 with `-applaunch 730 +exec <profile>.cfg`. No `localconfig.vdf` writes or Steam restart; persistent Steam launch options are never modified.
- **LAUNCH ALL:** opens Steam, FACEIT AC, FACEIT matchmaking, Spotify, G HUB, and Mouse Pointer Options. It is *not* a guaranteed Steam/FACEIT readiness checker.
- **Offline CFG fallback:** stored under `%LOCALAPPDATA%\CafeLauncher\cfg-cache`; also tries an adjacent or already installed CFG. FabMode can use bundled `at.cfg` content. First-time offline friend profiles without a cached CFG may be unable to install.

## Launcher auto-update

On startup or **Check for Updates**, the BAT compares `# CAFE_RELEASE=YYYY.MM.DD.N` against `main/cafe.bat`. If GitHub has a higher version, it asks before installing. Downloads are checked for size/Git blob hash and parsed for PowerShell syntax; then Windows line endings are normalized, a backup is stored, and the **local BAT** is replaced.

**Close and reopen** to run the updated version. The original Google Drive file is **not** modified; a Deep Freeze reboot may discard the local update.

Backups: `%LOCALAPPDATA%\CafeLauncher\backups`. If the original BAT cannot be overwritten, the replacement may be written to Downloads instead.

## Requirements, logs and troubleshooting

- Windows 10/11 with Windows PowerShell 5.1, `cmd.exe`, Windows Forms. NVIDIA hardware/driver is required for NVIDIA-specific operations; Steam/CS2/FACEIT/G HUB are only needed for their associated actions.
- Some café PCs restrict registry/display/driver changes and access to installed files. Respect the machine owner's policies.
- Main log: `%TEMP%\CafeLauncher.log` (also shown in LIVE LOGS). Startup parse failures: `%TEMP%\CafeLauncher-startup-error.log`.
- If a save isn't appearing on other PCs, check the editor's **unsynced local edits** status and whether GitHub sync succeeded.
- If the launcher stops working after an update, restore a `cafe-before-update-*.bat` backup or download a known-good BAT.

## Contributing / validation

Before publishing launcher changes, run these **from the repository root on Windows**:

```powershell
powershell.exe -NoProfile -File .\tools\Test-CafeLauncher.ps1
powershell.exe -NoProfile -File .\tools\Test-ProfileSave.ps1
powershell.exe -NoProfile -File .\tools\Test-SteamLaunchOptions.ps1
powershell.exe -NoProfile -File .\tools\Test-Graphics.ps1
```

[GitHub Actions](./.github/workflows/cafe-syntax.yml) runs the syntax and save regression tests for relevant pushes and PRs. These do **not** replace live Windows/NVIDIA/CS2 testing, and a failed workflow does not block pushes without separately configured branch rules. Keep `cafe.bat` in Windows CRLF format and increment the release marker for each launcher release.

For complete logic, source layout, data flow, and maintenance gotchas: **[context.md](./context.md)**.

## NVIDIA compatibility preflight (v2026.10.13.14)

Before applying NVIDIA gaming settings, CafeLauncher reads the installed NVIDIA GPU and Windows-reported driver version, identifies the available NVAPI driver DLL and its file version, detects classic or Microsoft Store NVIDIA Control Panel, and inspects the monitor's driver-advertised resolutions/refresh rates. The same read-only report is available from **Detect PC** and appears in LIVE LOGS when NVIDIA settings are applied.

Unsupported driver functions are handled independently: the launcher skips an unavailable NVAPI or display API but continues any supported actions, logging the reason. The existing resolution fallback chooses the highest advertised refresh at the requested resolution, or an available current-resolution mode if needed. **No driver is automatically installed or updated**, and existing FabMode/other preset values are unchanged. Compatibility still depends on each café PC's actual drivers, monitor, and Windows permissions.


## Superlight 1 / Superlight 2 safe device targeting (v2026.10.13.15)

For live DPI, CafeLauncher runs `logihub.exe --json list`, selects the detected `pro_x_wireless_mouse` (PRO X SUPERLIGHT 1) or `pro_x_2_wireless_mouse` (PRO X SUPERLIGHT 2), and passes that device's specific `--device` index to both `dpi set` and `dpi get`. If no supported mouse is detected or more than one supported mouse is connected, CafeLauncher logs a warning/error and does not change DPI. This prevents silently changing the wrong player's mouse. The same device-targeting guard has been added to the dormant onboard implementation, but the onboard GUI button remains commented out.

