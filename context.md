# CafeLauncher — Codex Project Context

This file gives Codex and maintainers the operational context needed to work safely in this repository. **Always follow the checked-out source tree.** The generated state block below reports the launcher release marker, not whether that code has shipped to `main`.

<!-- BEGIN GENERATED LAUNCHER STATE -->
- Launcher release: `2026.10.15.36`
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
- NVIDIA profile Apply runs a read-only capability scan for Windows display modes, Digital Vibrance (extended then legacy query), Hue, NVIDIA DRS settings, and display-scaling APIs. Unsupported or uncheckable operations are skipped and logged. Digital Vibrance falls back to the legacy interface's queried min/max, maps the requested percentage to its quantized range, sets it, and verifies read-back. That legacy interface and Hue interfaces are private/undocumented; success is reported only after verification. DRS settings are handled individually: supported values are written and read back, while rejected or unavailable settings are reported. Display resolution uses advertised modes and verifies the selected mode; GPU scaling validates the topology, applies, and reads back. PhysX processor selection, the NVIDIA scaling override checkbox, and the G-SYNC Control Panel checkbox remain manual because the launcher does not have a reliable supported setter for them. Brightness is not changed by a profile; keep it at NVIDIA Control Panel's 50% default.
- MSAA, shadows, textures, shaders, particles, ambient occlusion, HDR, Reflex, texture filtering, FSR, VSync, and CMAA.

Each profile's canonical preset is stored independently in `graphics/<ProfileName>.json` (`FabMode`, `ArliMode`, `ArmlMode`, `OliMode`, and `BrileMode`). The editor validates and displays the selected profile's file; Apply Graphics validates that same profile name before using its settings. FabMode, ArliMode, ArmlMode, and OliMode currently use 1280×960 4:3 fullscreen defaults. BrileMode uses 1920×1080 16:9 fullscreen. Presets request the highest advertised refresh for the selected CS2 resolution; a saved 360 Hz value is not treated as proof the monitor supports 360 Hz.

The editor can copy only the CS2 graphics fields from another profile, or reset the current editor values from that profile's canonical preset. These actions do not save automatically. Apply Graphics reports confirmed/applied fields, changed fields, skipped fields, display-mode fallback details, NVIDIA scaling verification, and the backup path. A partial result is presented as a warning rather than unconditional success.

The CS2 / Apps editor can capture saved video settings from the running Steam client's active account after CS2 is closed. Capture reads only that account's `userdata/<id>/730/local/cfg/cs2_video.txt`, rechecks the active account after reading, validates recognized keys and ranges, converts the refresh numerator/denominator to whole Hz, and preserves profile values for missing settings. It imports CS2 resolution/aspect/fullscreen and supported video quality values into the editor; NVIDIA scaling is outside `cs2_video.txt` and remains the profile's current value. Capture never edits the game file or syncs immediately. The user reviews the imported values, then chooses Save Locally or Save & Sync; the existing sync confirmation describes profile/graphics and optional sensitivity CFG changes. In-game CFG binds are not captured.

The CS2 / Apps editor can load the three previous versions of `graphics/<ProfileName>.json` from GitHub commit history. The commit list is cached per profile for 24 hours; manual refresh bypasses the cache. Restoring fetches the selected file version over the internet, validates it, and fills the editor without saving or applying it. Saving or syncing remains a separate user action. History is not available offline unless it is already listed in the fresh cache; fetching an older preset still requires internet.

