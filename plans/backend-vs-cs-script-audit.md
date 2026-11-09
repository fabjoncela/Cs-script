# CafeLauncher Backend vs. CS-Script Parity and Bug Audit Plan

## Objective

Audit the complete behavior that moved from the pre-backend CS-Script/GitHub implementation to CafeLauncherBackend, then identify regressions, changed semantics, new failure modes, security problems, operational gaps, and useful follow-up updates. The audit must compare actual implementations and deployed behavior, not just the intended API contract.

This is an audit plan. It does not authorize changing production data, publishing a launcher, changing the server, or modifying users' game/Windows settings.

## Comparison set and evidence rules

Use three explicit sources and label conclusions by source:

1. **Before:** launcher commit `6c5caf9` (release marker `2026.11.07.18`) is the parent of backend migration commit `d77401b`; it is the precise source baseline immediately before backend client adoption.
2. **After, client:** the unversioned directory copy at `C:\Users\Admin\Desktop\Cs-script-codex-backend-preferred-windows-test` reports release marker `2026.11.08.4`. Its backend migration code matches the early development period, but it has no `.git` metadata. Use the recoverable Git commits (starting at `d77401b`, ending at `41fbec7` for the nearby backend-preferred testing snapshot) and the current `main` history for attribution. Current launcher `main` is `d18420a`; it contains the migration plus subsequent fixes and unrelated post-migration work.
3. **After, service:** `C:\Users\Admin\Desktop\CafeLauncherBackend` is currently checked out at `adecb37` on `codex/cafelauncher-profile-viewer`, which equals fetched `origin/main`; its local `main` is `7a56930` and is four commits behind. The backend working tree is clean at this check. Verify the deployed Ubuntu commit independently before making deployment claims.

For every finding, record: component; before behavior; after client behavior; after server behavior; expected contract; evidence/source location; reproducibility; user/data impact; severity; and proposed correction or accepted intentional change. When source, deployment, and documentation disagree, report the disagreement instead of silently choosing one.

## Phase 0 — Freeze the audit scope and establish baselines

- Record `git status`, branch, commit, remotes, and relevant diffs in each repository/snapshot. Preserve all dirty changes. Do not reset, clean, stash, or rewrite history.
- Locate the exact last pre-backend launcher release, matching `cafe.bat`, `graphics/ApplyGraphics.ps1`, profiles, graphics presets, CFGs, and tests. Record hashes for the source bundle used in the comparison.
- Identify the backend integration snapshot's source revision, release marker, and whether its `context.md` and tests describe code that is actually present.
- Compare backend working branch, backend `main`, deployment workflow's checked-out ref, and live server version/health. Record which commits are deployed; do not infer deployment from a local branch or README.
- Establish a read-only data baseline: six profile JSON files, six graphics JSON files, six CFG files, current release/module artifacts and hashes, local imported backend revision numbers, mirror manifest generation/hashes, and available prior GitHub file history. Redact credentials and account identifiers.
- Inventory the environments needed for later verification: Windows PowerShell 5.1/WinForms; Python versions used in CI; Ubuntu/systemd service; SQLite data directory; Tailscale Funnel/public HTTPS route; GitHub mirror and deployment runner.

**Exit condition:** the before/after versions and live deployment are identified well enough that every later result can be tied to a specific source revision or runtime.

## Phase 1 — Build a complete responsibility and request inventory

Trace each action end-to-end from UI/event to client helper, HTTP request, server handler, validation, persistence, mirror/publisher, and user-visible result. Use source searches to find every network call, not just functions named “backend.” Include indirect calls from `graphics/ApplyGraphics.ps1`, release helpers, updater code, and subprocesses.

Inventory at least:

- Initial startup profile selection and refresh; dashboard/card refresh; edit; Apply; Play + Exec; Apply Graphics; profile copy/reset; local save; Save & Sync; pending retry; conflict resolution; cache/local fallback.
- Reads/writes for profile JSON, graphics JSON, profile CFG, sensitivity, captured CS2 convars/binds, graphics history, launcher update metadata/assets, graphics module, helper binaries, and GitHub/API status/quota display.
- Profile/release import and publishing tools; GitHub mirror worker; scheduled/automatic deploy; database initialization and backup/restore.
- All direct GitHub/raw URLs and assumptions still present after integration. Classify each as migrated, mirror-only, source/CI/publisher-only, unrelated runtime dependency, or accidental leftover.

Create a responsibility matrix with one row per user action/resource and columns for old source/endpoint, new client function, new endpoint, fallback/cache, authorization, validation, persistence/consistency, user-visible success/failure, tests, and unresolved questions.

