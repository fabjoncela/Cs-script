# CafeLauncher Web App Plan

## Goal

Add an optional web dashboard for players who want to choose a profile and run CafeLauncher actions from the café website. The web workflow should be:

1. Open the website and choose a profile/action.
2. The page asks Windows to activate the registered `cafelauncher://` handler.
3. A verified local runner starts in the currently signed-in Windows user's session, claims the requested action, and runs only an allowed CafeLauncher action.
4. The page displays structured progress and the final result, including skipped, partial, failed, or pending steps and any required user input.

The web app is optional. Double-clicking `cafe.bat` must continue to open the current Windows dashboard with its existing actions and behavior. No web setup should be required for that entry point.

## Current architecture and constraints

These are source-backed findings from the repository review on 2026-11-12; verify them again before deployment because runtime state can drift.

- `Cs-script` is the launcher source. `cafe.bat` is a hybrid batch/PowerShell WinForms application; it has no compiled-app build step. The current dashboard already records action-step outcomes (`SUCCESS`, `PARTIAL`, `SKIPPED`, `FAILED`, `PENDING`) and logs recovery guidance.
- Profile, graphics, CFG, and history reads use CafeLauncherBackend first and the generated public GitHub mirror as a validated fallback. The mirror is read-only to clients, may lag, and is not an execution queue or player-authentication service.
- Profile writes use the existing token-protected, revision-checked backend sync path. Do not expose the sync or release-publishing secrets to browser JavaScript or include them in a local queue, URI, logs, or profiles.
- Backend source documents immutable versioned launcher and graphics-module release endpoints and a separate publishing path. The active launcher updater still uses `Cs-script` GitHub and Google Drive. The reviewed mirror manifest had `releases.latest: null`; a runner release is not currently available through that route.
- At the live baseline check, the backend root served the status dashboard; `/viewer` served the read-only profile viewer; `/v1/*` served APIs. Local backend source now serves the web app at `/` and the old status dashboard at `/status`, while retaining `/viewer` and `/v1/*`; this source change is not deployed.
- The backend service is documented as loopback-bound behind the existing Tailscale Funnel path. The launcher currently reads from `https://fabjon-hp.tail681ec9.ts.net:10000`; the public HTTPS health check succeeded during the baseline review. Funnel exposure alone does not create `/status` or `/` routing rules. Verify the deployed Funnel mapping and service before changing routes.
- Existing actions retain Windows, Steam, CS2, hardware, privilege, and confirmation requirements. Web invocation must preserve those limits and cannot assume all actions are unattended.

## Current architecture decisions

0. **Repository ownership:** Keep the launcher action mode, portable Windows runner, and launcher-specific protocol/operations documentation in `Cs-script`. Keep the web page, ticket/session/result API, and HTTP route changes in `cafelauncher-backend`. Treat `cafelauncher-backend-mirror` as generated, public, and read-only. Do not create a fourth repository for this feature unless the runner later needs an independent release/security boundary.
1. **Request and result transport:** Use short-lived, single-use action requests. The website creates an authorized request; the runner claims it once; the runner reports structured progress/result; the page polls or subscribes until completion. A custom URI only launches the handler and carries an opaque request identifier. It does not itself return a result to the page.
2. **Request binding:** Bind each request to an anonymous same-origin browser session, selected profile, allowlisted action, expiry, and a unique idempotency value. The pilot assumes the browser is open on the café PC; the local handler runs under that Windows kiosk account and the runner checks the active Steam session. Add player login/pairing only if the café requires identity beyond that context.
3. **Runner trust:** The runner accepts no arbitrary command, script, URL, file path, or profile payload from URI arguments. It fetches the authorized request over HTTPS, validates its schema/expiry/action, claims it atomically, and verifies the release manifest and downloaded artifact SHA-256 before executing code. If the backend's latest artifact lacks the requested web-action entry point, it falls back only to the fixed Cs-script GitHub Contents API endpoint and validates the exact file size and Git blob SHA-1 before caching or executing it; it never opens an older normal dashboard as a web action.
4. **Replay and concurrency:** Define one-claim semantics, expiry, duplicate clicks, concurrent actions, runner crashes, network loss, and result retries. The backend must not report a successful action before the runner has supplied a result.
5. **Local installation:** The website offers a runner download. The player opens the downloaded executable once; it self-copies with byte verification to `%LOCALAPPDATA%\CafeLauncher\Runner\CafeLauncherWebRunner.exe` and registers the protocol for that Windows account without admin rights. Reopening it is idempotent and can replace an older unlocked copy. Browsers cannot silently run or install an executable. On a normal PC this is a one-time per-account setup. If Deep Freeze restores LocalAppData or HKCU at reboot, staff must install/register it in the saved image or reprovision during maintenance; a browser button cannot bypass the reset policy. The version cache under LocalAppData is disposable: each action must reverify the cached launcher artifact, and a missing cache must be downloaded again.
6. **Interactive actions:** Create an action capability matrix. Some actions need native dialogs, direct user confirmation, elevated helpers/UAC, active Steam identity, connected hardware, or CS2 to be closed. Keep those requirements explicit; the web page cannot silently bypass them.
7. **Release channel:** Select one authoritative immutable release source and publish a version-matched runner plus required helper/module assets. Do not treat the public profile mirror as an execution authority. Keep all existing launcher update paths supported.

