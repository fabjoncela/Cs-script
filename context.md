# CafeLauncher — Codex Project Context

This file gives Codex and maintainers the operational context needed to work safely in this repository. **Always follow the checked-out source tree.** The generated state block below reports the launcher release marker, not whether that code has shipped to `main`.

<!-- BEGIN GENERATED LAUNCHER STATE -->
- Launcher release: `2026.10.30.2`
- Generated from the unique `# CAFE_RELEASE` marker in `cafe.bat` by `tools/Update-Context.ps1`.
<!-- END GENERATED LAUNCHER STATE -->

## Branch and shipping rules

- `main` is the production source. A `codex/*`, `feature/*`, or other non-main branch is testing/development until merged. A feature present in a testing branch is **not** shipped just because it is documented here or pushed to GitHub.
- Describe behavior from the current checkout. When discussing release status, compare the current branch with `origin/main`; do not infer production behavior from branch-local code.
- The release marker reports the launcher file's version; it does not prove that the current branch's code has shipped to `main`.

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

## Feature map

| Area | Implementation | Focused verification |
| --- | --- | --- |
| Profile editor, persistence, and GitHub sync | `cafe.bat`: `Show-ProfileEditor`, `Refresh-ProfileFromGitHub`, `Sync-ProfileToGitHub` | `Test-ProfileSave.ps1`, `Test-GitHubSyncAuth.ps1`, `Test-CfgSensitivitySync.ps1`, `Test-ProfileCfgSensitivity.ps1` |
| CS2 graphics apply and history | `graphics/ApplyGraphics.ps1`; `cafe.bat`: `Invoke-GraphicsOnly`, `Get-ProfileGraphicsHistory` | `Test-Graphics.ps1`, `Test-GraphicsHistory.ps1`, `Test-NvidiaCompatibility.ps1`, `Test-NvidiaDvcFallback.ps1` |
| CS2 settings capture and crosshair share-code import/preview | `cafe.bat`: `Get-CafeCS2GraphicsCapture`, `Get-CafeCS2UserConvarsCapture`, `ConvertFrom-CafeCS2CrosshairShareCode`, `ConvertTo-CafeCS2CrosshairPreviewModel`, `Draw-CafeCS2CrosshairPreview`, `Show-CafeCS2CrosshairPreviewDialog` | `Test-CS2GraphicsCapture.ps1`, `Test-CrosshairShareCode.ps1` |
| Steam/CS2 discovery and Play + Exec | `cafe.bat`: `Get-SteamLibraryRoots`, `Get-CS2SteamLaunchArguments`, `Start-CS2WithProfileCfg` | `Test-SteamPathDiscovery.ps1`, `Test-SteamLaunchOptions.ps1` |
| Workshop cleanup | `cafe.bat`: `Get-CafeWorkshopCleanupSnapshot`, `Remove-CafeWorkshopItems`, `Show-CafeWorkshopCleanupDialog` | `Test-WorkshopCleanup.ps1` |
| Logitech live DPI | `cafe.bat`: `Set-LogitechLiveDPI`, `Invoke-LogitechDPISetAndReadback` | `Test-LogitechDPI.ps1`, `Test-SuperlightDevice.ps1` |
| Action result reporting and GitHub quota display | `cafe.bat`: `Set-StepResult`, `Write-Log`, `Add-LiveLogLine`, `Set-CafeGitHubRateLimitDisplay` | `Test-StepResults.ps1`, `Test-GitHubRateLimit.ps1` |

Use this map to locate the implementation and focused test. The full verification command list is below.

## Profile editor and CS2 graphics UI

`Show-ProfileEditor` contains one tab control. The **Mouse** tab contains Windows mouse controls and the per-profile **CS2 sensitivity** field, labeled separately from Windows pointer speed. The selected profile's CFG is the only saved source of truth: Edit reads its `sensitivity` command from the validated GitHub Contents API, and Apply installs that CFG without a JSON override. Legacy `CS2Sensitivity` values in older profile JSON are ignored; exports omit the field. Every profile CFG must contain exactly one valid sensitivity command, checked on read, before Apply, and in CI.