## Phase 2 — Compare functional behavior and data semantics

### A. Read and fallback behavior

- Compare old Contents/raw GitHub reads and any local-cache behavior with backend-first reads, mirror fallback, and local fallback.
- Verify profile identity/schema checks, missing or malformed file handling, invalid UTF-8/JSON, size bounds, timeouts, redirects, status interpretation, and stale-data decisions.
- Check that the three values in a profile bundle (profile JSON, graphics JSON, CFG) always come from a consistent revision. Test mixed revisions, stale ETags, mirror manifest changing between fetches, and backend/mirror disagreement.
- Verify cache-busting and cache headers through the actual proxy/Funnel. Confirm mutable reads cannot remain stale in browser/proxy/client caches and immutable release URLs remain immutable.
- Check first-run behavior, missing profile, missing CFG, no network, server timeout, mirror outage, backend recovery, and recovery when local data is older than cloud data.

### B. Save and sync semantics

- Compare old per-file Contents API writes (blob SHA, commit SHA, sequential CFG/profile/graphics operations, partial-sync reporting, and read-back) to new atomic bundle PUT and revision check.
- Check exact payload assembly: exported profile fields, `GraphicsSettings`, profile name/schema, CFG selection, captured/pending sensitivity, convars/binds/reset sentinels, voice-key reconciliation, URL rewrite, and omission/removal of legacy fields.
- Check unchanged bundle behavior, canonical JSON ordering/number conversion, newline/encoding treatment, and whether semantically equal but byte-different CFGs or JSONs create unnecessary revisions.
- Exercise first revision (`expectedRevision=0`), normal update, stale revision/409, simultaneous writes, lost response after commit, client retry, duplicate retry, server restart during commit, and client restart with a durable pending queue.
- Verify the queue is written before network mutation, contains only intended data and no token, is atomic/corruption-detecting, scoped per profile, cleared only after verified acceptance, and retained on failures. Check behavior if a queue file is truncated, malformed, copied, or conflicts with newer local edits.
- Compare the old “partial sync” states and recovery against the new all-or-nothing transaction. Confirm unchanged resources do not get lost when the client sends a full bundle and that profile-only/CFG-only edits cannot silently revert newer graphics or vice versa.
- Confirm success read-back checks all three payloads and revision/hashes, and that a mismatch or malformed response keeps edits pending. Confirm a successful write with a dropped response is recognized by a safe content match without overwriting a newer revision.
- Verify UI prompts accurately explain local save, cloud sync, conflict, fallback, and pending state. Confirm pending edits from the old GitHub client are blocked or resolved without accidental redirection or data loss.

### C. Validation and schema parity

- Compare all client validation with `validation.py` and actual server enforcement: profile allowlist, required fields, types, ranges, profile-name/file mapping, URLs, optional legacy fields, graphics enums/ranges/policies, refresh mode, and CFG command parsing.
- Test boundary values, booleans-as-integers, nulls, duplicate/unknown keys, huge/deep JSON, Unicode, control characters, malformed base64/content, overlong strings, path traversal attempts, percent-encoded names, and unusual case variants.
- Ensure server canonicalization (including `DisplayPolicy`, legacy CFG URL normalization, and JSON serialization) matches the client read-back comparison and does not change user intent.
- Ensure unknown fields are rejected or preserved intentionally; verify that future schema versions fail safely rather than being silently downgraded.
- Compare CFG writers/parsers for duplicate commands, comments, quoted values, whitespace, CRLF/LF, UTF-8 BOM, escaped strings, duplicate binds, reset sentinels, and sensitivity uniqueness/range. Ensure unrelated CFG content survives editing.
- Review crosshair alias migration and other supported convar/bind allowlists so the backend doesn't accept values the launcher cannot apply or reject valid legacy data the launcher intentionally handles.

### D. History and restore behavior

- Compare GitHub commit-based graphics history with SQLite revision history and mirror history. Confirm the meaning of “current plus prior versions,” sorting, timestamps/time zones, duplicate graphics snapshots, profile-only or CFG-only revisions, history limits/cursors, and deleted/missing revisions.
- Confirm initial import starts a new history and clearly handles old GitHub history. Check whether the UI labels backend revisions in a way users can interpret and whether restores stage only intended fields without saving/applying automatically.
- Check consistency among API history, mirror history manifest, client history cache, and current revision after an interrupted mirror update.
- Review the dirty `server.py` profile history endpoints separately: confirm whether they are intended, committed, tested, deployed, documented, and consumed by a client. Avoid assuming the working-tree-only feature exists in production.

### E. Release and artifact behavior