Dashboard **Apply Graphics** is a separate action from the normal profile Apply and **Play + Exec** buttons. Saving in the editor does not apply the settings immediately.
- The dashboard does not refresh all profiles at startup. It refreshes only the selected profile when the user opens Edit or starts an Apply / Play + Exec action. Before normal Apply performs any profile actions, it also fetches and validates that profile's latest `graphics/<ProfileName>.json` through the GitHub Contents API and uses its `ScalingMode` as authoritative, overriding the duplicate compatibility field in `profiles/<ProfileName>.json`. If that graphics refresh fails, the entire Apply is canceled before mouse, NVIDIA, CFG, or app actions begin. This costs one additional GitHub API request for each normal Apply where NVIDIA settings are enabled. Apply Graphics independently refreshes `graphics/<ProfileName>.json` immediately before changing CS2 and uses its `ScalingMode` for GPU scaling. Opening Edit refreshes both `profiles/<ProfileName>.json` and `graphics/<ProfileName>.json` so the fields shown are current. Closing the editor does not make a redundant second request; successful Save & Sync already adopts its verified read-back.
- Before an action or editor open, a profile marked `SyncPending` offers three choices: sync the local profile and graphics to GitHub (authenticated and read-back verified), discard local changes and fetch/validate both latest GitHub files, or cancel. If the discard fetch fails, the local values remain pending. If GitHub is unavailable without pending edits, local fallback requires explicit confirmation. A GitHub profile or graphics refresh failure must never silently choose cached data.

- The Mouse tab's pointer-speed editor uses the classic Windows Mouse Properties slider's 11 levels, mapped to the same underlying MouseSensitivity values (1, 2, 4, ..., 20). The apply logic remains unchanged. Existing custom intermediate values are retained unless the user actively chooses a dropdown level.

### Local and GitHub persistence