Profile Apply and **Play + Exec** install the selected named CFG through `Install-ProfileCfg`. It validates the CFG sensitivity and installs a matching local or downloaded profile file with backup and hash verification; the retired standalone `at.cfg` workflow and embedded fallback are removed.

Typing a value or using **Capture CS2** stages a local pending CFG sensitivity. **Save Locally** keeps that draft in the local profile cache as `PendingCfgSensitivity`, never in the cloud profile JSON. **Save & Sync** previews and writes the selected CFG, verifies its read-back, and then clears the draft. Capture CS2 is the explicit action that reads the active Steam account's saved sensitivity; opening Edit defaults to the selected profile CFG. The **CS2 / Apps** tab contains the CFG filename/URL, app launch options, and per-profile CS2 graphics controls for:

- CS2 resolution width and height, aspect ratio, fullscreen/windowed mode.
- Highest supported refresh or a user-selected exact Hz.
- NVIDIA scaling: stretch to fill, preserve aspect ratio, or center without scaling.
- NVIDIA profile Apply starts with a read-only capability scan for Windows display modes, Digital Vibrance, Hue, NVIDIA DRS settings, and display-scaling APIs. Unsupported or uncheckable operations are skipped and logged.
- Digital Vibrance uses the extended interface when available. Its legacy fallback queries the supported range, maps the requested percentage to that range, applies it, and verifies read-back. The legacy Digital Vibrance and Hue interfaces are private/undocumented; success is reported only after verification.
- DRS settings are handled individually: supported values are written and read back, while rejected or unavailable settings are reported. Display resolution uses advertised modes and verifies the selected mode. GPU scaling validates the topology, applies, and reads back.
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

The **CS2 / Apps** editor can capture saved settings from the running Steam client's active account after CS2 is closed.

- Video capture reads only that account's `userdata/<id>/730/local/cfg/cs2_video.txt`, rechecks the active account after reading, validates recognized keys and ranges, converts refresh numerator/denominator to whole Hz, and preserves profile values for missing settings.
- It imports CS2 resolution, aspect, fullscreen, and supported video quality values. NVIDIA scaling is outside `cs2_video.txt`, so the profile's current scaling value is retained.
- It also captures sensitivity and every saved `cl_crosshair*` user-convar with a numeric or boolean value; new crosshair convars do not need an allowlist update. In-game CFG binds are not captured.
- When saved `sensitivity` is captured, it replaces the selected profile's staged sensitivity in the **Mouse** tab. Capture alone does not save or sync it; the user reviews the values and chooses Save Locally or Save & Sync.
- Capture does not edit game files or sync immediately. The user reviews the imported values, then chooses Save Locally or Save & Sync. Captured convars stay staged under the selected profile until sync.
- The Mouse tab can import a pasted crosshair share code offline. It supports legacy `CSGO-...` versions 1, 3, and 4 plus current `CS...` version 1, validates the base-57 code and checksum, and shows the decoded convars and conversion notes before staging.
- Share-code import stages crosshair and scope-dot convars for only the selected profile. It preserves an already staged sensitivity value, changes no game files, and waits for Save & Sync and the existing CFG diff confirmation before publishing. Legacy-v1 codes lack a source-resolution field and can only be approximated; weapon-dependent gap and retired outline thickness are called out when present.
- The decoder is a local PowerShell implementation based on the documented layouts in `akiver/csgo-sharecode` (MIT); CafeLauncher does not require Node.js or network access to decode. Attribution and license text are in `THIRD_PARTY_NOTICES.md`. Current scope-dot convars are allowed through the selected profile CFG writer.

### Planned: Capture CS2 group selection and review (not implemented)

Extend the existing **Capture CS2** action in the selected profile editor with a review step before settings are staged.