- Compare old launcher update check/download and pinned graphics-module fetch to the new release manifest, immutable asset routes, server-side stored hashes/sizes, client verification, and current remaining GitHub/raw URLs.
- Verify version parsing/sorting (including date and release suffix), minimum supported version, release notes, cache behavior, invalid/missing asset handling, rollback prevention, and “latest” consistency.
- Test interrupted asset upload, retry with same/different bytes, manifest publication order, asset replacement after publication, partial release, old release retention, artifact size limits, SHA mismatch, path traversal, and updater behavior if a verified artifact cannot be launched/replaced.
- Determine which channel actually publishes `cafe.bat` and `ApplyGraphics.ps1` today (backend publish tool, GitHub workflow, Drive, or manual path). Check whether the published pair is version-matched and atomically identifiable. Keep Logitech helper and unrelated GitHub downloads explicitly in scope even if they are not part of the backend migration.
- Confirm that a GitHub mirror failure cannot make a committed backend save appear failed or encourage duplicate writes; verify durable mirror retry, state reporting, and recovery after process/machine restart.

## Phase 3 — Security and privacy review

- Trace sync and publish token entry, lifetime, in-memory storage, exception paths, async workers, retry, UI disposal, logs, crash traces, local queue, environment files, CI secrets, and server request logging. Test that tokens never enter profile JSON, queue files, query strings, logs, API errors, mirror commits, source, screenshots, or artifacts.
- Verify sync and publish tokens are distinct, minimum length/entropy expectations are documented, constant-time comparison is used where applicable, and unauthorized/expired/missing tokens fail consistently without leaking which secret was wrong.
- Test HTTPS and certificate validation from café-client conditions. Confirm redirects cannot forward bearer authorization to a different host; check host allowlists, URL construction/encoding, proxy behavior, and request size/body limits.
- Review public exposure of profiles, CFGs, history, release artifacts, and viewer. Confirm the data is intentionally public and no private account data/secrets have entered imported or mirrored content.
- Check the API's loopback-only bind, Funnel route, firewall/listener state, systemd hardening, file ownership/modes, separate environment files, SQLite permissions, backup location/access, runner credentials, and GitHub mirror token scope.
- Review denial-of-service controls: bounded workers, socket/request timeouts, maximum body, JSON nesting, SQLite lock behavior, rate limiting or practical abuse controls, oversized history requests, and resource usage under repeated requests.
- Inspect error messages for stack traces, filesystem paths, request bodies, tokens, internal hostnames, and database details.

## Phase 4 — Persistence, deployment, and recovery review

- Verify SQLite transaction boundaries, WAL/journal configuration, busy timeout, foreign keys/schema migrations, crash consistency, disk-full behavior, corrupt DB startup, and concurrent API/mirror worker access.
- Confirm backups capture a consistent DB plus matching release/helper assets. Exercise a restore to an isolated location/service and verify health, latest profile revisions, history, release hashes, and mirror generation before any live restore is considered.
- Verify automated deployment is serialized, tests the exact commit, atomically switches code, restarts the right service, preserves the data directory and environment, and rolls back source changes when health checks fail. Confirm branch protection/runner permissions and deployment logs.
- Test service restart and server reboot behavior, Funnel availability/HTTPS, API health semantics, mirror worker retries/backoff, stale mirror status, pending generation recovery, and alerting/diagnostics for prolonged failure.
- Inspect data migration/import idempotency, source-root selection, validation before transaction, accidental re-import protection, initial revision metadata, and comparison against source hashes. Confirm whether old histories are intentionally omitted and documented.

## Phase 5 — Build the verification matrix

Use existing tests as evidence, then add only focused missing cases after the audit has identified a gap. Do not treat unit tests as proof of WinForms, network, proxy, deployed-service, or actual café-PC behavior.

1. **Static/source review:** request inventory; no unintended GitHub runtime calls; every endpoint and file path traced; schema and limits cross-checked; release/module pins and workflows mapped.
2. **Backend unit/API tests:** validation boundaries; atomic writes; conflict and idempotency; exact response/error schemas; history; publishing; asset integrity; mirror persistence and retry; backup/import behavior.
3. **Windows client fixture tests:** profile/graphics/CFG equivalence; queue durability; read-back; 409 handling; partial/offline/retry; mirror hash validation; profile editor state; updater/module hash checks. Prefer mocked endpoints and isolated temporary directories.
4. **Cross-version contract tests:** send the pre-backend repository's valid data through the new API, read it back through the integrated launcher parsers, and compare semantic values and hashes. Include all six profiles and edge fixtures.
5. **Local end-to-end staging:** isolated API/database and disposable mirror repository; anonymous reads, token writes, stale writer, lost-response retry, mirror-down/recovery, history, release upload/download, and client fallback. No live user profile or café machine writes.
6. **Deployed read-only smoke:** check live health, six profile/graphics/CFG bundles, revision/ETag consistency, mirror manifest/hash equality, HTTPS/certificates, history, release manifest/assets, and service/mirror status. Do not send a live sync or publish request during this step.
7. **Authorized canary sync/publish:** only after staging passes and separately approved, use a test profile or designated canary, record before/after data/revisions, verify client read-back and mirror completion, then confirm no unrelated bundle changed.
8. **Recovery drill:** restore a private backup into an isolated service and demonstrate profile/history/release/mirror consistency. Do not test by overwriting live production data.

