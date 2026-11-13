# CafeLauncher Web Action Speed Improvement Plan

## Goal

Make web actions 1–3 feel faster without applying stale profile data, skipping settings that changed outside CafeLauncher, or making runner updates less reliable.

The four ideas covered here are:

1. Measure where action time is spent.
2. Warm up the runner when that would save meaningful time.
3. Reduce duplicate profile reads safely.
4. Use Apply Profile to prepare apps before Play + Exec when that fits the player's workflow.

## Implementation status

- **Step 1:** The page now checks action status every 700 ms initially, increasing by 150 ms up to a 1-second maximum. It records the selected profile revision and shows that revision beside the profile summary and while starting an action. Collecting real cold/warm café-PC timing reports remains a rollout task.
- **Step 2:** Runner v0.7.6 adds a page-open warm-up, throttled to one attempt every four hours per browser profile. It checks for a runner update, warms the verified CafeLauncher cache, and prefetches the graphics and Logitech helpers after checking their pinned hashes. It does not apply settings or launch apps. Browsers can block automatic external-protocol starts or ask the player to allow them; setup and click-to-launch remain necessary fallbacks.
- **Step 3:** Implemented end to end. The backend pins the current profile revision to each action ticket, rejects a stale page revision, and returns the pinned revision to the runner. The runner passes it to CafeLauncher, which reads that exact immutable bundle directly. The page refreshes and retries once when its profile display was stale.
- **Step 4:** Existing action behavior already follows this guidance: Apply Profile may start the configured apps, but Play + Exec remains independent and rechecks Steam, CS2, and CFG targets. No prior result is treated as proof that the PC is still ready.

## Current flow

```text
Page loads the selected profile bundle for display
  → Player clicks an action
  → Browser creates a short-lived backend action ticket
  → Windows starts CafeLauncherWebRunner through cafelauncher://
  → Runner checks for its own update, then claims the ticket
  → Runner verifies the launcher source and starts the requested CafeLauncher action
  → CafeLauncher reads and verifies the current profile bundle
  → Local settings or CFG work runs and reports progress
  → Runner submits the final result; the page polls until it receives it
```

### Existing timing and cache behavior

- The web page records an action event timeline. Downloaded action reports show server-recorded intervals between events and total time to the last event. This includes local work and network/server reporting delay; it is not CPU-only timing.
- CafeLauncher reports elapsed seconds for completed local progress stages. The first web action stage may not appear until after the runner's pre-claim update check has finished.
- The runner checks GitHub for a newer runner release each time it is activated. It downloads the runner only when a newer version is found and verifies the published size and SHA-256.
- CafeLauncher code and the pinned graphics helper are cached locally after their hashes are verified. GitHub launcher metadata has a three-minute cache. The runner still checks the backend launcher manifest and decides whether the verified GitHub `main` launcher is newer.
- Apply Profile checks the pinned Logitech helper cache. The launcher can prepare that helper in parallel with profile settings; the runner and launcher avoid repeatedly downloading it once the verified copy is present.
- Apply Profile and Apply Graphics already avoid some writes when live read-back or file comparison confirms that settings match. Play + Exec still needs to validate Steam and CFG state for every launch.
- The page's request polling begins at 700 ms, increases by 400 ms, and tops out at 3 seconds. A completed action can therefore take up to the current polling interval to appear on the page.

  **Updated:** polling now increases by 150 ms and tops out at 1 second.

## Step 1: Measure action timings

### Current flow

The page already produces event timelines and CafeLauncher reports elapsed time for local stages. These measurements can distinguish work done by the runner, backend calls, local settings application, and result reporting. Runner update-check time before its first claim event is not currently shown as a distinct page stage.

### Plan