- On click, show a group-selection dialog with **Graphics**, **Sensitivity**, **Crosshair**, **Viewmodel**, **HUD and Radar**, **Audio**, and **Binds**. Under **Binds**, allow selecting the supported actions/keys: jump, voice, reload, grenade keys, and scroll wheel.
- After the user continues, require CS2 to be closed. Read only the selected settings from the active Steam account's saved files: `cs2_video.txt` for graphics, `cs2_user_convars_0_slot0.vcfg` for console variables, and `cs2_user_keys_0_slot0.vcfg` for binds. Recheck the active account after reading, validate supported fields and ranges, and preserve existing profile values for missing or unsupported settings.
- Show a review window before importing. Compare the current selected-profile value with the captured value. Use names that match CS2's menu labels where available (for example **Global Shadow Quality**, **Viewmodel FOV**, **Radar Scale**, and **Master Volume**), and show the console-variable name in smaller text where useful. Display graphics choices as readable labels, including the existing FSR value translation.
- For each selected bind, show the key, its current action in the selected profile CFG, and the captured action. Label a key collision **Will replace** and show both actions. Preserve unrelated CFG lines. If the profile CFG has duplicate or ambiguous bindings for a key, require review rather than guessing. Represent an explicit saved unbind when the source file supports it; never infer an unbind from a missing entry.
- Provide **Import selected** and **Cancel**. Only **Import selected** stages the reviewed values for the selected profile. Canceling or closing the window leaves all prior staged values unchanged.
- Keep the existing **Save Locally** / **Save & Sync** workflow. Route reviewed graphics through the existing graphics preset staging, and reviewed console variables/binds through the selected profile CFG staging and existing CFG diff confirmation. Capture itself must not edit CS2 files, save locally, authorize GitHub, or sync.
- Extend fixture-based verification for each saved-file parser; readable value conversion; CS2-running rejection; account changes during capture; partial/missing values; quoted and duplicate binds; same-key replacement previews; explicit unbind handling; and cancel-versus-import staging behavior. Retain the current FSR capture mapping coverage.

### CS2 crosshair visual preview

CafeLauncher adds a custom WinForms confirmation dialog before crosshair values are staged. `ConvertTo-CafeCS2CrosshairPreviewModel` validates the decoder output; `Draw-CafeCS2CrosshairPreview` draws using the panel's `Paint` event and .NET `System.Drawing`. It renders cross, circle, square, dot-only, and quadrant style families separately. Static Quadrant (style 9) uses the decoded quadrant-size ratio for four short diagonal ring arcs with outer radius `max(1, gap) + thickness`; length does not affect this style. `New-CafeCS2StaticQuadrantRaster` evaluates radial and angular edge coverage, fill and outline opacity, and linear-light color blending per native game pixel, then `Draw-CafeCS2CrosshairPreview` enlarges the raster with nearest-neighbor sampling. The geometry follows the MIT-licensed [`setposgg/cs2-crosshair`](https://github.com/setposgg/cs2-crosshair) port of the 2026-10-08 CS2 client; attribution is in `THIRD_PARTY_NOTICES.md`. The raster math was independently implemented after studying the public [crosshair.club renderer](https://crosshair.club/static/js/cs2-crosshair-render.js?v=1791479013), which reconstructs the September 30, 2026 game shader. For the user's style-9 share code, the 16×16 native RGBA raster on the solid Stone background matches that public renderer byte for byte. This validates agreement with the public reconstruction, not with a lossless CS2 capture. The dialog defaults to a warm stone color like the user's reference and also offers dark, light, and locally drawn foliage-like backgrounds. Dragging and recentering only move the preview; they do not change imported settings. **Import** stages values only after a successful initial paint; fixed-position preview labels are undocked so decoded settings and Import/Cancel remain visible. Canceling, closing the dialog, or a rendering error leaves the profile's staged values unchanged. Dynamic/recoil styles are shown at rest, and missing source resolution uses a labeled 1080p reference scale. Half outlines, non-quadrant styles, foliage compositing, screenshot scaling, and game postprocessing remain approximations. The implementation prompt and acceptance notes are in [`prompts/cs2-crosshair-visual-preview.md`](./prompts/cs2-crosshair-visual-preview.md).

The **CS2 / Apps** editor can load the three previous versions of `graphics/<ProfileName>.json` from GitHub commit history.