For every check, record setup, exact version, expected result, observed result, logs/response status (redacted), and cleanup. Separate automatically repeatable tests from manual UI/live-service smoke checks.

## Phase 6 — Findings, fixes, and release readiness

- Classify findings as blocker (data loss, wrong profile/settings applied, unauthorized write, unsafe artifact), high (sync/recovery/security failure), medium (feature parity or misleading status), low (diagnostic, documentation, or efficiency issue), or intentional change with evidence.
- For each bug, write a minimal reproduction and identify the owning layer: launcher, API, mirror/publisher, deploy/ops, data import, or contract/docs.
- Build a fix order that addresses data integrity/security first, then core read/write parity, offline/recovery, history/release, UI and operations, and documentation.
- Re-run focused tests plus the full relevant project/backend suite after fixes; verify current deployed code matches the tested commit before any release decision.
- Update the project context, backend README/API contract, deployment docs, and test map only where verified behavior changed. Do not erase pre-backend semantics/history documentation that is still needed to interpret old pending data or revisions.
- Produce a final comparison report with: tested baseline versions; parity matrix; confirmed regressions; risks not reproduced; tests and live checks completed; changed/unchanged behaviors; required fixes; deferred items; and a release-readiness decision with evidence.

## Initial watch list from source inspection

These are questions for the audit, not conclusions that a bug exists:

- The comparison baseline is now pinned: pre-migration `6c5caf9` → migration `d77401b`; use current launcher `main` `d18420a` for the remaining fixes. The workspace now has no tracked dirty changes; retain the untracked `BACKEND_API_PLAN.md` and audit plan.
- The backend-integrated directory copy is release `2026.11.08.4` without `.git`; do not treat its exact contents as the final migrated client. Current tracked source and history are available in the main ProjectCafe Git repository.
- Backend code at `adecb37` includes profile revision-history routes and tests. Local backend `main` at `7a56930` is behind; the public status page independently reports deployed commit `adecb37a3e17`.
- The migration appears to change graphics history from GitHub commits to backend revisions and starts a fresh service history at import. Quantify this behavior change and make old history expectations explicit.
- The integrated snapshot still has GitHub/raw dependencies, including updater/module paths and potentially helper downloads. Distinguish intended source/release infrastructure from migration leftovers, and verify all residual calls' failure modes.
- The old sync wrote several files separately, while the backend accepts an atomic full bundle. Validate how a full-bundle client prevents stale fields in one resource from overwriting newer values in another.
- The backend and launcher README/context describe mirror fallback and pending retries; continue checking actual code paths rather than relying on prose.
- **Confirmed client retry flaw (manual retry after ambiguous success):** `Sync-ProfileToBackend` persists a queue specifically so it can recognize a bundle that committed even if the response was lost. But the profile editor's `$saveEditorValues` unconditionally calls `Clear-CafeBackendQueue` before every Save & Sync attempt. If a PUT committed and the client then timed out or failed during read-back, a user retry deletes the only copy of the exact payload; the next payload builder still has the prior `BackendRevision`, sees the server's newer revision, and reports a conflict instead of recognizing the accepted bundle. Local edits remain stored, so this is a recoverability/UX defect rather than confirmed data loss. `Test-BackendRetry.ps1` exercises the health worker with a mocked `Sync-ProfileToBackend`; it does not cover commit-success/response-loss through the editor and durable queue path.
- **Confirmed unsafe local CFG fallback during a later network failure:** normal Apply/Play + Exec first refreshes a profile and asks for confirmation only if that refresh reports local/mirror fallback. `Get-ProfileCfgSource` then independently fetches the bundle again; if that second fetch fails, it silently installs `%LOCALAPPDATA%\CafeLauncher\cfg-cache\<name>.cfg` or a CFG beside the launcher (lines 3334–3353). That cache may be stale, and the fallback path does not ask for confirmation. The installer's syntax/read-back checks prove the chosen file copied correctly, not that it is the latest cloud CFG. This violates the documented rule that local fallback requires confirmation when both cloud sources fail.
- **Potential stale-primary acceptance after DB restore:** the launcher rejects a mirror snapshot older than its saved `BackendRevision`, but `Get-CafeCloudSnapshot` returns a successful primary backend snapshot without comparing it to that saved revision. The documented backend restore procedure can restore an older SQLite backup and therefore lower a profile's revision. An already-used launcher can then silently load/apply older primary data and replace its remembered revision. Verify the intended restore semantics and add explicit downgrade detection or an authenticated restore-generation mechanism if old revisions must not be accepted silently.
- **Migration scope gap, likely intentional:** the backend implements release-manifest and launcher/module artifact routes, but the current CafeLauncher updater still checks/downloads `cafe.bat` from the original `Cs-script` GitHub repository; the graphics module's standalone GitHub fetch also remains. Treat this as an explicit non-migrated responsibility unless the backend project claims otherwise, and verify that docs and publishing workflows agree on the actual release source.