- **Save Locally** writes the profile settings and `GraphicsSettings` snapshot to `%LOCALAPPDATA%\CafeLauncher\profiles.json`, and marks that profile `SyncPending`.
- **Apply Graphics** uses a validated pending local `GraphicsSettings` preset first, including while offline. This prevents a cloud fetch from overwriting unsynced edits.
- **Save & Sync to GitHub** confirms the destination, then updates `profiles/<ProfileName>.json` and `graphics/<ProfileName>.json`. If sensitivity is nonblank, it may update only the matching CFG's sensitivity command; other binds and commands are preserved.
- **Stale profile after successful sync (regression to prevent):** GitHub recorded FabMode pointer speed `18`, then a later profile commit set it to `10`; the next Apply still logged a GitHub refresh and used `18`. A unique query on `raw.githubusercontent.com` was not sufficient to guarantee the latest revision. Both profile JSON (`profiles/<Profile>.json`) and CS2 graphics presets (`graphics/<Profile>.json`) must be refreshed through the GitHub Contents API with no-cache headers, validate the returned path/type/blob SHA/base64 encoding/size, and decode only that validated file. If an API read fails, retain local cache for recovery but do not silently use it for normal Apply: Apply must verify the selected profile's latest graphics file or cancel. Apply Graphics follows its own explicit local-fallback confirmation path. Never fall back to mutable raw-CDN profile or graphics JSON. Keep regression tests for both paths. Other mutable raw reads (CFG files, launcher update BAT, and the pinned graphics module) still need a unique cache-busting query and `Cache-Control: no-cache` where supported; hash-pinned module downloads must verify the downloaded bytes before use.
- **Persistence invariant:** after a successful Save & Sync, the exact saved values must remain the values used by the next Apply. Keep sync-pending/local precedence intact, and never let a background refresh or cache populate an older value over a successful local write. After GitHub accepts profile/graphics writes, Save & Sync reads both JSON files back through the authenticated Contents API with no-cache headers and verifies every submitted profile field plus the normalized graphics preset. Only a verified read-back lets the caller clear `SyncPending` and persist the clean local snapshot; a failed/mismatched read-back reports that verification failed and keeps local settings pending for retry. Persist the verified profile blob SHA and commit SHA locally (never in the public profile JSON). Every whole-profile refresh checks the latest commit touching that path, including on first run; it loads the file at that immutable commit SHA. If it is still the last verified commit, reuse the exact values read back during sync. Before accepting a different path commit, compare its ancestry with the last verified commit: ignore an older ancestor returned during GitHub's brief post-push lag, and require a clear newer descendant before replacing the verified local profile. A diverged history is reported and requires explicit confirmation before applying local values. This avoids trusting stale mutable `ref=main` responses and stale path-commit listings while still allowing another user's newer profile to load. If GitHub cannot be checked, keep local values but require explicit confirmation before Edit; normal Apply cancels if it cannot verify the selected profile's latest graphics preset. Pending local profile and graphics edits require an explicit sync/discard/cancel decision. Apply Profile and Apply Graphics both use `graphics/<Profile>.json` as the authoritative scaling source; Apply Graphics also asks before using an offline local/cache fallback. When investigating a recurrence, compare the synced GitHub commit/API contents with `%LOCALAPPDATA%\CafeLauncher\profiles.json` and the LIVE LOG sequence. GitHub API writes still require the current file SHA, so a conflicting remote edit should fail visibly rather than silently overwrite another user's update.
- Profile refresh diagnostics in LIVE LOGS include the repository, branch, file path, returned latest commit SHA, verified prior SHA, decision (reuse, load, ignore stale ancestor, refuse divergence, or local fallback), and pointer speed before/after a remote load. These are diagnostic records only; they do not affect precedence. Never log tokens or authorization headers.
- **Expected profile-sync behavior; no change planned:** GitHub's commit-history query is filtered to `profiles/<Profile>.json`, while Save & Sync remembers the commit SHA returned by its write. If that write creates a commit without changing the profile file, path history omits the no-op commit and returns the last commit that changed the file. The ancestry check may then log `decision=ignore-stale-ancestor` / `comparison=behind`; it safely keeps the already verified settings. This was observed on 2026-10-14: FabMode sync commit `2bc051f74af698e70bf65fe0ff235a9e2e68d215` had no file diff, while the last actual `profiles/FabMode.json` change was `8a6a78a88e467f0f71c85489e4d85e933b575ce4`. Do not treat this expected log as a bug or independently change this behavior, add API requests, or implement a cleanup; only revisit it if the user explicitly asks.
- **Potential safeguard for stale profile values (validated once, not proven universally fixed):** the 2026-10-14 FabMode test changed pointer speed 20 → 2 → 6 → 20. GitHub commits `e74ca85ec773586c6e53fc16d5831aea260c27ce`, `78e04379845536c99fc03a3b6ce1e597395b62eb`, and `6d7257e87253d70ce12bc3dfb0cc134fe9501732` contained 2, 6, and 20 respectively; each dashboard refresh logged that same SHA as `latestCommit` and `verifiedCommit`, and Windows Apply read back 2, 6, and 20. This run did not reproduce the rollback; treat the safeguards as likely contributors, not proof the bug cannot recur. When it happens for any profile, compare its Save & Sync read-back, subsequent refresh `decision`/SHA/value, the immutable GitHub profile file at that SHA, and Apply's requested versus actual value. A `local-pending` refresh explicitly skipped GitHub, so sync-pending state must be considered before interpreting it as a cloud refresh.
- **Pointer editor selection:** preserve a nonstandard saved pointer value when the user leaves the dropdown unchanged. When the selected standard level differs from the initially displayed level, save that value even if WinForms did not raise the user-selection event; keep regression coverage so the editor's log matches the submitted value.
- Save & Sync offers two one-time authorization choices: paste a personal access token, or sign in through GitHub's device flow using the `github.com/login/device` link and a short code. Device sign-in checks the authenticated username, repository identity, and verified push permission before the sync; the UI asks the user to confirm that GitHub account. Both credentials stay in memory for the sync and are not written to disk. The device flow uses the public GitHub App Client ID configured in `cafe.bat`; the app must have device flow enabled, Contents read/write permission, and access to this repository. The client ID is not a secret; do not put a client secret or access/refresh token in the launcher.
- A partial upload reports the files confirmed saved and the files not confirmed. Local settings remain pending until the profile and graphics uploads have both passed read-back verification.
- GitHub profile reads and the sync target are configured in `cafe.bat` (`$script:GithubBranch`). Check this before any claim about which remote branch receives profile data.
- The launcher captures its running `CAFE_RELEASE` at startup and compares that version with GitHub `main`; this avoids confusing the currently running PowerShell UI with a newer BAT that replaced its file on disk. If the newer BAT is already installed, the updater says to close and reopen it; otherwise it offers the verified download. Startup checks before slower hardware/game inventory and only shows a dialog when a newer build exists; manual **Check for Updates** reports current or failed checks too. Automatic check failures are written to LIVE LOGS.
- The updater classifies a GitHub HTTP 403/429 as quota exhaustion only when the response body identifies rate limiting or `X-RateLimit-Remaining` is zero; a confirmed quota failure says to wait and retry. Other 403 errors remain generic access failures. The status is presentation/logging only and never bypasses the updater's GitHub SHA, size, and syntax verification.
- The dashboard's top-right GitHub API allowance indicator reads the remaining/limit headers from requests the launcher already makes; it must not make a separate polling request. It shows the count and when that response was received. This is a display only and does not affect profile selection or settings.
- **Windows PowerShell 5.1 event-handler compile regression:** avoid `[void]` casts around .NET methods inside WinForms click-handler `try/catch` blocks. They can throw `Argument type cannot be System.Void` when the user clicks, before the handler runs. Discard dialog results with `$null = [System.Windows.Forms.MessageBox]::Show(...)` instead. This affected the CS2 graphics capture error dialog; the CS2 graphics capture test guards against reintroducing the pattern.