- The commit list is cached per profile for 24 hours; manual refresh bypasses the cache.
- Restore fetches and validates the chosen version, then fills the editor without saving or applying it. Saving or syncing remains a separate user action.
- History works offline only when the version is already listed in the fresh cache. Fetching an older preset requires internet.

### Planned: Profile graphics, settings, and crosshair history (not implemented)

Preliminary review of the current `main` source found that **Load history** covers only `graphics/<ProfileName>.json`. It does not provide history for `profiles/<ProfileName>.json` or the profile CFG that stores CS2 sensitivity and crosshair convars. GitHub currently returns commit history for all three file types. The existing graphics history tests mock GitHub and check the background HTTP worker separately; they do not exercise the full Windows UI flow. Reproduce the reported failure before concluding that the graphics history request itself is broken.

Plan:

1. Reproduce the problem on the intended branch/build. Test loading, refreshing, selecting, and restoring history; record the visible message and relevant LIVE LOGS entry. Check whether the running build matches the current source.
2. Trace the graphics history button from its click through the background request, cache, version selection, historical file fetch, validation, and editor staging. Make failures clear for empty history, offline/network errors, GitHub limits, and deleted commits.
3. Add history sources for each profile:
   - **Graphics:** `graphics/<ProfileName>.json`.
   - **Profile settings:** `profiles/<ProfileName>.json`.
   - **Sensitivity and crosshair:** the profile CFG (for example, `fab.cfg`), using only supported sensitivity and crosshair values.
4. Use GitHub file commit history for the selected source. Keep histories separate by profile and file, show the commit date/message and short commit ID, skip the current version, and provide an explicit refresh. Scope cache entries and invalidation to the selected profile and file.
5. Validate a selected historical file with the existing schema/CFG validators, then stage only that category in the editor. Restoring must not directly edit CS2 files, save locally, or sync to GitHub. CFG history must preserve unrelated current CFG commands and use the existing diff confirmation when the user later saves or syncs.
6. Add focused mocked tests for each source, history ordering, cache refresh/invalidation, invalid or mismatched files, deleted versions, and empty/offline responses. Verify cancel leaves drafts unchanged and restore stages values only. Add a Windows UI smoke test for the complete load-select-restore flow.


Dashboard **Apply Graphics** is a separate action from the normal profile Apply and **Play + Exec** buttons. Saving in the editor does not apply the settings immediately.
- The dashboard builds profile cards in the ordered `GamingProfiles` registry and displays five per page. Previous/Next changes only which cards are attached to the dashboard; it does not refresh profiles or make GitHub requests. The sixth registered profile begins page 2. The current registry contains six profiles, so `Provmode` appears on page 2.
- The dashboard refreshes its initially selected `FabMode` settings from GitHub before showing them. Edit, Apply, and Play + Exec refresh the profile they act on; the Graphics action also refreshes that profile before running. The selected-profile card marks GitHub-verified values, local pending values, and local fallback values when GitHub cannot be reached. Other profiles are not fetched at startup.
- Before normal Apply begins mouse, NVIDIA, CFG, or app actions, it fetches and validates the selected profile's latest `graphics/<ProfileName>.json` through the GitHub Contents API. That file's `ScalingMode` is authoritative and overrides the duplicate compatibility field in `profiles/<ProfileName>.json`.
- If this refresh fails, normal Apply is canceled before any profile actions begin. It costs one additional GitHub API request when NVIDIA settings are enabled.
- Apply Graphics independently refreshes the graphics file immediately before changing CS2 and uses its `ScalingMode` for GPU scaling.
- Opening Edit refreshes both the profile and graphics JSON files. Closing the editor makes no redundant request because successful Save & Sync already adopts its verified read-back.
- Before an action or editor open, a profile marked `SyncPending` shows a labeled choice dialog with **Use GitHub settings** as the primary action, **Upload local edits to GitHub** with a warning that it can overwrite newer GitHub settings, and **Cancel**. Choosing upload opens a second confirmation with **No** as the default before authorization or any writes. The GitHub choice discards local edits only after both latest files are fetched and validated; if that fetch fails, local values remain pending. Upload clears `SyncPending` only after GitHub read-back verification.
- Without pending edits, GitHub unavailability requires explicit confirmation before local fallback. A failed profile or graphics refresh must never silently select cached data.