## Completion criteria

The audit is complete when the before/after inventory covers every runtime and publishing responsibility; each intended behavior has parity evidence or a documented intentional change; all blockers and high-severity risks have a reproducible finding or a clear reason they could not be tested; staged contract, failure, recovery, and artifact checks pass; the deployed version is identified; and the final report states what remains before a safe default switch/release.

## Proposed remediation plan and decisions

This section turns the findings into a fix sequence. The items marked **Recommended default** can be implemented with the current behavior preserved. The items marked **Decision needed** change recovery or migration policy and should be settled before implementation.

### 1. Protect ambiguous-sync recovery state (P2)

- **Goal:** never discard the only exact payload that can prove a timed-out sync was accepted.
- **Chosen approach — simpler option:** block editor saves while an ambiguous queued write exists. Offer Retry / Review current backend / Cancel, and only allow another save after the pending operation has been reconciled. Retry must use the existing queued payload; keep the queue and local profile state unchanged on network failure, read-back failure, user cancellation, or conflict. Clear it only after the backend confirms the write (or the user explicitly resolves/discards it through the existing confirmation flow).
- **Deferred alternative:** treat the pending queue and a newer editor draft as separate durable records, reconcile both against the backend, and preserve them independently through conflicts. This supports editing while offline but requires more state and UI; it is not the selected approach.
- **Verification cases for a later implementation pass:** lost PUT response after server commit; read-back timeout; manual retry with unchanged values; editor re-save with changed values; user answers No/cancels; backend conflict with different content; restart between each step. Verify local edits and queue evidence survive every failure.

### 2. Close the late CFG fallback confirmation gap (P2)

- **Chosen approach:** pass the already fetched and confirmed cloud snapshot from profile refresh into CFG installation so the same revision supplies both profile and CFG. Avoid a second independent cloud read for that action. If no verified cloud snapshot is available, require explicit confirmation before using a local CFG; identify the local path and its cached revision/hash if known, and keep cancel as the default.
- **Deferred alternative:** never install local CFG on a cloud-read failure; stop Apply/Play + Exec and ask the user to retry later. This eliminates stale fallback but reduces offline capability.
- **Verification cases:** backend succeeds then fails on the second fetch; mirror succeeds after backend failure; both cloud reads fail with an old cache; no local CFG; user declines confirmation; verify the installed bytes came from the displayed source.

### 3. Warn before accepting a lower backend revision (P2 candidate; selected)

- **Chosen approach — warn on revision rollback:** compare every primary backend snapshot to the locally remembered revision, just as for mirror fallback. If the backend revision is lower, show a warning that older settings may be applied. Default to cancel and retain local values; allow continuing only after the user explicitly confirms an intentional restore. Update the remembered revision only after that confirmation and verified snapshot load. If the user cancels, keep the previous revision floor and do not apply the older data.
- **Deferred alternative:** use a monotonic restore epoch or an operator-marked restore event so the client can distinguish an intentional restore from stale data without asking each user. This requires API/client schema and restore-procedure changes.
- **Deferred alternative:** require restore tooling to create a new higher revision containing the restored values. This avoids per-client rollback prompts but requires carefully defined history semantics and a staging restore drill.

### 4. Make publisher retries safely idempotent (P3)

- **Chosen approach — exact-match retry:** make `publish.py` inspect existing state after an ambiguous result. For a launcher release, compare the existing published manifest, launcher hash, module hash, and release notes with the requested inputs; report success only when they match exactly. For a helper version, compare the existing asset metadata/hash. Preserve conflicts for any mismatch and never overwrite a published version.
- **Partial release handling:** retry identical staged asset bytes; if the intended bytes changed after a partial upload, require a new version or explicit admin cleanup of the incomplete version.
- **Verification cases:** response lost after each artifact PUT, response lost after manifest PUT, retry same inputs, retry changed launcher/module/notes, partial release with one asset missing, helper retry, and latest-version selection.