## Future storage migration plan — Cloudflare R2 (not implemented)

This is a saved plan only. The current launcher still uses GitHub for profile, CFG, and graphics files. Do not start this migration unless the user explicitly asks.

### Goal and design

Move profile settings, CS2 graphics presets, CFG files, and optionally the graphics helper file off GitHub file hosting and GitHub profile-file API calls. Keep the launcher updater separate. Use a private Cloudflare R2 bucket to hold the files and one small Cloudflare Worker as the launcher's HTTPS REST API and access gate. Do not add a database or per-user accounts. The Worker alone accesses R2; CafeLauncher never receives R2 credentials.

### Keep familiar file paths

Store objects using recognizable paths, for example:

- `profiles/FabMode.json` and the other `profiles/<Profile>.json` files.
- `graphics/FabMode.json` and the other `graphics/<Profile>.json` files.
- Root CFG files such as `fab.cfg`, `brile.cfg`, and the other profile CFGs.
- Optionally `graphics/ApplyGraphics.ps1`; if moved, retain the existing pinned-hash verification before running the downloaded helper.

Keep the bucket private. Seed it with the current canonical files after validating that the source files are current. The launcher should use the Worker for reads and writes; it should not access the bucket directly.

### Worker API shape

- `GET /v1/profiles/<Profile>` returns that profile's profile JSON and graphics JSON together, with a revision for each file. This replaces the launcher's separate profile and graphics reads where both are needed.
- `POST /v1/profiles/<Profile>` accepts the edited profile JSON, graphics JSON, and optional permitted CFG sensitivity update. Require the shared save code, validate the profile name and every allowed file/key, and write only approved paths. Return the resulting revisions and values or hashes for read-back verification.
- `GET /v1/files/<name>` serves allow-listed CFG files and, if chosen, the graphics helper. Reject arbitrary paths.
- Graphics history moves from GitHub commit history to Worker-managed snapshots: before replacing a graphics preset, retain its prior content; expose an endpoint to list the latest three previous versions and fetch a selected version. Restore should load a version into the editor; saving and applying remain separate actions.

Use optimistic concurrency: reads return revisions and saves identify the revision they were based on. If another PC has saved a newer revision, reject the stale write and ask the user to refresh or review instead of silently overwriting newer settings.

### Launcher flow changes

Keep the editor and Apply behavior mostly unchanged; replace the storage transport underneath them:

1. Edit Profile refreshes the selected profile and graphics through the Worker.
2. Apply Profile refreshes that selected profile before applying it; Apply Graphics refreshes that profile's graphics before writing CS2 settings.
3. Save & Sync saves locally first, then sends the profile, graphics, and any allowed CFG change in one Worker request. Clear `SyncPending` only after the Worker accepts the save and the launcher verifies the returned revision/content. Preserve pending edits if the network or verification fails.
4. CFG downloads use the Worker rather than raw hosted-file URLs. History uses Worker snapshots. If the helper is moved, verify its pinned hash before execution.
5. Keep the current visible result and error reporting: distinguish saved, pending, conflict, unavailable, and verified outcomes. Do not silently fall back to stale local data after a failed remote refresh; require the existing explicit local-fallback choice where appropriate.