- The Mouse tab's pointer-speed editor uses the classic Windows Mouse Properties slider's 11 levels, mapped to the same underlying MouseSensitivity values (1, 2, 4, ..., 20). The apply logic remains unchanged. Existing custom intermediate values are retained unless the user actively chooses a dropdown level.

### Local and GitHub persistence

- **Save Locally** writes the profile settings and `GraphicsSettings` snapshot to `%LOCALAPPDATA%\CafeLauncher\profiles.json`, and marks that profile `SyncPending`.
- **Apply Graphics** uses a validated pending local `GraphicsSettings` preset first, including while offline. This prevents a cloud fetch from overwriting unsynced edits.
- **Save & Sync to GitHub** confirms the destination, then updates `profiles/<ProfileName>.json` and `graphics/<ProfileName>.json`.
- It may also update the selected profile's CFG with captured sensitivity, crosshair convars, and push-to-talk changes. Unrelated binds and commands are preserved; captured crosshair values are never copied to another profile.
- Modern CS2 crosshair aliases are migrated: `cl_crosshairgap` → `cl_crosshair_gap`, `cl_crosshairsize` → `cl_crosshair_length`, and `cl_crosshairthickness` → `cl_crosshair_thickness`. If both old and modern names were captured, the modern value wins and the old command is removed. Legacy-only capture remains supported.
- During Save & Sync, obsolete crosshair commands are removed only from the selected profile CFG and only when Capture CS2 includes the current corresponding control: old `cl_crosshaircolor` requires all captured RGB channels; old alpha/use-alpha requires `cl_crosshaircolor_a`; weapon-value gap requires `cl_crosshair_gap`; outline thickness requires `cl_crosshair_drawoutline`. Partial captures leave those old lines intact. No guessed conversion is made for removed behaviors.
- Before a selected CFG write, the editor previews exact line changes and asks for confirmation. Removing weapon-based gap or old outline thickness shows a warning that the old behavior/value has no direct replacement; canceling the preview leaves GitHub unchanged and keeps local edits pending.
- **Refresh safeguard:** a previous stale-read regression showed that a unique query to `raw.githubusercontent.com` did not guarantee the latest profile. Always refresh profile and graphics JSON through the GitHub Contents API with no-cache headers.
- Validate the returned path, type, blob SHA, base64 encoding, and size; decode only the validated response. Never fall back to mutable raw-CDN profile or graphics JSON.
- If a Contents API read fails, retain local cache for recovery but do not silently use it for normal Apply. Normal Apply must verify the selected profile's latest graphics file or cancel. Apply Graphics uses its explicit local-fallback confirmation path.
- Mutable profile and graphics JSON reads use the GitHub Contents API with a unique cache-busting query and `Cache-Control: no-cache`, so an immediate Apply after Save & Sync sees the verified new preset instead of an intermediary's older response. Other mutable raw reads (CFG files, launcher update BAT, and the pinned graphics module) also need a unique cache-busting query and `Cache-Control: no-cache` where supported. Verify downloaded bytes before using the hash-pinned graphics module.
- **Persistence invariant:** after successful Save & Sync, the exact verified values must remain the values used by the next Apply. Preserve sync-pending/local precedence; background refresh or cache must never replace a successful local write with older data.
- After GitHub accepts the profile and graphics writes, read both JSON files back through the authenticated Contents API with no-cache headers. Verify every submitted profile field and the normalized graphics preset.
- Only a verified read-back clears `SyncPending` and persists the clean local snapshot. Failed or mismatched read-back leaves local settings pending for retry.
- Persist the verified profile blob SHA and commit SHA locally, never in public profile JSON. Every whole-profile refresh checks the latest commit touching that path, including on first run, and loads the file at that immutable commit SHA.
- If the latest commit matches the last verified commit, reuse the exact values read back during sync. For a different commit, compare ancestry: ignore an older ancestor returned during brief post-push lag, and require a clear newer descendant before replacing verified local values. A diverged history requires explicit confirmation before local values can be applied.
- If GitHub cannot be checked, keep local values but require explicit confirmation before Edit. Normal Apply cancels if it cannot verify the latest graphics preset. Pending local profile or graphics edits require an explicit sync/discard/cancel choice. Both Apply Profile and Apply Graphics use `graphics/<Profile>.json` as the authoritative scaling source; Apply Graphics also confirms offline local/cache fallback.
- When investigating a recurrence, compare the synced GitHub commit/API contents with `%LOCALAPPDATA%\CafeLauncher\profiles.json` and the LIVE LOG sequence. GitHub writes require the current file SHA; a conflicting remote edit must fail visibly rather than overwrite it.
- Profile refresh diagnostics in LIVE LOGS include repository, branch, file path, latest commit SHA, verified prior SHA, decision (reuse, load, ignore stale ancestor, refuse divergence, or local fallback), and pointer speed before/after a remote load. These diagnostics do not affect precedence. Never log tokens or authorization headers.
- **Expected profile-sync behavior:** history is filtered to `profiles/<Profile>.json`, while Save & Sync remembers the commit SHA returned by its write. A commit with no profile-file change is omitted from path history, so the previous content-changing commit may be returned as an ancestor.
- In that case `decision=ignore-stale-ancestor` / `comparison=behind` is expected; retain the already verified settings. Log INFO with “No action needed.” Do not add API requests or alter refresh behavior for this case.
- A `local-pending` refresh explicitly skipped GitHub. Check pending state before treating a refresh as a cloud read.
- **Pointer editor selection:** preserve a nonstandard saved pointer value when the dropdown is unchanged. If a standard selection differs from the initially displayed level, save it even if WinForms did not raise the user-selection event; keep regression coverage so the editor log matches the submitted value.
- Save & Sync offers two one-time authorization choices: paste a personal access token, or sign in through GitHub's device flow using the `github.com/login/device` link and a short code. Device sign-in checks the authenticated username, repository identity, and verified push permission before sync; the UI asks the user to confirm that account.
- Both credentials stay in memory for the sync and are not written to disk. The device flow uses the public GitHub App Client ID configured in `cafe.bat`; the app needs device flow enabled, Contents read/write permission, and repository access. The client ID is not a secret; never put a client secret or access/refresh token in the launcher.
- A partial upload reports confirmed and unconfirmed files. Local settings remain pending until both profile and graphics uploads pass read-back verification.
- GitHub profile reads and the sync target are configured in `cafe.bat` (`$script:GithubBranch`). Check this before claiming which remote branch receives profile data.
- **Pointer editor selection:** preserve a nonstandard saved pointer value when the user leaves the dropdown unchanged. When the selected standard level differs from the initially displayed level, save that value even if WinForms did not raise the user-selection event; keep regression coverage so the editor's log matches the submitted value.
- Save & Sync offers two one-time authorization choices: paste a personal access token or sign in through GitHub device flow using the `github.com/login/device` link and a short code.
- Device sign-in checks the authenticated username, repository identity, and verified push permission. The UI asks the user to confirm the GitHub account before syncing.
- Both credentials stay in memory for the sync and are not written to disk. The device flow uses the public GitHub App Client ID configured in `cafe.bat`; the app needs device flow enabled, Contents read/write permission, and repository access.
- The client ID is not a secret. Do not put a client secret or access/refresh token in the launcher.
- A partial upload reports the files confirmed saved and the files not confirmed. Local settings remain pending until the profile and graphics uploads have both passed read-back verification.
- GitHub profile reads and the sync target are configured in `cafe.bat` (`$script:GithubBranch`). Check this before any claim about which remote branch receives profile data.
- The launcher captures its running `CAFE_RELEASE` at startup. **Check for Updates** compares that version with GitHub `main`, even if a newer BAT has replaced the file on disk while the current PowerShell UI is running.
- If the newer BAT is already installed, the updater says to close and reopen it; otherwise it offers the verified download.
- After the dashboard appears, startup checks GitHub `main` for launcher updates in a background worker. The check is silent when current; a different verified BAT prompts before download. The updater checks GitHub blob SHA, size, and PowerShell syntax before installing it. Manual **Check for Updates** keeps its up-to-date and failure dialogs; failures are written to LIVE LOGS.
- Read-only PC inventory runs only when **Detect PC** is pressed. It does not refresh GitHub profiles or gate dashboard actions. Startup timings include the update-check dispatch and its separately tracked HTTP span.
- The updater classifies HTTP 403/429 as quota exhaustion only when the response body identifies rate limiting or `X-RateLimit-Remaining` is zero. Confirmed quota exhaustion tells the user to wait and retry; other 403 errors remain generic access failures.
- Quota status affects presentation/logging only. It never bypasses the updater's GitHub SHA, size, and syntax verification.
- The dashboard's top-right GitHub API allowance indicator reads the remaining/limit headers from requests the launcher already makes; it must not make a separate polling request. It shows the count and when that response was received. This is a display only and does not affect profile selection or settings.
- **Windows PowerShell 5.1 event-handler compile regression:** avoid `[void]` casts around .NET methods inside WinForms click-handler `try/catch` blocks. They can throw `Argument type cannot be System.Void` on click, before the handler runs.
- Discard dialog results with `$null = [System.Windows.Forms.MessageBox]::Show(...)`. The CS2 graphics capture test guards against reintroducing this pattern.

