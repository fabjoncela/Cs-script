# Backend API with GitHub fallback

Status: design agreed; client implementation is in progress in the local checkout. Backend and mirror reads plus pending backend writes are coded and have partial Linux PowerShell 7 read-only smoke checks. Windows PowerShell 5.1, WinForms, queue, conflict, and migration validation remain before any release. The current published launcher remains unchanged.

## Source priority

The updated CafeLauncher has one cloud behavior, without a data-source switch:

- Read profile, graphics, CFG, and graphics history from `https://fabjon-hp.tail681ec9.ts.net:10000/v1/` first.
- If a read fails, read the last complete public snapshot from `fabjoncela/cafelauncher-backend-mirror` after checking the manifest's hashes.
- Write profile, graphics, and CFG changes only to the backend. The backend mirrors accepted changes to GitHub.

Do not persist a sync token or GitHub credential. During migration from the existing launcher, preserve any locally pending GitHub edits and require an explicit safe resolution before treating them as backend edits. Do not silently discard or redirect them.

## Pending writes

1. Save Locally writes the edited profile, graphics preset, and CFG draft to the existing atomic local profile file and marks the profile pending before attempting a network write.
2. Save & Sync sends one complete bundle to `PUT /v1/profiles/{name}/sync`, with the expected backend revision and a one-time bearer token. A successful response is not enough by itself: read back the backend revision and compare the profile, graphics, and CFG values or hashes before clearing pending state.
3. A network error, server error, authentication failure, conflict, or read-back mismatch leaves the local edits pending. Show **Waiting to sync** with the reason and a retry action; do not claim the cloud accepted them.
4. While the launcher remains open, retry when connectivity returns using only a token still held in memory. After restart, keep the pending edit on disk and request fresh authorization before retry. Never store the token in the queue, logs, or profile JSON.
5. The backend mirror worker publishes accepted backend generations to GitHub. The launcher never writes directly to the fallback mirror. During a backend outage, fallback reads show the last mirrored snapshot and must not overwrite pending local edits.

## Read and conflict rules

- Validate backend responses and mirrored JSON/CFG with the launcher's existing profile, graphics, and CFG validators. Verify mirrored bytes against manifest SHA-256 and use one manifest generation for each profile/graphics/CFG read set.
- A backend conflict (HTTP 409) keeps the local edit and shows a clear choice to review the current backend version, retry a deliberate merge, or cancel. Do not overwrite automatically.
- If both backend and mirror are unavailable, preserve the existing local fallback and confirmation behavior. Never silently treat stale cached data as current cloud data.
- The launcher updater and separate Logitech helper remain on their current GitHub paths until matching release artifacts and client update behavior are verified separately.

## Implementation sequence

1. Inventory the current profile, graphics, CFG, history, and save call sites; preserve any pending edits from the prior GitHub-based launcher during migration.
2. Add a single backend/mirror read adapter and test malformed responses, hash mismatches, partial snapshots, and outages.
3. Add backend sync with persisted pending revision/bundle state, read-back verification, and safe retry after one-time authorization.
4. Route editor, Apply, Play + Exec, graphics history, and dashboard status through the backend-first adapter. Remove GitHub write authorization from the new save flow.
5. Run the existing Windows PowerShell 5.1 focused tests plus new transport, pending-write, conflict, and migration cases; perform a real Windows UI smoke test before releasing the updated launcher to a café PC.

No backend server, Cloudflare, Tailscale, Docker, or remote profile data change is required for this client work.