### Shared save code and scope

Ask for the shared save code only when Save & Sync is used. Send it over HTTPS to the Worker for verification; never embed it in `cafe.bat`, save it in profiles, or write it to logs. Do not persist it on café PCs, so Deep Freeze sign-outs/resets do not affect the workflow. Anyone who learns the shared code can edit shared files, so provide a way to rotate it and explain that tradeoff.

This migration removes GitHub profile/graphics Contents API usage and GitHub-hosted profile/CFG/graphics reads. It does not move app update checks: those remain on their existing separate source unless a later plan explicitly changes them. R2 is the file store; the Worker is still a small backend, but no database or user-account system is part of this design.

## Runtime behavior and safety boundaries

- Startup PC detection is informational. It must not change monitor settings.
- A normal profile Apply refreshes the selected profile immediately before applying mouse/NVIDIA settings, installing its CFG, and optionally launching configured apps. Play + Exec also refreshes the selected profile before installing its CFG. Neither starts CS2 with normal profile Apply nor writes persistent Steam launch options.
- Run summaries report step totals plus per-setting requested values, target devices/displays, applied/fallback/skipped/failed/pending outcomes, and actual verified values where available. NVIDIA scaling log entries include the profile, human-readable mode and NVAPI mode number, Windows display target, outcome, and NVAPI result/read-back or failure detail. The concise summary remains in the launcher status line; setting details are appended to LIVE LOGS and the existing `%TEMP%\CafeLauncher.log` session log. CS2 Apply Graphics writes its field-level result summary to those same logs as well as showing its result dialog. No separate history file is created.
- Apply Graphics marks `panelOverride=not-read-or-set` in the NVIDIA scaling log: the launcher cannot verify or toggle NVIDIA Control Panel's “Override the scaling mode set by games and programs” checkbox. A successful NVAPI mode-2 read-back confirms the GPU scaling mode at Apply time, not that the checkbox is enabled or that CS2 retained the mode at launch. If CS2 opens with black bars, compare the applied resolution/aspect and display target, then check the override checkbox manually; the launcher currently does not monitor manual CS2 launches.
- Steam/CS2 discovery checks registry and running-client locations, Steam `libraryfolders.vdf`, and a small revalidated local library-path cache. It skips disconnected mapped drives, validates `appmanifest_730.acf` (`appid` and safe `installdir`) plus the expected CS2 folders, and searches at most 1,200 directories / depth 8 inside a confirmed CS2 install if the CFG folder is relocated. A missing or ambiguous install is never auto-selected; interactive install asks the user to choose and confirm the exact existing `game\csgo\cfg` path, while silent profile Apply skips and logs the reason. CFG and graphics targets remain separate: CFGs go in the confirmed game install, while `cs2_video.txt` goes under the current Steam account's `userdata` tree. Steam executable discovery prioritizes the running client so graphics account IDs are paired with the active client path. Successful CFG writes are SHA-256 verified; graphics writes recheck account and path before replacement.
- **Play + Exec** installs the selected CFG and requests a one-time Steam launch argument. It does not persist launch options or apply mouse/display settings.
- Logitech live DPI uses BetterLogiHub and validates the selected mouse identity before writes and read-backs. If the ordinary live DPI operation fails, the original PRO X SUPERLIGHT (`pro_x_wireless_mouse`) alone gets a host-mode fallback: recheck the mouse, read its current onboard/host mode, switch to host only when needed, verify that mode, retry DPI, and verify the requested value. A successful fallback leaves the mouse in host mode; if fallback fails after a mode switch, attempt and verify restoration to onboard mode. The PRO X SUPERLIGHT 2 keeps its existing helper-specific behavior. This does not write onboard DPI memory and is separate from the deferred reconnect-triggered reapply TODO.
- **Possible later Superlight 1 fallback (not implemented; consider only if both BetterLogiHub live DPI paths fail):** OpenMouse's `mouse-protocol` project has a Logitech HID++ implementation; its supported-device list identifies the original G Pro X Superlight as PID `0xc094` (also called `PRO X Wireless`, wireless product ID `4093`) and lists HID++ direct support. The useful reference is the Logitech protocol package/driver (`@openmouse/protocol/logitech`, sources grouped under `src/`), not its browser UI. This is not a drop-in Windows helper: integrating it would require a Windows HID++ transport or a small native helper, runtime feature discovery, exact model/device targeting, serialized commands, DPI range validation, and read-back. Begin with read-only detection, then test one live DPI write on the exact SL1 hardware. OpenMouse documents live DPI as host-mode/volatile; do not write onboard profile memory as part of this fallback. The SL1 is documented as profile format 4, so do not reuse the Superlight 2 format-7 profile layout. The upstream `mouse-protocol` license is AGPL-3.0-or-later; before copying or adapting its source into a redistributed CafeLauncher build, retain required notices and review the license's source and distribution obligations. This is a research lead only; do not implement it automatically.
- **Apply Graphics** requires CS2 to be closed, detects the active Steam account at the write boundary, changes only recognized keys in that account's `cs2_video.txt`, backs up before replacing, verifies the result, and restores on failure where possible.
- The CS2 refresh choice applies to the selected **game resolution**, independently of Windows desktop resolution. `Highest` chooses the highest advertised progressive rate for that resolution. `Exact` applies only if the exact resolution/Hz is advertised; otherwise it preserves existing display values and reports why.
- NVIDIA preflight defines overall NVAPI availability by calling `NvAPI_Initialize` and balancing a successful initialization with `NvAPI_Unload`; the DLL path is used only for version reporting. Per-setting capability probes still verify each operation independently. Tests do not prove live hardware behavior. Do not perform live mouse, DPI, display, or other device writes as a test without user authorization.
- **Deferred TODO — reconnect-triggered DPI reapply (do not implement unless the user explicitly asks):** Consider listening for Windows mouse/receiver disconnect and reconnect notifications, then re-detecting the connected supported mouse and reapplying the selected profile's live DPI with a small bounded retry count. Avoid constant polling, identify the mouse rather than targeting only its receiver, and log a clear result if it does not reconnect. This is only a deferred idea; do not start implementation, add background monitoring, or change DPI behavior on your own.
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-GitHubSyncAuth.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-ProfileSave.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-CfgSensitivitySync.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-Graphics.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-GraphicsHistory.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-NvidiaCompatibility.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-SteamPathDiscovery.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-CS2GraphicsCapture.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-SteamLaunchOptions.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-StepResults.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Update-Context.ps1 -Check
```

These checks cover parser/formatting, profile Apply's GitHub-authoritative graphics scaling and fail-closed behavior, mocked persistence and GitHub sync, device-flow worker compilation and in-memory token clearing without network or GUI, graphics fixtures, legacy DVC range mapping without hardware writes, read-only NVIDIA capability inventory, mocked Steam launch arguments, and status reporting. A real CS2/Steam account and monitor smoke test is still separate.

## 2026-10-15 — CS2 capture and dashboard usability

- Added **Capture CS2** beside each of FabMode, ArliMode, BrileMode, ArmlMode and OliMode. The shortcut opens that profile's editor directly on **CS2 / Apps**, triggering the same extracted capture action as the editor button; GitHub authentication, Save Locally, and Save & Sync are unchanged.
- Capture reads video values from the active Steam account's `cs2_video.txt` and attempts to read sensitivity and supported crosshair commands from `cs2_user_convars_0_slot0.vcfg`. Missing user convars produce a warning and do not overwrite an existing CFG with invented values. Captured values are staged per profile until GitHub sync.
- Save & Sync updates only recognized sensitivity/crosshair commands in that profile's matching `.cfg` (alongside existing graphics/profile JSON sync); unrelated binds and CFG commands remain untouched. Profile-to-profile **Copy graphics** remains graphics-only.
- Dashboard profile rows have distinct outline accents (FabMode blue, ArliMode green, BrileMode purple, ArmlMode orange, OliMode cyan), more identifiable `Edit <Profile>` buttons, and `EDITING: <Profile>` window titles.
- Keep the shortcut and editor wired to the **same** capture action to avoid diverging behavior. GitHub credentials must not be persisted; preserve Deep Freeze portability and non-admin assumptions.
- **Validation required:** Windows PowerShell 5.1 parser and Windows/CS2 smoke test (including local account detection, saved user convars format, and GitHub read-back) before relying on this build in internet cafés. This environment cannot run the Windows GUI.

## 2026-10-15 — Profile identity refinement (merged via PR #22)

- `feature/profile-identity-ui` centralizes the FabMode/ArliMode/BrileMode/ArmlMode/OliMode accent palette in `$script:ProfileAccentColors`; dashboard borders and editor heading use consistent colors.
- Editor headings display `EDITING: <PROFILE>` and dashboard Edit buttons identify their own profile (`⚙ Edit <Profile>`).
- Dashboard row hover brightens the slim container outline while preserving dark button backgrounds, including when the cursor is over a child button. Button handlers remain bound to their row's captured profile.
- CI validation was performed before merge; real Windows WinForms layout testing at different DPI scaling remains recommended.

## 2026-10-15 — Per-profile CS2 push-to-talk binding (merged via PR #23)

- Each profile editor's **CS2 / Apps** tab has a push-to-talk selector. The launcher looks up the current `bind "<key>" "+voicerecord"` from the matching GitHub CFG when no unsynced local profile changes exist; if the network is unavailable, the locally saved key can be shown.
- The selected key is locally persisted as `VoicePushToTalkKey` in profile settings; blank means do not modify the remote CFG. `Save & Sync to GitHub` stages an update to the matching `fab.cfg`, `arli.cfg`, `brile.cfg`, `arml.cfg` or `oli.cfg`.
- The CFG rewrite replaces the unique active `+voicerecord` bind, rejects duplicated voice bindings and an already-occupied target key, preserves unrelated bind commands, and skips rewriting unchanged binds. A changed voice binding is read back from GitHub for verification.
- No admin privileges, permanent token storage, Steam restart, profile-to-profile copying, or changes to Apply Graphics were introduced.
- PR #23 merged into `main` as commit `61112a43de74e85071611aa69499702060555b8e`. All five Windows PowerShell 5.1 CI jobs passed on head commit `0ea8b11c066e35f54fba568f397a04a794be74de` (Core, Profiles, UI, CS2, Hardware). The CFG voice-bind matcher was corrected to preserve Windows CRLF line endings. Real Windows mouse-button capture and in-game CS2 confirmation are still outstanding.

## Next UI improvement (not yet implemented)

- Move the editable CFG download URL out of the everyday CS2/Apps fields into an **Advanced Settings** section with a **Restore Default URL** control. Keep the URL functional and editable for troubleshooting, but harder to change accidentally. This is a proposal, not shipped behavior.

## 2026-10-15 — Release marker catch-up for dashboard UI

- Release `2026.10.15.35` increments the launcher marker so existing `2026.10.14.34` installations can detect and install the dashboard **Capture CS2** shortcuts and color-coded profile borders that were merged earlier without a version bump.
- The launcher code for capture/profile colors was already on main; this fixes release discovery, not the in-game capture algorithm. Close and reopen the app after updating to see the new UI.

## 2026-10-15 — Same-version updater safety

- The updater now compares the existing GitHub Contents API Git blob SHA with the local launcher using `Test-LauncherIsCurrent`, which already ignores CRLF-versus-LF differences. A differing file with the **same** `CAFE_RELEASE` is offered as an update instead of being incorrectly reported current.
- Version ordering still blocks downgrades and a newer already-installed file still prompts to restart. No extra API request or dependency was added. Release marker `2026.10.15.36` delivers the fix to existing installs.