### 5. Document and recover incomplete artifact staging (P3 operational concern)

- **Chosen approach:** document that incomplete unpublished versions may contain staged files and add a read-only inspection report identifying staged versions with no published DB record, including their age and file hashes. Same-byte retry remains allowed; if the intended bytes differ, use a new version or request explicit operator cleanup.
- **Cleanup safeguards:** no automatic deletion. A separate cleanup action must require explicit operator confirmation, recheck under the server's database lock that the version has no published DB record, and remove only the selected orphan staging files. Never remove files for a published release. Keep inspection and cleanup separate so operators can review what would be removed first.
- **Deferred alternative:** implement age-based automatic cleanup only after defining a safe retention period and proving the API/publisher cannot still be using the staging directory. Do not automatically delete potentially recoverable assets without a reviewed policy.
- Include a crash-between-file-replacement-and-DB-commit case in the isolated publisher/recovery drill.

### 6. Correct migration documentation (P3)

- Update `CafeLauncherBackend/README.md` to replace the stale “Before connecting CafeLauncher” roadmap with the deployed architecture: backend-first profile reads and bundle sync, revision checks, local pending queue, read-back, verified GitHub mirror fallback, and current history behavior.
- List remaining GitHub/Drive paths explicitly: launcher update metadata/download, pinned graphics module source, Logitech helper download, GitHub source/CI, and any actual release publishing path. Distinguish active runtime calls from source/CI and dormant legacy code.
- State that initial backend history starts at revision 1 and old GitHub history is not imported. Document the intended restore/revision policy after decision 3.

### 7. Remove or quarantine dormant legacy sync code (P3 maintenance risk; decision needed)

- First confirm no supported external script or user workflow invokes `Refresh-ProfileFromGitHub`, `Sync-ProfileToGitHub`, or the old GitHub authorization UI by name.
- **Recommended default:** remove unreachable old profile read/write/auth functions and their private helpers once current backend and supported updater/module calls are explicitly inventoried. Keep GitHub updater/module/helper paths that are still active.
- **Alternative:** retain them with a clear deprecated/unreachable marker and a source-level guard preventing UI wiring. Choose this if external callers may rely on the function names.

### 8. Keep intentional migration boundaries explicit (decision needed only if full release migration is desired)

- **Chosen approach:** leave launcher updates on the existing GitHub/Drive route and keep the graphics module's reviewed SHA pin until the backend release manifest is integrated end-to-end. Update docs so backend artifact endpoints are described as available but not the active updater.
- **Deferred alternative:** migrate updater and module delivery to backend releases, with paired launcher/module versions, client hash/size checks, rollback behavior, and staging rollout. Treat this as a separate release-channel project after publisher retry recovery is fixed.
- Preserve the documented history reset unless old GitHub graphics commits are a user requirement. If they are required, design an import mapping and display semantics before attempting import.

### 9. Implementation and verification order

1. Fix the two client P2 issues (queue lifecycle and CFG snapshot/fallback confirmation) without changing the backend API contract.
2. Choose and implement the restore revision policy before any restore procedure relies on it.
3. Make publishing idempotent and define incomplete-stage recovery.
4. Update the backend README and classify/remove dormant GitHub code after confirming call-site scope.
5. Decide whether backend publishing remains separate from the active updater and whether legacy history is intentionally unavailable.
6. After implementation is requested, run focused isolated failure/recovery checks first, then the relevant launcher/backend suites and a staging end-to-end flow. Keep live profile sync, publishing, restore, and user-machine setting changes out of verification unless separately authorized.

## Audit progress — 2026-11-09

### Baseline established

- Pre-backend source: `6c5caf9` (parent of `d77401b`).
- Initial backend migration: `d77401b`; nearby backend-preferred test branch tip: `41fbec7`; current launcher `main`: `d18420a`.
- Backend repository source checked: `adecb37` on `codex/cafelauncher-profile-viewer`, equal to fetched `origin/main`; local `main` is `7a56930` and four commits behind. The checked-out backend worktree is clean. The public status page reports deployed commit `adecb37a3e17`.
- The local backend SQLite database contains revision 1 for each of the six profiles. Against current checked-in files, all six graphics JSON and CFG files match exactly. Profile JSON differences are limited to intended CFG URL conversion to `/v1/cfg/...` and filling optional website/PTT defaults. This establishes local import parity only; it is not proof of the deployed database's state.
- Read-only deployment inspection on 2026-11-09: `/v1/health` returned healthy (`0.1.0`); the status page exposed deployed commit `adecb37a3e17`. All 18 live profile/graphics/CFG reads (six profiles × three resources) returned revision `1`, and their bytes/hashes matched mirror generation `2`. The live graphics and profile history endpoints each list only revision `1`; this is consistent with the documented fresh backend history and confirms no legacy GitHub history was imported. `/v1/releases/latest` returns `404` because no backend launcher release is published; current launcher update flow still uses GitHub/Drive.