1. Collect action reports for Apply Profile, Apply Game Graphics, and Play + Exec.
2. For each action, compare a cold run (first run after setup or reboot) with a warm repeat (verified runner, launcher, and helper already cached).
3. Record time to first runner event, each local stage, time to the final server event, and time from the server's final event to the page displaying the result.
4. If the report cannot separate runner startup/update checks from launcher work, add bounded duration fields for those phases. Keep private request IDs, tokens, local paths, and raw device identifiers out of uploaded events.
5. Check whether the page's 3-second maximum polling interval creates visible delay. If it does, reduce the maximum wait to about 1 second or evaluate a server-sent event stream. Keep polling requests bounded and avoid a high-rate loop when a runner is waiting on a long local operation.

### Verification

- Confirm all phases use monotonic elapsed timers locally; do not subtract timestamps from different PC/server clocks to estimate duration.
- Confirm action reports continue to redact paths and account identifiers.
- Compare cold and warm results for each action before choosing the next optimization.

## Step 2: Warm up the runner

### Current flow

The browser does not contact the local runner until the player clicks an action. Windows starts the registered protocol handler, and the runner checks GitHub for a newer runner release before claiming the action. After claim, it checks the immutable backend launcher package and the GitHub `main` source, selecting the newer supported and hash-verified CafeLauncher copy. Cached code avoids a full download, but update metadata and ticket checks still happen.

### Plan

1. Use Step 1 timings to decide whether native runner startup or update metadata checks are a material part of the wait.
2. If warm-up is justified, prototype a preparation operation that verifies runner updates and primes only hash-verified code/helper caches. It must not apply profile settings, launch Steam/FACEIT, or change game files.
3. Prefer a user-initiated preparation action for the first prototype. Opening a web page does not reliably grant permission to launch a local application; browser behavior may block or prompt for automatic protocol activation.
4. Consider an always-running tray/background runner only if a preparation action does not save enough time. Document startup behavior, per-user installation, CPU/memory use, update behavior, logout behavior, and Deep Freeze/base-image setup before adopting it.
5. Keep runner version enforcement. A cache must not allow a runner below the backend's minimum supported version to claim actions, and it must not silently keep using unverified files.

### Verification

- Test first run, warm repeat, no-network startup, update available, hash mismatch, and backend minimum-runner increase.
- Confirm the preparation flow is clearly separate from applying settings and does not ask players to approve an unexpected action.
- Verify that a Deep Freeze reboot restores a usable base installation or causes the documented first-run setup behavior.

## Step 3: Reduce duplicate profile reads with a server-pinned revision

### Current flow

- The browser fetches `/v1/profiles/{profile}/bundle` when the page loads or the player changes the selected profile. This supplies summary display data.
- The browser's POST to `/v1/actions` currently contains the action, profile name, and client request ID. It does not include profile data or a pinned revision.
- For Apply Profile and Apply Graphics, CafeLauncher reads the current profile endpoint to get its revision, then reads the immutable bundle for that revision.
- Play + Exec also resolves the latest revision and fetches the corresponding immutable profile/graphics/CFG bundle.
- The browser's summary data is not reused for applying settings. That is intentional: browser data can be stale or modified and must not become an authority for local actions.

### Plan

1. Add an optional `profile_revision` column to the backend action request table. Detect PC requests have no profile revision.
2. When the backend creates a profile action ticket, capture the current profile revision from authoritative backend storage and store it with the ticket. Do not accept profile values supplied by the browser as the action snapshot.
3. Return the stored revision in the runner's claim response, protected by the existing one-time action ticket and claim capability.
4. Pass that revision into CafeLauncher. Add an exact-revision option to `Get-CafeWebActionSnapshot`; fetch the immutable bundle for that revision directly instead of first reading the latest profile just to discover the revision.
5. Use the same pinned revision path for Apply Profile, Apply Graphics, and Play + Exec. Preserve the current checks for pending edits, backend revision rollback, Steam session, unique CS2 installation, and pinned target recheck.
6. Keep the browser's bundle for display. The server may return the action's pinned revision so the UI can detect when its displayed summary is stale. If the displayed revision differs, refresh the summary before continuing or clearly show the revision the action will use.
7. Keep action request retries idempotent. Reusing a client request ID must return the original ticket and its original pinned revision, not a newer snapshot.