**Runner auto-update refinement:** after the initial install/registration, each protocol launch checks the latest immutable Cs-script GitHub runner release manifest. It installs a newer runner side-by-side only after validating manifest fields, size, and SHA-256, updates the current user's protocol handler, and resumes the same action request. GitHub network failure falls back to the installed runner; invalid release metadata or bytes fail closed. The first v0.5.0 bootstrap still requires downloading and opening the updated installer once because older installed runners cannot update themselves. A Deep Freeze image that restores an older runner will update on its first web action after each restore.

**Local profile edit policy on runner upgrade:** because the player explicitly requested local drafts be discarded when the web runner updates, the first action after an update fetches current primary-backend snapshots for every profile with pending local edits/queues. It validates all snapshots before importing any, then clears the pending edit state and one-time marker. If any snapshot fails, the web action stops and retains the local pending state. The marker is consumed after this one reset so subsequent local edits are not automatically discarded.

For Play + Exec, resolve the currently published profile revision first, then fetch the complete `/v1/profiles/{name}/history/{revision}` bundle so profile JSON, graphics, and CFG all come from one immutable revision. Never compose an execution snapshot from three independent “latest” requests. If that exact bundle cannot be verified under the existing backend/mirror trust and consent rules, stop with a visible result instead of launching with stale or mixed files.

## Phases and acceptance criteria

### Phase 0 — Source and deployment baseline (in progress)

- [x] Review the three repositories' documented roles, current launcher context, backend API/release contract, and mirror manifest.
- [x] Confirm that no runner release is currently listed in the reviewed mirror manifest.
- [x] Read-only live route check: `/` returned the CafeLauncher Backend Status page, `/viewer` returned the viewer, `/v1/health` returned healthy (`0.1.0`), and `/status` returned 404 on 2026-11-12.
- [ ] Record the current deployed backend commit and Funnel mapping; the workstation's `tailscale funnel status` reported `No serve config`, which does not reveal the server-side configuration.
- [x] Set the low-friction rollout assumption: open the page on the café PC, use its existing kiosk Windows account and active Steam session, and provision the portable runner plus per-user handler into the Deep Freeze baseline (or maintenance/login provisioning).
- [ ] Verify the actual café account model and Deep Freeze restore behavior during the physical pilot.

**Exit:** deployment facts are tied to live evidence rather than repository documentation alone.

### Phase 1 — Define the action protocol and threat boundaries

- [x] Draft request/result schemas, lifecycle states, limits, expiry, claim, idempotency, and retry behavior in [`cafelauncher-web-action-protocol.md`](cafelauncher-web-action-protocol.md).
- [x] Specify a strict URI shape carrying only one opaque, one-use request ID; caller-supplied action/path/command data is rejected.
- [x] Define explicit in-page confirmation for state-changing pilot actions and privacy-bounded result reporting; retain existing OS/UAC/device prompts.
- [x] Build the current web action matrix: Apply profile, Apply game graphics, and Play + Exec for a selected profile. Keep Detect PC as runner/API diagnostics only; Capture CS2 and Edit Profile stay out of the web UI.
- [x] Confirmation decision: require explicit in-page confirmation before ticket creation; keep existing Windows/UAC/device prompts only where required. A second generic native confirmation would add friction without identifying the website player.
- [ ] Confirm during the physical pilot whether the café requires player identity beyond the local browser session and active Steam state. The current backend has no player-account authentication.
- [ ] Review the protocol against the actual café browser and Deep Freeze model before enabling ticket endpoints in production.

**Exit:** the page, backend, and runner can be implemented without guessing who authorized an action or how its result reaches the page.

### Phase 2 — Prove the local protocol on one café PC