### Source review findings

1. **P2 — manual retry loses ambiguous-write recovery state (confirmed by control flow).** The editor saves local values and unconditionally deletes the per-profile retry queue in `$saveEditorValues` before every Save & Sync click (`cafe.bat`, around lines 9285–9354), before the user confirms the sync. `Sync-ProfileToBackend` uses that queue to compare the exact attempted payload with a newer server revision after a timeout/failed read-back (`around 7877–7891`). Immediate retry therefore loses the accepted-payload evidence and gets a revision-conflict error; even answering **No** to the sync confirmation can delete that evidence. Existing `Test-BackendRetry.ps1` mocks the sync helper and does not exercise this UI/queue sequence.
2. **P2 — local CFG fallback lacks confirmation after a second fetch failure (confirmed by control flow).** `Get-ProfileCfgSource` performs another bundle read after the profile-level refresh. If both cloud sources fail at that point, it silently installs the cached CFG or a file beside the launcher (`around 3334–3353`). The action's confirmation was based on the earlier successful backend/mirror refresh and is not repeated. File-copy hash verification does not prove that fallback content is current.
3. **P2 candidate — primary backend revision downgrade is not detected.** `Get-CafeCloudSnapshot` checks a saved revision floor only on GitHub mirror fallback; a successful primary backend response bypasses the floor (`around 6872–6889`). The backend restore guide permits restoring an older SQLite snapshot, which can lower revisions. The client can then silently replace its remembered revision and apply older values. Confirm expected behavior for restores before treating this as a release blocker.
4. **Scope discrepancy — release API is not the active launcher updater.** Current client update checks/downloads still use `Cs-script` GitHub endpoints; Google Drive remains distribution and the backend's release manifest/assets are not wired into the launcher updater. The direct graphics-module source also remains GitHub. Current context documents this as intentional separation, so track as an explicit boundary rather than a defect unless the migration goal includes release delivery.
5. **P3 — backend release/tool publisher is not retry-safe after a completed publish with a lost response.** `publish.py` restarts the same versioned upload on retry. Release asset uploads are idempotent only before manifest publication; after publication the server returns `409 release_immutable` even for identical bytes, and a repeated manifest returns `409 release_immutable` too. Helper tool versions likewise return `409` whenever the version already exists. The CLI does not GET the existing version and compare its hashes before reporting success, so a timeout after the server commits can leave a valid immutable artifact while every same-version retry reports failure. No launcher release is currently published, so this affects future use of the backend publishing path rather than current client updates.
6. **No confirmed import/backup defect found in source review.** `import_repository.py` validates the six fixed profile/graphics/CFG inputs before `import_bundles` opens one `BEGIN IMMEDIATE` transaction, and refuses to mix imports into a non-empty revision database. `backup.py` uses SQLite's online backup API and copies release/helper directories; both deployment docs tell operators to pause publishing for a consistent DB/assets snapshot. This audit has not exercised disk-full, process-crash, or restore behavior, and the documented restore procedure can still roll profile revision numbers backward (see candidate above).
7. **Release asset storage has an unverified orphan recovery edge case.** Uploads are staged under the version directory before the DB transaction commits the release manifest. If the process or filesystem fails between asset replacement and DB commit, an unreferenced staged release file can remain; retrying the same bytes succeeds, while attempting different bytes for that version is rejected and needs operator cleanup. This is not observed in deployment; no live release is published.
8. **Mirror validation is fail-closed at the client boundary.** The launcher verifies manifest identity, fixed expected paths, SHA-256 for each mirror payload, and that profile/graphics/CFG revision headers agree on primary API reads. A changing raw-GitHub branch during sequential mirror fetches can cause hash mismatch and fallback failure, but cannot produce an accepted mixed bundle. This review found no confirmed mirror-integrity bypass.
9. **P3 — backend README migration roadmap is stale and contradicts the shipped client.** `CafeLauncherBackend/README.md` still says client mirror fallback/pending-write integration “have not been implemented,” and its “Before connecting CafeLauncher” checklist says to implement the adapter, token prompts, conflict handling, and then remove runtime GitHub calls. Current `ProjectCafe/cafe.bat` already reads/syncs through the backend, verifies a GitHub mirror fallback, and queues pending writes; the service is deployed. The README also says the mirror manifest supports a “future” fallback adapter. This can mislead future maintenance/release work about which safeguards exist and which GitHub calls intentionally remain (updater/module/helper paths). Update the backend README roadmap/status to describe the current split accurately.
10. **No additional route-contract mismatch found in this pass.** The launcher’s active backend endpoints map to implemented read, history, health, and sync routes. Reads are bounded and HTTPS-host constrained, primary resource revisions must agree, mirror bytes are checked against pinned paths and manifest hashes, and the Apply Graphics path passes its verified backend/mirror preset into the pinned module. The module's standalone GitHub graphics fetch is only used when invoked without an explicit preset; current launcher Apply Graphics supplies one.
11. **P3 maintenance risk — old GitHub profile read/write and authorization implementations remain in the launcher but have no current call sites.** `Refresh-ProfileFromGitHub`, `Sync-ProfileToGitHub`, `Get-GitHubSyncAuthorization`, and their commit-order/token helpers remain in `cafe.bat`; source search found no callers of the legacy refresh/sync entry points. Current profile operations call `Refresh-ProfileFromBackend` and `Sync-ProfileToBackend`. This did not appear to be an active behavior regression, but dormant write/auth code makes future tracing and security review harder and can be accidentally reconnected; remove or clearly mark it only after parity coverage confirms no supported external invocation depends on it.

