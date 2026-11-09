# CafeLauncher — Codex Project Context

This file gives Codex and maintainers the operational context needed to work safely in this repository. **Always follow the checked-out source tree.** The generated state block below reports the launcher release marker, not whether that code has shipped to `main`.

<!-- BEGIN GENERATED LAUNCHER STATE -->
- Launcher release: `2026.11.08.9`
- Generated from the unique `# CAFE_RELEASE` marker in `cafe.bat` by `tools/Update-Context.ps1`.
<!-- END GENERATED LAUNCHER STATE -->

## Branch and shipping rules

- Continue work on the currently checked-out branch by default. Do not create a new branch for each task or change; create a branch only when the user explicitly asks for one. A branch is a line of development, not a substitute for a commit: keep related edits together on the current branch and make commits only when requested.

- `main` is the production source. A `codex/*`, `feature/*`, or other non-main branch is testing/development until merged. A feature present in a testing branch is **not** shipped just because it is documented here or pushed to GitHub.
- Describe behavior from the current checkout. When discussing release status, compare the current branch with `origin/main`; do not infer production behavior from branch-local code.
- The release marker reports the launcher file's version; it does not prove that the current branch's code has shipped to `main`.
- The main CafeLauncher validation workflow watches changes to `cafe.bat`. On `main`, if a launcher change did not change `CAFE_RELEASE`, it increments the date-based release marker, refreshes `README.md` and `context.md`, validates them, and commits the update. It then publishes that exact resulting commit to Google Drive. If a change already includes a release bump, it preserves that version. The workflow uses serialized release updates so closely spaced merges do not race each other.

## What this project is

CafeLauncher is a portable Windows internet-café setup launcher. The hybrid `cafe.bat` contains the PowerShell/WinForms app, profile actions, and embedded C# display/NVIDIA interop. `graphics/ApplyGraphics.ps1` is a separately hash-pinned module for editing the active Steam account's CS2 video settings. There is no compiled application build step.

## Backend integration in the current launcher

The client uses the CafeLauncherBackend API for profile, graphics, CFG, and graphics-history reads. When the API is unavailable, it reads the public `cafelauncher-backend-mirror` snapshot after checking the manifest hashes. A mirror revision older than the latest revision this PC has verified is rejected; mirror-sourced values require confirmation before Edit, Apply, Play + Exec, or Apply Graphics because the mirror may lag a backend update this PC has not seen. There is one cloud behavior; there is no GitHub-only mode switch. Active profile writes go only to the backend. The launcher keeps failed edits in a local pending queue, verifies a successful backend write by reading it back, and retries while open only with a sync token held in memory. A restart requires the token again. Pending edits left by the older GitHub-based launcher remain blocked until explicitly resolved.

The dashboard's top-right read-source label shows the most recent cloud source: Backend API, GitHub fallback, or local data when both cloud reads fail. GitHub API remaining-request status is visible only while the verified mirror is the active fallback.

This backend client ships on `main` through the existing Google Drive launcher file. Google Drive remains a launcher distribution mirror; it does not store profile data or proxy backend API requests. The updater and graphics module download still use the original `Cs-script` repository. The pinned graphics module can accept a preset supplied by the launcher, so Apply Graphics uses the backend or verified mirror preset. Keep backend deployment and launcher distribution as separate workflows.

Main project files:

- `AGENTS.md` — entry-point instructions Codex automatically reads; directs it to this context file.
- `cafe.bat` — launcher UI, profile persistence and sync, Windows/NVIDIA operations, module loader.
- `profiles/<ProfileName>.json` and `graphics/<ProfileName>.json` — retained profile/graphics files in this repository; the running launcher reads current cloud data from the backend API or its verified public mirror.
- `graphics/ApplyGraphics.ps1` — validated CS2 video settings editor and backup/replace logic.
- `tools/Test-*.ps1` — Windows PowerShell 5.1 tests, mostly fixture or mock based.
- `.github/workflows/cafe-syntax.yml` — Windows PowerShell validation in CI.

## Feature map

| Area | Implementation | Focused verification |
| --- | --- | --- |
| Profile editor, persistence, and backend sync | `cafe.bat`: `Show-ProfileEditor`, `Refresh-ProfileFromBackend`, `Sync-ProfileToBackend`, `Start-CafeBackendRetryHealthCheck` | `Test-ProfileSave.ps1`, `Test-BackendRetry.ps1`, `Test-BackendMirrorFreshness.ps1`, `Test-GitHubSyncAuth.ps1`, `Test-ProfileCfgSensitivity.ps1` |
| Profile and CFG history | `cafe.bat`: `Show-ProfileEditor`, `ConvertFrom-CafeBackendProfileHistory`, `Get-CafeBackendProfileHistoryRevision` | `Test-ProfileHistory.ps1` |
| CS2 graphics apply and history | `graphics/ApplyGraphics.ps1`; `cafe.bat`: `Invoke-GraphicsOnly`, `Get-ProfileGraphicsHistory`, backend/mirror history adapter | `Test-Graphics.ps1`, `Test-GraphicsHistory.ps1`, `Test-GraphicsHistoryAsync.ps1`, `Test-GraphicsHistoryUI.ps1`, `Test-NvidiaCompatibility.ps1`, `Test-NvidiaDvcFallback.ps1` |
| CS2 settings capture, Extras editor, and crosshair share-code import/preview | `cafe.bat`: `Get-CafeCS2GraphicsCapture`, `Get-CafeCS2UserConvarsCapture`, `Get-CafeCS2UserKeysCapture`, `ConvertFrom-CafeCS2UserConvarsText`, `ConvertFrom-CafeCS2UserKeysText`, `Show-CafeCS2CaptureOptionsDialog`, `Show-CafeCS2CaptureReviewDialog`, `Invoke-CafeCS2CaptureReview`, `Show-CafeCS2ExtrasDialog`, `ConvertFrom-CafeCS2CrosshairShareCode`, `ConvertTo-CafeCS2CrosshairPreviewModel`, `Draw-CafeCS2CrosshairPreview`, `Show-CafeCS2CrosshairPreviewDialog` | `Test-CS2GraphicsCapture.ps1`, `Test-CfgSensitivitySync.ps1`, `Test-CrosshairShareCode.ps1` |
| Steam/CS2 discovery and Play + Exec | `cafe.bat`: `Get-SteamLibraryRoots`, `Get-CS2SteamLaunchArguments`, `Start-CS2WithProfileCfg` | `Test-SteamPathDiscovery.ps1`, `Test-SteamLaunchOptions.ps1` |
| Workshop cleanup | `cafe.bat`: `Get-CafeWorkshopCleanupSnapshot`, `Remove-CafeWorkshopItems`, `Show-CafeWorkshopCleanupDialog` | `Test-WorkshopCleanup.ps1` |
| Logitech live DPI | `cafe.bat`: `Set-LogitechLiveDPI`, `Invoke-LogitechDPISetAndReadback` | `Test-LogitechDPI.ps1`, `Test-SuperlightDevice.ps1` |
| Action result reporting and fallback GitHub quota display | `cafe.bat`: `Set-StepResult`, `Write-Log`, `Add-LiveLogLine`, `Set-CafeGitHubRateLimitDisplay` | `Test-StepResults.ps1`, `Test-GitHubRateLimit.ps1` |