- [ ] Build/package and provision a runner that can register/handle `cafelauncher://` and start under the expected signed-in Windows user. The current Windows account has installed the runner and the screenshot from the player flow shows the protocol handler starting it; no café PC has been provisioned or reboot/Deep Freeze tested.
- [x] Local development round trip: an isolated temporary backend served the exact current `cafe.bat` artifact; a temporary runner build using a loopback-only HTTP origin claimed a Detect PC ticket, executed the structured launcher action, and returned Steam/CS2 results. This did not test the production HTTPS origin, browser-triggered URI activation/registration, or café provisioning.
- [x] Runner terminal-result check: an isolated backend and fake immutable launcher made the C# runner claim a Play + Exec ticket, verify release size/hash/marker, dispatch a harmless PowerShell stub, validate the result schema, upload `COMPLETED`, and return it to the creating browser session. The temporary runner used a loopback HTTP-only source override; no real CFG/Steam action ran.
- [x] Connect the Detect PC page button to the runner request/result channel. A local loopback runner/backend round trip returned structured Steam/CS2 discovery; browser-triggered Windows URI activation still needs the café pilot.
- [ ] Verify the runner's verified release download, first launch, repeat launch, expiry, duplicate claim, cancellation, network failure, and result retry behavior.
- [ ] Reboot the PC and test the actual Deep Freeze restore cycle. Confirm runner files and URI registration remain available, or document the required re-provisioning step.
- [ ] Verify no elevation is requested for ordinary detection; document any required machine-wide registration privilege.

**Exit:** the browser reliably receives the result of a single authorized local action before and after the café's reboot/restore cycle.

### Phase 3 — Add the web-action mode while preserving `cafe.bat`

- [x] Add an additive `detect-pc` named-action context to the launcher. Keep ordinary double-click behavior routed to the current Windows dashboard.
- [x] Connect `play-exec` to the existing pinned-path CFG install and Steam launch helpers. The web action resolves one current revision and fetches its immutable profile/graphics/CFG history bundle; unresolved local edits, missing Steam/CS2 discovery, or rollback review requirements fail closed.
- [x] Additive groundwork: existing Detect PC inventory can now return a versioned structured Steam/CS2 path record on request, while the existing no-argument call and dashboard text report remain unchanged.
- [x] Reuse CafeLauncher CFG install and Steam launch functions where possible; produce a structured result envelope for the web runner.
- [x] Ensure action execution uses the current Windows user's Steam session and CS2 installation and the selected profile's coherent, verified profile/graphics/CFG snapshot.
- [x] Add mocked PowerShell checks for web Play + Exec success, already-running CS2, pending local edits, rollback, target-path changes, and uncertain CFG/Steam outcomes.
- [x] Keep existing confirmation, permission, hardware, path, backup/rollback, and recovery gates. Mocked Play + Exec checks cover the key web-action branches; real-machine parity remains in Phase 6.
- [x] Wire the three requested player actions: Apply profile, Apply game graphics, and Play + Exec. Detect PC remains diagnostics-only; Capture CS2 and Edit Profile are deferred from the web UI. The new profile actions use immutable backend snapshots and bounded result envelopes.
- [x] Make web Apply profile apply supported Logitech **live** DPI synchronously: download the pinned helper when needed, verify SHA-256, apply to the selected supported mouse, and wait for read-back. Do not write onboard mouse memory from this web action; unavailable/unsupported hardware must produce a visible failed or skipped step.
- [ ] Add Capture CS2 or Edit Profile only after documenting their web-specific interaction requirements and safety boundaries.

**Exit:** the selected action and profile are explicit; page result states agree with the launcher action records; double-click still opens the existing dashboard without web registration.

### Phase 4 — Release and browser dashboard