### Not yet completed

- Complete endpoint-by-endpoint review, including request boundaries, import/backup/recovery, and remaining active vs dead GitHub call paths.
- Review the release/tool retry finding against its tests and define remaining manual UI/service checks. Existing publisher tests cover successful publication, immutable conflicts, artifact integrity, and latest-version ordering, but do not model a committed response being lost and then the publisher CLI retrying.
- Review all user-visible launch/apply/edit paths and validate the two confirmed UI defects with focused isolated reproduction if implementation verification is authorized; no such tests were run in this read-only audit.
- Inventory remaining GitHub calls by active call graph versus dormant legacy helpers, then compare against the release and deployment documentation before proposing cleanup.
- Complete endpoint-by-endpoint review, including request boundaries, import/backup/recovery, and remaining active vs dead GitHub call paths.

### Remediation implementation progress — 2026-11-09

The user selected the first six remediation items and chose to keep launcher updates on GitHub/Drive. Focused implementation is underway in the working trees; no commit, push, deployment, cleanup, live profile sync, or release publication has been performed.

1. **Ambiguous queued profile writes:** Save Locally and Save & Sync now resolve an existing durable backend queue before saving the editor's current values. The exact queued request remains available for retry or explicit discard. If resolution succeeds, the click is blocked and the UI says the current editor values were not saved; the user can review and save them in a separate click.
2. **Single verified profile/graphics/CFG snapshot:** Apply and Play + Exec pass the snapshot used for profile refresh into the graphics and CFG paths. CFG installation can consume the same verified in-memory content if cache writing fails. If no snapshot is available, a local CFG requires explicit confirmation showing its path and SHA-256; cancellation aborts installation.
3. **Primary backend rollback warning:** A primary snapshot below this PC's remembered revision prompts with default No. Choosing No cancels the read without falling through to a mirror retry. Explicit acceptance permits that intentional restore and the accepted revision becomes the new local baseline after import.
4. **Publisher retry recovery:** `publish.py` checks the exact published manifest/tool bytes before upload and after upload errors. Identical content/version is treated as success; mismatched immutable content still requires a new version. A public exact-version manifest read route was added for this check.
5. **Incomplete release staging:** Added read-only inspection and explicitly confirmed cleanup for one unpublished version. Cleanup rechecks the DB under `BEGIN IMMEDIATE`, verifies the staged inventory still matches what was shown, and removes only known asset/temp files.
6. **Documentation and release boundary:** Backend and launcher docs now describe current backend profile integration and intentional GitHub/Drive launcher distribution. The backend publisher remains separate from the active updater.

Static source review and focused verification completed. The launcher validation suite passed, including the added checks for queued-save gating, same-snapshot CFG use, primary rollback cancellation, and mirror freshness. The backend standard-library suite passed all 25 tests, including simulated lost upload responses, immutable-content conflicts, exact-version manifest reads, and staged-release inventory rechecks. `cafe.bat` remains CRLF. No live backend write, release publication, staged cleanup, deployment, or user-machine setting change was performed. The push to `main` is still pending; its configured workflows may publish the launcher to Drive and deploy the backend.