Use this map to locate the implementation and focused test. The full verification command list is below.

## Profile editor and CS2 graphics UI

`Show-ProfileEditor` contains one tab control. The **Mouse** tab contains Windows mouse controls and the per-profile **CS2 sensitivity** field, labeled separately from Windows pointer speed. Windows pointer speed choices display only their position from `1/11` through `11/11`; the underlying Windows speed values and apply behavior are unchanged. The selected profile's CFG is the only saved source of truth: Edit reads its `sensitivity` command from the backend or verified mirror, and Apply installs that CFG without a JSON override. Legacy `CS2Sensitivity` values in older profile JSON are ignored; exports omit the field. Every profile CFG must contain exactly one valid sensitivity command, checked on read, before Apply, and in CI.

Profile Apply and **Play + Exec** install the selected named CFG through `Install-ProfileCfg`. It validates the CFG sensitivity and installs a matching local or downloaded profile file with backup and hash verification; the retired standalone `at.cfg` workflow and embedded fallback are removed.

Typing a value or using **Capture CS2** stages a local pending CFG sensitivity. **Save Locally** keeps that draft in the local profile cache as `PendingCfgSensitivity`, never in the cloud profile JSON. **Save & Sync to Backend** previews and writes the selected CFG bundle, verifies its read-back, and then clears the draft. Capture CS2 is the explicit action that reads the active Steam account's saved sensitivity; opening Edit defaults to the selected profile CFG. The **CS2 / Apps** tab contains the CFG filename/URL, app launch options, and per-profile CS2 graphics controls for:

- CS2 resolution width and height, aspect ratio, fullscreen/windowed mode.
- Highest supported refresh or a user-selected exact Hz.
- NVIDIA scaling: stretch to fill, preserve aspect ratio, or center without scaling.
- NVIDIA profile Apply starts with a read-only capability scan for Windows display modes, Digital Vibrance, Hue, NVIDIA DRS settings, and display-scaling APIs. Unsupported or uncheckable operations are skipped and logged.
- Digital Vibrance uses the extended interface when available. Its legacy fallback queries the supported range, maps the requested percentage to that range, applies it, and verifies read-back. The legacy Digital Vibrance and Hue interfaces are private/undocumented; success is reported only after verification.
- DRS settings are handled individually: supported values are written and read back, while rejected or unavailable settings are reported. Display resolution uses advertised modes and verifies the selected mode. GPU scaling validates the topology, applies, and reads back.
- The global NVIDIA DRS apply also sets **Power management mode** to **Prefer maximum performance** and verifies persisted read-back, affecting all 3D applications. NVIDIA Low Latency Mode Ultra remains manual: the installed driver returned NVAPI status `-160` for both legacy setting reads and writes, and the test session was discarded without saving.
- PhysX processor selection, NVIDIA's scaling override checkbox, and the G-SYNC Control Panel checkbox remain manual because the launcher has no reliable supported setter. Profiles do not change brightness; NVIDIA Control Panel's default is 50%.
- While the profile editor is open, wheel messages over the active Mouse, NVIDIA / Display, or CS2 / Apps tab are intercepted and scroll that tab, including when the pointer is over an input or dropdown. The original message is consumed so the control cannot change its value or selection; the filter is removed when the editor closes.
- The editor shows a **Frame Pacing** section before **Presets**; captions and dropdown options match the CS2 menu. Each setting occupies its own full-width row, with its caption on the left and one control on the right. Anti-aliasing is one dropdown combining the existing `MSAASamples` and `CMAA` profile fields, with no schema change. Older saved values that are no longer offered remain visible as a preserved value until the user chooses a current menu option.

### Potential follow-up: verify CS2 preset application