### Safety and compatibility requirements

- The backend remains authoritative; the runner must never trust profile values supplied by page JavaScript.
- An action uses one immutable bundle revision for profile, graphics, and CFG content.
- Missing, expired, or unavailable revisions fail before local settings or files are changed. Do not silently fall back to a different revision or a mirror for web actions.
- Detect PC remains independent of profile revisions.
- Add a backwards-compatible database migration and define how in-flight requests created before the migration are claimed.

  **Implemented behavior:** requests created before the migration retain a null revision. The new runner reports them as failed before starting CafeLauncher; it will not guess which revision to apply. Clients that do not send a page revision remain compatible: the backend still pins the current authoritative revision.

### Verification

- Backend tests: ticket stores and returns its revision; retries return the same revision; detect PC has no revision; expired/invalid tickets cannot claim; concurrent profile updates do not mix bundle revisions.
- Runner tests: missing/invalid revision blocks profile action; valid revision reaches launcher without exposing it as a profile value.
- Launcher tests: exact-revision read uses one bundle and preserves rollback/pending-edit checks; no latest-profile read occurs in that path.
- Cross-repo schema check and full CI/deployment tests.

## Step 4: Use Apply Profile to prepare apps before Play + Exec when useful

### Current flow

- Apply Profile applies mouse settings, supported NVIDIA settings, the selected profile CFG, and Logitech live DPI. When the profile's `LaunchApps` setting is enabled, it also starts Steam, FACEIT Anti-Cheat, FACEIT matchmaking, and other configured items.
- Play + Exec is a separate action. It requires an active Steam session and a unique CS2 installation, reads a verified profile/graphics/CFG bundle, installs and verifies the reset baseline and selected profile CFG, rechecks the Steam session, then asks Steam to start CS2 with the CFGs.
- Play + Exec does not repeat the profile's `LaunchApps` step. If Apply Profile already started Steam, Steam may be ready sooner, but Play + Exec still has to verify and install the current CFGs and request CS2 startup.

### Plan

1. Keep Apply Profile as an optional readiness step when the player needs profile settings or the configured apps started.
2. Do not require it before every Play + Exec. If Steam and the required apps are already ready, another full profile apply adds work.
3. Show readiness from the most recent verified Apply Profile result only as a hint. Play + Exec must continue checking the active Steam user, CS2 install, CFG target, and current profile revision at action time.
4. Do not skip baseline/profile CFG validation based only on a prior action. A future write-skip optimization may compare the exact expected file bytes or hash and read back the target before reporting success.
5. If considering a combined Apply Profile + Play action later, keep it separate from this speed plan until its confirmations and side effects are designed. It would open apps and launch a game in one flow, so it needs explicit action text and clear partial-failure behavior.

### Verification

- Test with Steam closed and already open, FACEIT closed and already open, and CS2 already running.
- Confirm Play + Exec never launches against a changed Steam account or a different CS2 config path.
- Confirm a successful prior Apply Profile does not make the page claim Steam is still ready after the user closes or switches it.

## Recommended implementation order

1. Collect cold/warm action timings from real café PCs, including whether browser policy allows the page-open warm-up. The local instrumentation and warm-up attempt are implemented, but the browser/Deep Freeze behavior needs a real café-PC check.
2. Server-pinned revisions are implemented and locally tested; deploy only after the backend and Cs-script changes are both ready and the runner release is published.
3. Evaluate the warm-up timings and external-app prompt impact before changing its four-hour throttle or making it persistent at Windows login.
4. Keep Apply Profile as optional app preparation; avoid making it a required extra click.

Commit each major change locally after its tests pass. Push and deploy only when explicitly requested.