- [x] Add the web-page runner download/setup instructions and a self-installing runner that verifies its copy and registers the per-user protocol; add temp-directory tests for initial install, no-op reinstall, and replacement.
- [x] Add a Windows GitHub Actions workflow to build/test the runner and publish immutable versioned executable and SHA-256 sidecar assets. It refuses to replace a version with different bytes. The release still requires an authorized push before it can run.
- [x] Add a compatibility check so an older backend launcher artifact cannot open the dashboard for a web request; fetch current Cs-script source only from the fixed GitHub Contents API endpoint and verify size plus Git blob SHA-1 before running the requested action. Local runner v0.5.0 adds automatic self-update and Apply profile/graphics/play actions; these changes still need publication.
- [x] Add immutable runner release metadata (`version`, `size`, `sha256`) and a side-by-side client updater that resumes the pending action after installation. Validate metadata/version ordering in local C# compatibility tests. A prior v0.4.0 installation needs one manually opened v0.5.0 download; future runner releases update from a web action.
- [ ] Publish immutable, versioned runner/launcher and required helper/module assets with a manifest containing sizes and SHA-256 hashes. The runner validates the manifest and hashes client-side before execution.
- [ ] Ensure partial publication, retries, abandoned versions, and rollback are safe. Never overwrite a published version with different bytes.
- [x] Build the three-action website flow: selected profile, in-page confirmation, protocol URI launch, bounded polling, and text-only structured result rendering. Apply profile, Apply game graphics, and Play + Exec are wired locally; Detect PC is hidden from the player page.
- [x] Complete initial structured result/error/recovery mapping: known results close normally; unknown local outcomes report `INTERRUPTED` and leave the page locked until the player checks the PC. Refine the page after a real café pilot.
- [x] Avoid browser-held long-lived secrets; use an anonymous same-origin cookie session, CSRF token, exact-origin checks, strict action/profile allowlists, and bounded outstanding requests/events. No player login is in the pilot scope.
- [ ] Keep the page and APIs on the intended HTTPS origin where possible; do not use a broad CORS policy to bridge the runner.

**Exit:** a test release is reproducibly verifiable and the browser session that created a request can view only that request's result.

### Phase 5 — Hosting/routing

- [ ] Inspect the live Funnel configuration and backend service binding before changing routing.
- [x] Update the local backend source to serve the web app at `/` and the existing status dashboard at `/status`, preserving `/viewer` and `/v1/*` routes.
- [ ] If practical, keep API and app same-origin. Make routing changes in the backend/proxy owner, not by assuming Funnel creates paths.
- [ ] Verify root, `/status`, `/viewer`, health, profile APIs, artifact APIs, and result APIs through the public HTTPS route and from the local service after focused API coverage is added.

**Exit:** every existing route and the new page work through the actual public route; health checks and service restart/recovery remain valid.

### Phase 6 — Café parity and rollout gate

- [ ] On a real café PC, verify Play + Exec uses the intended Steam account and CFG, including when CS2 is already running.
- [ ] Verify Apply Graphics changes only supported target settings and preserves unrelated settings.
- [ ] Verify DPI, NVIDIA, display, and helper actions preserve existing hardware, privilege, and UAC boundaries.
- [ ] Test rapid repeat clicks in the browser, expired requests, runner termination, stale profile revisions, API outage, mirror fallback, failed downloads, hash mismatch, and interrupted result upload. Backend tests now verify concurrent retries with one client request ID produce one ticket; browser/UI and café runtime behavior remain open.
- [ ] Test both entry points after clean/reverted provisioning: website download + first-run setup, and double-click `cafe.bat` on a PC never configured for the web app.
- [ ] Confirm no action appears successful when it was skipped, only partly applied, or still pending.

**Rollout gate:** do not roll out broadly until one café PC passes the protocol, persistence, parity, recovery, and legacy-entry-point checks.

## Operational rules

- Keep this feature optional and preserve the existing `cafe.bat` workflow throughout development.
- Do not push, merge, deploy, publish a release, or change remote profile data without a separate explicit request.
- Treat mirror contents as public and generated. Never edit generated mirror data directly.
- Never store sync/publish tokens in the runner, browser, URI, profile, log, or action result.
- Preserve the current source tree's Windows PowerShell 5.1 compatibility and `cafe.bat` CRLF format.
- Update `context.md` when the implementation architecture, UI behavior, persistence, safety boundaries, or verification workflow changes.
- Record deployment facts only after checking the live service; do not infer production behavior from a branch or README.

## Current implementation checkpoint