## Runtime behavior and safety boundaries

- Startup PC detection is informational. It must not change monitor settings.
- A normal profile Apply refreshes the selected profile immediately before applying mouse/NVIDIA settings, installing its CFG, and optionally launching configured apps. Play + Exec also refreshes the selected profile before installing its CFG. Neither starts CS2 with normal profile Apply nor writes persistent Steam launch options.
- `Launch-ProfileApps` is the shared app-launch routine. When Launch Apps is enabled, applying any profile (FabMode, ArliMode, BrileMode, ArmlMode, OliMode, or Provmode) passes its name and opens `https://metastack.gg/` instead of Spotify. The standalone Launch All action calls the routine without a profile name and still opens Spotify; the separate Spotify tile is unchanged. Profile Apply continues to skip G HUB.
- Run summaries report step totals and per-setting requested values, targets, outcomes, and verified values where available. NVIDIA scaling entries include profile, human-readable mode and NVAPI mode number, Windows display target, outcome, and NVAPI result/read-back or failure detail.
- LIVE LOGS keeps successful per-setting rows compact; full requested, target, actual, and detail fields remain in `%TEMP%\CafeLauncher.log`. The viewer uses one row per entry, horizontal scrolling, status/value colors, and bold profile/action names. Selected text can be copied with Ctrl+C or the right-click **Copy** menu item.
- The viewer loads current-session entries and available retained history (up to 2,000 lines) the first time **Show Logs** is opened, using the current log file so cleared or newly written entries are reflected. If loading fails, the next open retries. The session log retains the last 2,000 lines across launches, including exception stack traces. Startup exceptions are appended so a manual reopen preserves automatic-restart failures.
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

- GitHub sync authentication and CS2 graphics capture.
- Graphics history, including its async worker, and Steam/CS2 path discovery.

Changes to those test scripts trigger CI on pull requests and pushes to `main`.

The `publish-drive` job runs after all five validation jobs for pushes to `main` and manual dispatches from `main`.

- It skips pushes that did not change `cafe.bat`.
- When configured, it posts the validated release to the Apps Script endpoint in `tools/google-drive-sync/Code.gs`. The script updates the existing `cafe.bat` in the configured Drive folder in place, preserving its Drive file ID and folder link.

The checks cover:

- Parser/formatting and profile Apply's GitHub-authoritative graphics scaling and fail-closed behavior.
- Mocked persistence and GitHub sync, device-flow worker compilation, and in-memory token clearing without network or GUI.
- Per-profile CFG sensitivity presence/format, CFG-backed editor/apply contracts, and legacy JSON-field removal.
- Graphics fixtures, legacy DVC range mapping without hardware writes, read-only NVIDIA capability inventory, mocked Steam launch arguments, and status reporting.

A real CS2/Steam account and monitor smoke test remains separate.