- CS2 FSR values are reversed from the editor choice order in `setting.videocfg_fsr_detail`: editor/profile values remain `0=Disabled, 1=Performance, 2=Balanced, 3=Quality, 4=Ultra Quality`, while CS2 stores `0=Disabled, 1=Ultra Quality, 2=Quality, 3=Balanced, 4=Performance`. This was confirmed in-game: applying profile Performance (`1`) showed Ultra Quality, and applying profile Ultra Quality (`4`) showed Performance. `graphics/ApplyGraphics.ps1` translates on apply, and `ConvertFrom-CafeCS2VideoText` translates back on capture; the profile schema and existing profile meanings stay unchanged.
- For other suspect settings, confirm behavior against a config captured before and after changing each setting in CS2. If a selector alone does not apply the choice, map the profile choice to every required video-config field and make Capture read back those values. Keep profile JSON field names and established meanings stable.
- References: [CS2 Options Menu config guide](https://steamcommunity.com/sharedfiles/filedetails/?id=3046217806) (community guide; documents menu choices and associated config values); [ValveSoftware CS2 issue #4155](https://github.com/ValveSoftware/csgo-osx-linux/issues/4155) (issue report includes a `cs2_video.txt` sample); [sample `cs2_video.txt` on GitHub](https://github.com/gucu112/cs2-config/blob/master/cs2_video.txt). These are useful investigation references, not an official Valve specification of the setting callbacks.

Each profile's canonical preset is stored independently in `graphics/<ProfileName>.json`: `FabMode`, `ArliMode`, `ArmlMode`, `OliMode`, `BrileMode`, and `Provmode`. The editor validates and displays the selected profile's file; Apply Graphics validates that same profile name before using its settings.

- FabMode, ArliMode, ArmlMode, OliMode, and Provmode default to 1280×960 4:3 fullscreen. Provmode currently copies OliMode's profile and graphics values.
- BrileMode defaults to 1920×1080 16:9 fullscreen.
- Presets request the highest advertised refresh for the selected CS2 resolution. A saved 360 Hz value does not prove the monitor supports 360 Hz.

The editor can copy only CS2 graphics fields from another profile or reset current editor values from that profile's canonical preset. Copying starts with a **Choose a profile to copy from...** placeholder; **Copy graphics** stays disabled until another profile is selected. Neither action saves automatically. Apply Graphics reports confirmed/applied and changed fields, skipped fields, display-mode fallback details, NVIDIA scaling verification, and the backup path. Partial results are shown as warnings.

The **CS2 / Apps** editor's **Capture from CS2** action first asks which groups to read: **Graphics**, **Sensitivity**, **Crosshair**, **Viewmodel**, **HUD and Radar**, **Audio**, and individual bind groups for **Movement**, **Jump**, **Crouch**, **Walk**, **Use**, **Voice**, **Reload**, **Inspect**, **Scoreboard**, **Attack**, **Secondary attack**, **Drop**, **Weapon slots**, **Grenade keys**, and **Scroll wheel**. The **Viewmodel** group also includes supported `switchhands` binds.

- Capture requires CS2 to be closed. It reads selected values from the active Steam account's `cs2_video.txt`, `cs2_user_convars_0_slot0.vcfg`, `cs2_machine_convars.vcfg` (for Audio), and `cs2_user_keys_0_slot0.vcfg` as applicable, then rechecks the active account. Readers validate file sizes, supported names and values; missing entries leave the profile's current values alone.
- A review table compares the selected profile value with the saved CS2 value. Graphics options use readable choices (including the existing CS2-to-profile FSR mapping); console variables show their CS2 menu label and command name. Bind rows show the key, current profile action, captured action, and **Will replace** status for a key collision.
- The user can uncheck individual rows and choose **Import selected** or **Cancel**. Cancel leaves staged data unchanged. Import stages only accepted rows in the selected profile's editor state. Capture does not save, sync, or modify game files.
- Reviewed graphics values flow through the existing graphics preset controls. Reviewed console variables and binds stay pending for the selected profile CFG and use the existing Save Locally / Save & Sync flow, including the exact CFG diff confirmation before a remote write. Other CFG binds remain untouched; duplicate bindings for an imported key are rejected as ambiguous.
- When a reviewed graphics capture includes `RefreshHz`, importing it adds that field even if the current preset uses `Highest` and has no explicit refresh field; the resulting preset uses `Exact` with the captured rate.
- Supported console-variable groups include sensitivity, crosshair, grenade-crosshair, scope-dot, viewmodel, HUD/radar, and the explicit numeric/boolean audio set. The capture schema accepts supported values only after validation. Bind actions use an explicit allowlist for common movement, combat, interaction, weapon-slot, grenade-slot, voice, reload, and viewmodel hand-switch actions; scroll-wheel keys can use a single supported action. Explicit saved unbinds are reviewed when they match a supported current profile or launcher-baseline action. If a captured action is also still bound to another key that CS2 did not list, Capture shows an optional **Possible leftover** row that can be checked to clear the old key; the user decides whether to remove that old bind. Missing saved binds are never cleared automatically.
- When sensitivity is imported, it appears on the **Mouse** tab. A captured push-to-talk key also updates the profile's existing voice-key field so Save & Sync does not overwrite it with an older value.
- The implementation and parser/review fixtures are in `tools/Test-CS2GraphicsCapture.ps1` and `tools/Test-CfgSensitivitySync.ps1`; the graphics fixture retains FSR mapping checks.

### CS2 Extras editor

The **CS2 / Apps** profile editor has an **Edit Extras** action that opens a separate modal window with Crosshair, Viewmodel, HUD and Radar, Audio, and Binds sections. It reads the selected profile CFG plus the launcher's baseline, overlays any already-staged values, and shows CS2-style setting names beside command names. The convar catalog includes the supported capture names and recognized settings already in the selected profile CFG.

- Each setting can be edited directly; entering `0` is a real numeric value. Blank values and the **Reset selected to default**, **Reset section to defaults**, or **Reset selected group** buttons stage removal of that profile's override. Reset is stored as a separate pending sentinel and removes the matching CFG line during Save & Sync; it does not write `0` or `unbind`.
- Binds show the current profile action and editable action. Common movement, jump, crouch, walk, use, reload, voice, inspect, scoreboard, attack, drop, weapon-slot, grenade-slot, and scroll-wheel actions are available through an explicit action list.
- Scroll-wheel option lookup supports both profile hashtables and ordered staged bind maps.
- Staging bind replacements asks for confirmation and names the key/action changes. Moving push-to-talk identifies the old key that will be removed and keeps the profile's separate voice-key field in sync. Only one push-to-talk key may remain active.
- The existing **Push-to-talk key (CFG)** selector and Extras Binds editor share the same staged PTT choice. Extras displays the selector's current choice. If the selector disagrees with a staged PTT bind, saving removes that stale generic bind and sync uses the selected profile voice-key value; matching PTT actions staged by Extras or Capture remain intact. Explicit reset markers and unrelated staged binds are preserved.
- Extras stages into the same per-profile pending convar/bind maps as Capture CS2. It changes no CS2 files or remote data by itself. **Save Locally** persists the pending maps; **Save & Sync to Backend** applies them to the selected profile CFG with the existing exact diff confirmation and read-back verification.
- The CS2 / Apps editor's **Paste Viewmodel** action accepts semicolon/newline-separated commands for `viewmodel_fov`, `viewmodel_offset_x/y/z`, `viewmodel_presetpos` (0-2), `cl_prefer_lefthanded`, and safe `bind KEY switchhands` commands. It validates every command before staging anything, applies per-setting numeric ranges, and merges into that profile's pending CFG convars/binds while preserving other staged and saved values. Built-in presets cannot be mixed with custom offsets; selecting a built-in preset stages removal of custom viewmodel overrides, while custom values default to preset position 0. Hand-switch binds are staged without execution, and cannot take over the selected push-to-talk key. Repeated pastes update matching keys while retaining earlier ones; **Save Locally** or **Save & Sync** commits them through the existing profile flow. Pasted text is never executed as console input.
- Regression fixtures for CFG reset sentinels, numeric zero, added bind groups, and editor wiring are in `tools/Test-CfgSensitivitySync.ps1` and `tools/Test-CS2GraphicsCapture.ps1`.

The **Mouse** tab can also import a pasted crosshair share code offline. It supports legacy `CSGO-...` versions 1, 3, and 4 plus current `CS...` version 1, validates the base-57 code and checksum, and shows the decoded convars and conversion notes before staging. Share-code import merges decoded crosshair and scope-dot convars into the selected profile’s staged settings, preserving sensitivity and any other staged groups while incoming crosshair values replace matching staged crosshair keys. It changes no game files and waits for Save & Sync and the existing CFG diff confirmation before publishing. Legacy-v1 codes lack a source-resolution field and can only be approximated; weapon-dependent gap and retired outline thickness are called out when present.
- The decoder is a local PowerShell implementation based on the documented layouts in `akiver/csgo-sharecode` (MIT); CafeLauncher does not require Node.js or network access to decode. Attribution and license text are in `THIRD_PARTY_NOTICES.md`. Scope-dot and grenade-crosshair convars are supported by the selected profile CFG writer.

### CS2 crosshair visual preview

CafeLauncher adds a custom WinForms confirmation dialog before crosshair values are staged. `ConvertTo-CafeCS2CrosshairPreviewModel` validates the decoder output; `Draw-CafeCS2CrosshairPreview` draws using the panel's `Paint` event and .NET `System.Drawing`. It renders cross, circle, square, dot-only, and quadrant style families separately. Static Quadrant (style 9) uses the decoded quadrant-size ratio for four short diagonal ring arcs with outer radius `max(1, gap) + thickness`; length does not affect this style. `New-CafeCS2StaticQuadrantRaster` evaluates radial and angular edge coverage, fill and outline opacity, and linear-light color blending per native game pixel, then `Draw-CafeCS2CrosshairPreview` enlarges the raster with nearest-neighbor sampling. The geometry follows the MIT-licensed [`setposgg/cs2-crosshair`](https://github.com/setposgg/cs2-crosshair) port of the 2026-10-08 CS2 client; attribution is in `THIRD_PARTY_NOTICES.md`. The raster math was independently implemented after studying the public [crosshair.club renderer](https://crosshair.club/static/js/cs2-crosshair-render.js?v=1791479013), which reconstructs the September 30, 2026 game shader. For the user's style-9 share code, the 16×16 native RGBA raster on the solid Stone background matches that public renderer byte for byte. This validates agreement with the public reconstruction, not with a lossless CS2 capture. The dialog defaults to a warm stone color like the user's reference and also offers dark, light, and locally drawn foliage-like backgrounds. Dragging and recentering only move the preview; they do not change imported settings. **Import** stages values only after a successful initial paint; fixed-position preview labels are undocked so decoded settings and Import/Cancel remain visible. Canceling, closing the dialog, or a rendering error leaves the profile's staged values unchanged. Dynamic/recoil styles are shown at rest, and missing source resolution uses a labeled 1080p reference scale. Half outlines, non-quadrant styles, foliage compositing, screenshot scaling, and game postprocessing remain approximations. The implementation prompt and acceptance notes are in [`prompts/cs2-crosshair-visual-preview.md`](./prompts/cs2-crosshair-visual-preview.md).

The **CS2 / Apps** editor can load earlier graphics revisions from the backend history API, with validated mirror history as a fallback.

- The commit list is cached per profile for 24 hours; manual refresh bypasses the cache.
- Restore fetches and validates the chosen version, then fills the editor without saving or applying it. Saving or syncing remains a separate user action.
- History works offline only when the version is already listed in the fresh cache. Fetching an older preset requires internet.
- The background completion callback receives its profile and WinForms controls through the worker instance's `RequestContext` property; it does not depend on nested PowerShell closure captures. Empty history and HTTP 404 show the no-earlier-versions state, while other failures remain visible and retryable. The request URI and status are logged for diagnosis. `tools/Test-GraphicsHistoryUI.ps1` covers callback wiring and UI recovery. See [graphics history loading diagnosis](./GRAPHICS_HISTORY_LOADING_DIAGNOSIS.md).
- Mirror history lookup and URI validation are covered by `Test-GraphicsHistory.ps1`; normal history reads use the backend API.

### Profile and CFG history

The profile editor includes a **Profile + CFG history** section in the **CS2 / Apps** tab, beside the existing graphics controls. Its backend-only **Load history** / **Refresh history** request lists earlier saved revisions for the selected profile, omitting the current revision. If a refresh fails, the error remains visible and previously loaded choices remain available; the user can retry. There is no GitHub mirror history fallback for these bundle revisions.

**Restore selected version** fetches the chosen immutable backend revision, validates its profile, graphics, and CFG bundle, then stages the profile settings and CFG in the open editor. It leaves the CS2 graphics preset unchanged and does not directly write the local game CFG or backend. **Save Locally** persists the staged values as pending; **Save & Sync to Backend** reviews the CFG diff and creates a new backend revision. The staged CFG is persisted with pending local edits so it survives closing and reopening the launcher. `tools/Test-ProfileHistory.ps1` covers history validation, backend detail loading with a mock, CFG staging, and retry UI behavior.


Dashboard **Apply Graphics** is a separate action from the normal profile Apply and **Play + Exec** buttons. Saving in the editor does not apply the settings immediately.
- Each profile card orders its actions as 1.Apply profile, 2.Game Graphics, 3.Play + Settings, Edit profile, and Capture CS2, with a 12 px gap before Edit and Capture.
- The dashboard builds profile cards in the ordered `GamingProfiles` registry and displays five per page. Previous/Next changes only which cards are attached to the dashboard; it does not refresh profiles or make cloud requests. The sixth registered profile begins page 2. The current registry contains six profiles, so `Provmode` appears on page 2.
- Profile-row hover feedback is active only while the launcher is the active window and the Dashboard tab is selected. Deactivating the launcher clears any hover color immediately, including when a modal profile editor opens.
- The dashboard refreshes its initially selected `FabMode` from the backend or verified mirror before showing it. Edit, Apply, Play + Exec, and Graphics refresh the profile they act on. The selected-profile card distinguishes backend values, GitHub mirror values, local pending values, and local fallback values.
- Opening Edit fetches one complete profile/graphics/CFG snapshot and reuses it for the profile fields, graphics settings, sensitivity, and voice bind. If the backend read fails, that same open uses the one verified mirror snapshot; if both cloud sources fail, existing local fallback confirmations apply without repeating cloud reads.
- Normal Apply reads the selected profile's graphics preset through the same backend-first adapter and uses its `ScalingMode` as authoritative. Mirror-sourced data requires explicit confirmation before profile actions. Apply Graphics fetches the preset immediately before changing CS2 and also confirms mirror data; local fallback requires explicit confirmation.
- Before an action or editor open, `SyncPending` offers backend sync, deliberate discard after a fresh backend fetch, or cancel. Older GitHub pending edits are preserved and blocked until explicitly resolved. A failed backend or mirror read never silently discards local edits.
- Without pending edits, backend and mirror unavailability requires explicit confirmation before local fallback.

- The Mouse tab's pointer-speed editor uses the classic Windows Mouse Properties slider's 11 levels, mapped to the same underlying MouseSensitivity values (1, 2, 4, ..., 20). The apply logic remains unchanged. Existing custom intermediate values are retained unless the user actively chooses a dropdown level.

### Local persistence and backend sync

- **Save Locally** writes profile settings, `GraphicsSettings`, pending CFG sensitivity, and captured CS2 console variables/binds to `%LOCALAPPDATA%\CafeLauncher\profiles.json`. It marks that profile `SyncPending` with `PendingTarget=Backend` and saves the last verified backend revision.
- **Save & Sync to Backend** creates an atomic queue file under `%LOCALAPPDATA%\CafeLauncher\backend-pending\` before the network write. The bundle contains one profile, graphics preset, CFG text, and an expected revision. The backend sync token is held only in memory and never written to the queue or log. A restart requires fresh authorization.
- The sync uses `PUT /v1/profiles/{name}/sync`. The client reads the new backend bundle back and compares submitted values before clearing pending state. A failed write, conflict, or read-back mismatch keeps the local edit and queue for retry. A matching bundle after an interrupted response is treated as already accepted.
- While the launcher remains open with a token, an asynchronous health probe can trigger retry. A conflict requires user review; it must never overwrite automatically. The public GitHub mirror is a read fallback and is never a client write target.
- Pending edits saved by an older GitHub-based launcher are marked `GitHubLegacy` and block backend actions until the user resolves or exports them with the older launcher. They are never silently redirected.
- Profile, graphics, and CFG reads prefer the backend. If it fails, the client verifies mirror paths and SHA-256 hashes from one mirror manifest before using the snapshot. A mirror revision below the last verified profile revision saved on this PC is rejected to prevent a known rollback. A mirror can still be behind an unseen backend update, so the launcher requires explicit confirmation before using it for an action. If both cloud reads fail, local fallback remains available only through the existing confirmation paths. Apply Graphics uses a launcher-supplied preset from this source order; the separate module remains hash pinned.
- The backend stores profile and graphics data at `profiles/<ProfileName>.json` and `graphics/<ProfileName>.json`; these paths are mirrored publicly with the CFG and graphics history.
- The CFG stays authoritative for sensitivity. A selected CFG write previews exact line changes, preserves unrelated commands and binds, and is verified by backend read-back. Crosshair alias migration remains: `cl_crosshairgap` → `cl_crosshair_gap`, `cl_crosshairsize` → `cl_crosshair_length`, and `cl_crosshairthickness` → `cl_crosshair_thickness`.
- The pointer-speed editor preserves a nonstandard saved value when its dropdown is unchanged; if a standard choice differs from the initial value, it saves that choice even if WinForms did not raise the selection event.

## Runtime behavior and safety boundaries

- Startup PC detection is informational. It must not change monitor settings.
- A normal profile Apply refreshes the selected profile immediately before applying mouse/NVIDIA settings, installing its CFG, and optionally launching configured apps. Play + Exec also refreshes the selected profile before installing its CFG. Neither starts CS2 with normal profile Apply nor writes persistent Steam launch options.
- `Launch-ProfileApps` is the shared app-launch routine. When Launch Apps is enabled, applying any profile (FabMode, ArliMode, BrileMode, ArmlMode, OliMode, or Provmode) passes its name and opens `https://metastack.gg/` instead of Spotify. The standalone Launch All action calls the routine without a profile name and still opens Spotify; the separate Spotify tile is unchanged. Profile Apply continues to skip G HUB.
- **Launch All** and the manual **Change DPI** input/button are in **Tools & Apps**. The DPI panel matches the other tool tiles at 198×58 px, with a compact input beside its action button. Manual DPI still validates the entered value and applies it through the existing Logitech action.
- Run summaries report step totals and per-setting requested values, targets, outcomes, and verified values where available. NVIDIA scaling entries include profile, human-readable mode and NVAPI mode number, Windows display target, outcome, and NVAPI result/read-back or failure detail.
- LIVE LOGS keeps successful per-setting rows compact; full requested, target, actual, and detail fields remain in `%TEMP%\CafeLauncher.log`. The viewer uses one row per entry, horizontal scrolling, status/value colors, and bold profile/action names. Selected text can be copied with Ctrl+C or the right-click **Copy** menu item.
- The viewer loads current-session entries and available retained history (up to 2,000 lines) the first time **Show Logs** is opened, using a byte-length snapshot of the current log file. A background task seeks from the end of the snapshot and reads only the last 2,000 physical lines, folding multiline entries without holding the log-write lock. A WinForms timer polls task completion and appends up to 15 formatted entries per tick, so loading does not depend on a background-worker completion callback and the dashboard stays responsive. Log writes made during loading are queued and appended after the snapshot, and Clear Logs is disabled until loading completes. If reading or display fails, the next open retries. The session log retains the last 2,000 lines across launches, including exception stack traces. Startup exceptions are appended so a manual reopen preserves automatic-restart failures.
- Apply Graphics writes its field-level result summary to the same logs and shows a result dialog. No separate history file is created.
- **Send Logs** beside LIVE LOGS uploads `%TEMP%\CafeLauncher.log` as a raw Sentry Envelope attachment only after the user presses the button. It compiles a small C# `BackgroundWorker` and uses .NET Framework `HttpWebRequest`; there is no Sentry SDK or startup Sentry activity.
- The DSN is a public, send-only project identifier set in `cafe.bat`; no café user login or persistent credential is required. Each press uses a distinct event ID and fingerprint. On HTTP success, the UI displays the report ID; on failure, the log stays local.
- The launcher does not enforce an upload size limit or filter usernames and paths. Sentry's own limits apply. Email notifications are configured in Sentry; the email does not contain the raw attachment. The configured alert target and notification setup are maintained in Sentry.
- Apply Graphics marks `panelOverride=not-read-or-set` in the NVIDIA scaling log. The launcher cannot verify or toggle NVIDIA Control Panel's “Override the scaling mode set by games and programs” checkbox.
- A successful NVAPI mode-2 read-back confirms GPU scaling at Apply time. It does not confirm the checkbox is enabled or that CS2 retained the mode at launch.
- If CS2 opens with black bars, compare the applied resolution/aspect and display target, then check the override checkbox manually. The launcher does not monitor manual CS2 launches.
- Steam/CS2 discovery checks registry and running-client locations, Steam `libraryfolders.vdf`, and a revalidated local library-path cache. Disconnected mapped drives are skipped. The launcher validates `appmanifest_730.acf` (`appid`, safe `installdir`) and expected CS2 folders.
- If the CFG folder is relocated, discovery searches at most 1,200 directories and depth 8 inside a confirmed CS2 install. A missing or ambiguous install is never auto-selected: interactive install asks the user to choose and confirm the exact existing `game\csgo\cfg` path; silent profile Apply skips and logs the reason.
- CFGs go in the confirmed game install; `cs2_video.txt` goes under the current Steam account's `userdata` tree. Steam executable discovery prioritizes the running client so graphics account IDs match the active client path. CFG writes are SHA-256 verified; graphics writes recheck account and path before replacement.
- **Play + Exec** installs `cafelauncher_profile_baseline.cfg` with captured defaults for profile-managed binds, radar, sensitivity, FPS, and visibility, and enables the developer console with `con_enable 1`. The baseline does not set crosshair values. The selected profile CFG runs last and sets a crosshair only if it contains crosshair commands; ArliMode, OliMode, and ArmlMode intentionally leave theirs unset until each player's settings are confirmed.
- Bind defaults come from installed `user_keys_default.vcfg` when the user's key override file is empty. `r_low_latency` is not guessed from reset values; each profile CFG explicitly sets it to `2` after the baseline.
- Steam launches with `+exec cafelauncher_profile_baseline.cfg +exec <profile>.cfg`, so the selected profile runs last. This clears omitted profile binds such as ArliMode's `MWHEELDOWN` and `CAPSLOCK` leftovers without `unbindall`; the baseline is limited to profile-managed settings.
- If CS2 is already running, the app refreshes/installs the selected CFG and presents both console `exec` commands in order. If the console is off, enable it in Settings > Game first. This action does not persist Steam launch options or apply mouse/display settings.
- Logitech live DPI uses BetterLogiHub and validates the selected mouse identity before writes and read-backs.
- The standalone dashboard Change DPI field starts blank because it is independent of saved profiles; entering a supported whole-number DPI is required before applying it.
- If the ordinary operation fails, only the original PRO X SUPERLIGHT (`pro_x_wireless_mouse`) gets a host-mode fallback: recheck the mouse and current mode, switch to host only when needed, verify the mode, retry DPI, and verify the requested value.
- A successful fallback leaves the mouse in host mode. If it fails after a mode switch, the launcher attempts and verifies restoration to onboard mode. The PRO X SUPERLIGHT 2 keeps its helper-specific behavior.
- The fallback does not write onboard DPI memory. Reconnect-triggered reapply remains deferred.
- **Possible later Superlight 1 fallback (not implemented):** investigate only if both BetterLogiHub live DPI paths fail. OpenMouse's `mouse-protocol` project has a Logitech HID++ implementation. Its supported-device list identifies the original G Pro X Superlight as PID `0xc094` (also called `PRO X Wireless`, product ID `4093`) and lists HID++ direct support.
- The useful reference is the Logitech protocol package/driver (`@openmouse/protocol/logitech`), not its browser UI. It is not a drop-in Windows helper; integration would need a Windows HID++ transport or native helper, runtime feature discovery, exact model targeting, serialized commands, DPI range validation, and read-back.
- Begin with read-only detection, then test one live DPI write on the exact SL1 hardware. OpenMouse documents live DPI as host-mode/volatile; do not write onboard profile memory. The SL1 uses profile format 4; do not reuse the Superlight 2 format-7 layout.
- The upstream `mouse-protocol` license is AGPL-3.0-or-later. Before adapting it into a redistributed build, retain required notices and review source and distribution obligations. This is a research lead; do not implement automatically.
- **Apply Graphics** requires CS2 to be closed, detects the active Steam account at the write boundary, changes only recognized keys in that account's `cs2_video.txt`, backs up before replacing, verifies the result, and restores on failure where possible.
- The CS2 refresh choice applies to the selected **game resolution**, independently of Windows desktop resolution. `Highest` chooses the highest advertised progressive rate for that resolution. `Exact` applies only if the exact resolution/Hz is advertised; otherwise it preserves existing display values and reports why.
- NVIDIA preflight defines overall NVAPI availability by calling `NvAPI_Initialize` and balancing a successful initialization with `NvAPI_Unload`; the DLL path is used only for version reporting. Per-setting capability probes still verify each operation independently. Tests do not prove live hardware behavior. Do not perform live mouse, DPI, display, or other device writes as a test without user authorization.
- Workshop Cleanup is a separate **Tools & Apps** action. Its behavior and safeguards are described in [CS2 Workshop Cleanup](#cs2-workshop-cleanup).
- **Deferred TODO — reconnect-triggered DPI reapply (do not implement unless explicitly requested):**
  - Listen for Windows mouse/receiver disconnect and reconnect notifications, then re-detect the supported mouse and reapply the selected profile's live DPI with a small bounded retry count.
  - Avoid constant polling, identify the mouse rather than only its receiver, and log a clear result if it does not reconnect.
  - Do not start implementation, add background monitoring, or change DPI behavior without an explicit request.
- **Deferred TODO — ZOWIE DyAc Premium control (not implemented):**
  - Investigate an explicit action for DyAc/DyAc 2 Premium on supported BenQ ZOWIE monitors. Verify the exact monitor model and whether the official XL Setting to Share `.mccs` profile pathway supports the setting.
  - Prefer supported profile/software mechanisms over undocumented DDC/CI writes. Keep startup detection informational; report when a model or setting cannot be verified.
  - Do not change monitor OSD settings automatically during detection or normal Apply.
- **Deferred TODO — PC diagnostics Steam discovery optimization (not implemented):** Discover Steam library roots once per on-demand PC scan and reuse them for Steam/CS2 lookup. Rediscover them on later scans so moved or newly added libraries are found.
- **Startup & API Timings** is a dashboard tool backed by a per-launch in-memory trace. It reports the app-observed time to dashboard readiness and startup-path completion, plus launcher initialization sub-stages, dashboard layout/helper/action-tile/profile-card/DPI/log setup phases, retained log hydration, on-demand PC diagnostics, automatic update-check dispatch, and HTTP/API request spans. Initial profile commit and content requests are named with the profile and grouped as startup work. Later profile refreshes remain grouped as later work. Each request shows its host/path without query strings, individual elapsed wait, outcome, and HTTP status where available; overlapping operations remain individual spans and are not summed as sequential work.
- The trace starts before dashboard initialization, retains at most the latest 500 operations, and stores no request/response bodies, credentials, device codes, query data, profile contents, or full account identifiers. It is neither persisted nor uploaded. Opening or refreshing the timing dialog reads the in-memory snapshot and makes no network requests. Requests performed in the separate Logitech helper process are shown as app-observed external-process wait time, including helper verification overhead.
- `tools/Test-StartupApiTimings.ps1` checks delayed and failed mocked operations, parallel overlap, startup/later grouping, startup totals, query-secret removal, and that the dialog adds no requests. It does not launch the app or contact a network service.
- Never store GitHub tokens in files, logs, or profile JSON. Do not enter a token on a shared café PC.

## CS2 Workshop Cleanup

The standalone **Workshop Cleanup** tile appears only in **Tools & Apps**. It is separate from dashboard profiles, startup detection, profile Apply, and CS2 launch. It operates only on CS2 App ID `730` and local `<SteamLibrary>\steamapps\workshop\content\730\<WorkshopID>` directories.

### Scan and classification

- The scan requires one running Steam client with a signed-in account. It reads subscription IDs through Steamworks `ISteamUGC::GetSubscribedItems` in the installed CS2 Steamworks runtime and verifies the active account before and after the call.
- Local `appworkshop_730.acf` files do not establish subscription state. CafeLauncher parses them to validate app ID, installed state, download/update flags, and manifest stability.
- Steam's ACF format is undocumented. If Steamworks state is unavailable or a library containing CS2 Workshop data has an untrusted manifest, disable all cleanup candidates.
- Public `GetPublishedFileDetails` metadata supplies optional titles/descriptions only. Failed metadata requests fall back to numeric IDs and do not affect cleanup classification.
- Unsubscribed manifest entries whose content folders are already missing appear as zero-size candidates.

### Selection and removal safeguards

- The dialog lists Workshop name, ID, description, estimated size, and keep/removable/unknown status.
- **Select all** and **Select unsubscribed** are separate controls. Both select only safe candidates; the latter filters by the active-account Steamworks subscription result.
- Subscribed IDs are protected across detected libraries. Unknown items and items containing reparse points cannot be selected. Manifest download/update flags or nonempty Steam download/temp directories block cleanup.
- The user confirms the exact count, IDs, and estimated total. Immediately before removal, CafeLauncher rescans the account, subscriptions, and manifests, compares the state signature with the preview, requires CS2 to be closed, and rechecks paths and contents.
- Removal deletes only the selected numeric-ID directories. It never changes subscriptions. When manifest records are also removed, CafeLauncher atomically removes only the selected unsubscribed IDs from `WorkshopItemsInstalled` and `WorkshopItemDetails`, creates a timestamped `.bak`, and verifies the updated VDF before replacing Steam's file.
- Scan and removal outcomes are logged without credentials or full account identifiers.

### Verification

`tools/Test-WorkshopCleanup.ps1` covers VDF parsing, the stale details-versus-subscription regression, metadata decoding/app validation, selection filters, subscribed-item protection, multi-library keep behavior, incomplete/busy manifest refusal, account/subscription/manifest rechecks, confirmation gating, path containment, and selected-folder-only removal.

- The fixture test uses temporary data only; it does not touch live Workshop data.
- A real-account scan-only comparison remains a live smoke test because Steam may not be signed in on the development workstation.

Repository workflow, protected file requirements, and documentation maintenance rules are in [`AGENTS.md`](./AGENTS.md).

## Verification

Run from the repository root in Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-CafeLauncher.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-StartupApiTimings.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-ContextFreshness.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-GitHubSyncAuth.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-GitHubRateLimit.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-ProfileSave.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-BackendRetry.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-BackendMirrorFreshness.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-CfgSensitivitySync.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-ProfileCfgSensitivity.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-CrosshairShareCode.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-Graphics.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-GraphicsHistory.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-GraphicsHistoryAsync.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-NvidiaCompatibility.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-NvidiaDvcFallback.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-SteamPathDiscovery.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-WorkshopCleanup.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-CS2GraphicsCapture.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-EditorComboWheel.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-LogitechDPI.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-SteamLaunchOptions.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-SuperlightDevice.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-StepResults.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Update-Context.ps1 -Check
```

GitHub Actions runs these Windows PowerShell 5.1 checks in the existing Profiles and CS2 jobs:

- Backend sync authorization and CS2 graphics capture.
- Graphics history, including its async worker, and Steam/CS2 path discovery.

Changes to those test scripts trigger CI on pull requests and pushes to `main`.

The `publish-drive` job runs after all five validation jobs for pushes to `main` and manual dispatches from `main`.

- It skips pushes that did not change `cafe.bat`.
- When configured, it posts the validated release to the Apps Script endpoint in `tools/google-drive-sync/Code.gs`. The script updates the existing `cafe.bat` in the configured Drive folder in place, preserving its Drive file ID and folder link.

The checks cover:

- Parser/formatting and profile Apply's backend-or-verified-mirror graphics scaling authority and fail-closed behavior.
- Mocked local persistence and the legacy GitHub sync helper; backend sync authorization and in-memory token handling without network or GUI.
- Per-profile CFG sensitivity presence/format, CFG-backed editor/apply contracts, and legacy JSON-field removal.
- Graphics fixtures, legacy DVC range mapping without hardware writes, read-only NVIDIA capability inventory, mocked Steam launch arguments, and status reporting.

A real CS2/Steam account and monitor smoke test remains separate.

## Per-profile optional website (2026.10.30.3)

Edit Profile > CS2 / Apps exposes a custom website URL and enable checkbox. Apply with Launch Apps opens FACEIT Matchmaking, then the validated per-profile URL only if enabled. The URL and enabled flag persist through the existing local/cloud profile JSON export/import. Old profiles default to Metastack with the second website enabled. Standalone Launch All retains Spotify. Invalid imported URLs are ignored, and launch-time validation falls back to Metastack. The release number is generated from cafe.bat.

## CS2 update watch

`.github/workflows/cs2-update-watch.yml` runs the standalone Python watch on a GitHub-hosted runner at 07:17, 15:17, and 23:17 Europe/Tirane. It checks Valve's release-note feed and Steam announcement RSS, matches their announcement IDs, and uses rules to identify changes that may affect the launcher. Each run logs the count from each source before deduplicating. The rules cover profile CFG execution and settings, graphics apply and capture, Steam launch and install discovery, and Workshop Cleanup dependencies. Only qualifying changes produce email. It does not run on café PCs or use GitHub REST/GraphQL or an AI API.

Setup on the default branch:

1. In **Settings > Secrets and variables > Actions**, set `SMTP_HOST`, `SMTP_PORT` (465 for TLS or 587 for STARTTLS), `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM` and `SMTP_TO` as repository secrets. Use SMTP credentials supported by the email provider.
2. In **Actions > CafeLauncher CS2 update watch**, run `dry-run` to preview findings, then `test-email` to verify delivery. Neither mode updates alert history.
3. Set the Actions variable `CS2_WATCH_ENABLED` to `true`. Run `live` manually or wait for the next scheduled check. The workflow uses its built-in token to create and update the `cs2-watch-state` branch through Git. That branch contains only a timestamp and announcement fingerprints. If branch rules apply, permit the workflow to write to this branch.
4. Run the live check again to verify that previously emailed changes stay quiet. If switching from the ChatGPT watch, pause it once GitHub delivery is verified.

The initial alert window is 24 hours. Subsequent checks resume from the last successful check and revisit at least two weeks of notes for edits. A fetch or SMTP failure keeps the previous window available for retry. Runs are serialized. If SMTP accepts an email and Git then fails to persist its receipt, retrying can send that email again. Rules may miss changes that Valve describes without naming an affected setting or behavior.

Run the focused tests with `python3 -B -m unittest discover -s scripts -p 'test_cs2_update_watch.py'`.

## CS2 editor layout

In CS2 / Apps, Extras occupies row 28 and optional website controls occupy rows 29–30, preventing overlap with the reviewed CS2 capture controls. The update-watch workflow and scripts are part of the launcher repository.