- Plan created on 2026-11-12.
- Phase 0 source review and a read-only public route check are complete; deployed commit/Funnel configuration and café Deep Freeze facts remain to be collected.
- Phase 1 request/result protocol and action capability matrix are in [`cafelauncher-web-action-protocol.md`](cafelauncher-web-action-protocol.md). In-page confirmation is selected; player identity beyond the kiosk browser/active Steam session remains a pilot assumption.
- The current Windows account has a self-installed runner and the web page has activated it; this does not prove café-PC provisioning, persistence, or real action parity. A local .NET Framework runner validates URIs, claims tickets, verifies release artifacts, self-updates, dispatches allowed actions, and uploads bounded results. Detect PC completed an isolated loopback end-to-end run. Play + Exec completed an isolated runner round trip with a harmless fake action result; the real CFG/Steam path has not been executed end to end.
- No runner release is currently published in the reviewed mirror manifest.
- The backend repository is at `C:\Users\Admin\Desktop\CafeLauncherBackend` on `main`; web-action source and focused API coverage are locally committed. Nothing has been deployed.
- `Get-PCDiagnostics -AsObject` exposes a structured, versioned, local-only Steam/CS2 inventory without opening UI, scanning hardware/apps, or including the Steam account ID. The ordinary dashboard call still returns its existing text report. The local runner round trip returned Steam and CS2 discovery results.
- The backend contains a local, opt-in ticket/session/claim/progress/result API for `detect-pc`, `play-exec`, `apply-profile`, and `apply-graphics`; it requires an explicit HTTPS `CAFELAUNCHER_ACTION_ORIGIN`. Its 30-test suite passes locally; no production HTTPS service is configured or deployed for these APIs.
- The backend clone now serves a first web app at `/` and the previous status dashboard at `/status`; `/viewer` and `/v1/*` remain routed in source. The local route change is not deployed; the live public `/status` returned 404 during the baseline check.
- The web app loads the existing profile schema and offers exactly three selected-profile buttons: Apply profile, Apply game graphics, and Play + Exec. Each asks for in-page confirmation, invokes `cafelauncher://`, polls only the current browser session's request, and displays bounded result data as text. Capture CS2 and Edit Profile are deliberately absent. A manual protocol link covers blocked protocol activation; uncertain request state keeps actions disabled until the player confirms they checked the PC. Each action uses the exact immutable primary-backend snapshot and refuses unresolved local edits or an unapproved revision rollback. Apply Graphics reuses the pinned module with dialogs suppressed and structured results. Apply profile reuses the Windows routine and now applies supported Logitech live DPI synchronously with pinned-helper verification and read-back. The first web action after a runner update can discard pending local profile edits only after current backend snapshots for all affected profiles are verified.
- The browser retries an ambiguous ticket-create response using the same random request ID, relying on the API's idempotency so a lost HTTP response cannot create a second action ticket.
- The backend standard-library suite now has 30 tests, including action session/ticket/claim/result round trips, new profile-action allowlists and bounded results, CSRF and origin rejection, concurrent ticket idempotency, browser-session result isolation, idempotent claims/results, interrupted-result consistency, and expired-upload/late-result rejection; all 30 passed locally.
- An isolated local runner/backend Detect PC round trip completed with a `COMPLETED` result and structured Steam/CS2 discovery. A second isolated run exercised C# Play + Exec result validation/upload using a fake immutable release and harmless PowerShell stub. Both used a loopback-only HTTP source override and bypassed OS protocol registration; all temporary databases, fake releases, runner builds, and cache files were removed. Neither is a production HTTPS or café pilot.
- `tools/Test-WebPlayExec.ps1` passed its mocked action-flow checks. It stubs CFG installation and Steam launch, so it verifies branching/result semantics without changing a real CS2 install or launching a game. `tools/Test-WebProfileActions.ps1` checks profile-action result mapping, pending-edit and Steam preflight blocks, backend outage handling, and graphics pending-edit blocking with side effects stubbed.
- Deep Freeze deployment assumption: provision the portable runner and per-user protocol handler in the frozen base image, or reprovision during the maintenance/login cycle. Validate on a café PC before rollout.
- The .NET Framework runner source compiles locally with the installed Framework C# compiler. Runner v0.5.0 includes automatic updates, but its release workflow has not run for this unpushed change. `cafe.bat` is CRLF and its embedded PowerShell parser passes on Windows PowerShell 5.1. Runner install/compatibility checks, web profile/Play + Exec action tests, Logitech parsing/device tests, graphics tests, JavaScript syntax check, and all 30 backend API tests pass. The broad launcher test passes under Windows PowerShell 5.1; the default PowerShell 7 host failed its C# test-harness compile because of assembly references.
- Physical Logitech DPI read-back, café/Deep Freeze persistence, production HTTPS web action/result round trip, and real Steam/CS2 parity remain unverified. This source is locally committed only after review; nothing is pushed or deployed.
- Remaining rollout work: locally commit the three-action implementation, then publish a compatible immutable runner release only after the user authorizes pushing; exercise browser confirmation/polling through deployed HTTPS, register and verify the handler on a café PC, test reboot/Deep Freeze restore, and run parity checks for all three actions before enabling broad rollout.
