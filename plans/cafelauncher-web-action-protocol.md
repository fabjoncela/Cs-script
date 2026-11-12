# CafeLauncher Web Action Protocol

## Status

Design and local implementation draft, 2026-11-12. The sibling backend checkout has untested, uncommitted request/session/claim/result endpoints and a first web app shell. A local .NET Framework runner now claims requests, verifies/caches an immutable launcher artifact, and dispatches Detect PC and Play + Exec through structured launcher action modes. Play + Exec has not been run end to end. Nothing is deployed or registered on a café PC. The backend has no player-account authentication. The selected UX is explicit in-page confirmation before creating each state-changing action request, with Windows/UAC/device prompts only where an existing safeguard requires them. If the café requires identity stronger than the local browser session and active Steam state, add authenticated player identity and stronger PC/browser pairing before exposing state-changing actions.

## Trust boundaries

- The web page is untrusted input to the local runner, even when served by the CafeLauncher origin.
- The URI is untrusted input. It may be forged, replayed, truncated, or supplied by another website.
- The runner executes as the Windows user who owns the browser session. This establishes the OS session, not by itself the identity of the player signed into Steam. The runner reports only whether a Steam session is active; any action requiring a particular active-account identity must check it locally at its action boundary.
- The backend is authoritative for short-lived action tickets and action results. The profile mirror is not used for tickets, claims, or results.
- No bearer sync/publish token is sent to the browser or runner. Existing profile reads remain public; profile writes continue to require the existing protected sync flow and are excluded from the first web-action pilot.
- Windows confirmations, UAC, hardware capability checks, active-Steam-account checks, CS2 state checks, and filesystem safeguards remain authoritative.

## Request lifecycle

`REQUESTED -> CLAIMED -> RUNNING -> AWAITING_LOCAL_INPUT -> RUNNING -> COMPLETED | PARTIAL | SKIPPED | FAILED | CANCELED | EXPIRED | INTERRUPTED`

`AWAITING_LOCAL_INPUT` may be entered repeatedly for a running action. It is informational: the runner owns execution and must show the required native confirmation/dialog on the PC. A browser close or polling timeout does not imply that an action failed or was canceled.

Each ticket has a cryptographically random 256-bit identifier, a short expiry (90 seconds from creation), and exactly one successful claim. A claimed action has a bounded 10-minute result-upload window. The ID itself is a one-use capability because it appears in the URI; it is never written to logs. Ticket IDs are stored hashed at rest. A ticket is scoped to one allowlisted action and one allowlisted profile. The runner atomically claims before reading/acting; duplicate claim returns the existing state without rerunning the action. The webpage must display the exact action/profile and require explicit confirmation before requesting a ticket for a state-changing action.

## Proposed HTTP contract

All endpoints are same-origin under the backend's HTTPS host. The browser uses an `HttpOnly`, `Secure`, `SameSite=Strict` anonymous web session cookie and a CSRF token for ticket creation. The service rejects missing/wrong `Origin`, wrong `Sec-Fetch-Site`, invalid CSRF token, oversized JSON, unknown fields, and unsupported actions. Do not enable permissive CORS.

### Create request

`POST /v1/actions`

Request:

```json
{
  "action": "detect-pc",
  "profile": null,
  "clientRequestId": "<43-character-base64url-id>"
}
```

For profile actions, `profile` is one of the registered names. The server validates action/profile pairing against a fixed allowlist. The ticket stores the exact profile and action; the runner cannot replace either from URI input.

Response (`201`; an idempotent retry returns the original request with `200`):

```json
{
  "requestId": "256-bit-random-base64url",
  "action": "detect-pc",
  "profile": null,
  "expiresUtc": "2026-11-12T12:00:00Z",
  "state": "REQUESTED"
}
```

Same browser session plus the same `clientRequestId` returns the existing ticket during its lifetime; it never creates a second execution for a retry. The page invokes `cafelauncher://v1/run/<requestId>` directly from the user's click handler. No action parameters or arbitrary data appear in the URI.

If the POST response is ambiguous because the connection drops, the page retries with the exact same client request ID. The request ID is persisted in session storage while the request is unresolved, so a page reload can resume status tracking. A permanent authorization/session error stops retries; the page does not create a replacement ticket automatically.

### Claim request

`POST /v1/actions/{requestId}/claim`

Runner request:

```json
{
  "runnerVersion": "2026.11.12.1",
  "protocolVersion": 1,
  "machineInstanceId": "random-install-scoped-id"
}
```

The ticket ID is the sole bootstrap capability. The runner validates URI syntax and length before any network call, generates and retains a random claim capability, claims over HTTPS, rejects expired/claimed/canceled tickets, and verifies the returned action/profile/expiry against its compiled allowlist. The same capability makes claim retries idempotent if the first response was lost. It shows a visible local status for the action/profile. It does not add a second consent click for a supported action after the webpage confirmation; existing Windows/UAC/device prompts remain in force. Detect PC is read-only and never accepts caller-supplied paths or commands.

Successful claim returns the immutable ticket, request expiry, and upload expiry. The runner's one-use claim capability is also the result-upload capability; only its hash is stored, it expires with a bounded grace period, and the runner holds it in memory only. It is not a general API token and cannot read profiles, write profile data, or publish releases.

Claim request body:

```json
{
  "runnerVersion": "2026.11.12.1",
  "protocolVersion": 1,
  "claimCapability": "runner-generated-256-bit-base64url-value"
}
```

### Progress/result

`POST /v1/actions/{requestId}/events` accepts only bounded structured events and the result-upload capability. Event states are `RUNNING`, `AWAITING_LOCAL_INPUT`, or one terminal result (`COMPLETED`, `PARTIAL`, `SKIPPED`, `FAILED`, `CANCELED`, `INTERRUPTED`). For Play + Exec, `executionOutcomeKnown` must be false exactly when the runner reports `INTERRUPTED`; other terminal results must state that the local outcome is known. Step status is limited to the existing CafeLauncher vocabulary plus `RUNNING`: `SUCCESS`, `PARTIAL`, `SKIPPED`, `FAILED`, `PENDING`, `RUNNING`.

Example terminal event:

```json
{
  "eventId": "b75ec26a-1e8d-4c05-9b9d-40c1d4e739f4",
  "state": "PARTIAL",
  "result": {
    "summary": "Steam was detected; no unique CS2 install was found.",
    "steps": [
      {"name": "Steam discovery", "status": "SUCCESS", "detail": "Steam detected."},
      {"name": "CS2 path discovery", "status": "SKIPPED", "detail": "No validated CS2 install was found."}
    ],
    "data": {
      "steam": {"status": "DETECTED", "executable": "C:\\Program Files (x86)\\Steam\\steam.exe", "libraries": [], "activeSessionPresent": true},
      "cs2": {"status": "NOT_UNIQUELY_DETECTED", "installPath": null, "configPath": null}
    }
  }
}
```

Result payloads have strict size and field limits. Do not upload full logs, CFG contents, tokens, Steam account IDs, arbitrary paths, or hardware serials. Paths may be returned only where needed for the requested detection/action and should be redacted from routine logs. The server accepts one terminal result; identical retries are idempotent, while a conflicting second terminal result is rejected and audited.

### Page status

`GET /v1/actions/{requestId}` requires the same browser session that created the ticket. The page polls with bounded backoff (e.g. 500 ms up to 3 seconds) until a terminal state. It renders event details as text, never HTML. Unknown/expired requests return a clear terminal state. If a claimed action has no final event before the result-upload deadline, the page sees `INTERRUPTED`; it must not automatically relaunch it. Polling does not extend ticket expiry.

## Runner requirements

- The protocol handler must use a fixed executable path and safe Windows command-line quoting. The handler validates a single URI and does not invoke `cmd.exe`, PowerShell text evaluation, or file associations using supplied arguments.
- The runner checks an immutable release manifest and downloaded asset sizes/SHA-256 itself before executing the launcher or helper. TLS and server-side stored-hash checks are additional safeguards, not a substitute for client verification.
- The runner claims before acting and never executes a ticket twice. A crash after claim is reported as interrupted/unknown; it is not automatically retried as a new ticket.
- The runner uses the current Windows session and independently rediscovers Steam/CS2 paths and active account at the action boundary. It does not trust web-submitted paths.
- Existing Detect PC inventory now has an additive `Get-PCDiagnostics -AsObject` mode that performs only local Steam/CS2 path and active-session detection (no UI, hardware scan, or installed-app scan). It returns schema version 1 with Steam executable/libraries, CS2 install/config paths, and only a boolean active-session indicator. It intentionally omits the Steam account ID. The dashboard's current no-argument call continues to return its text report.
- The runner preserves `cafe.bat` double-click startup and supports the same interactive prompts, UAC boundaries, and recovery behavior as the existing dashboard.
- Result upload retries reuse the same request and event IDs. Results contain no secrets and are safely bounded.
- The page offers a direct protocol link if automatic activation is blocked by the browser. If request state becomes unavailable, it keeps other action buttons disabled and requires the player to confirm they checked this PC before allowing another action.

## Initial action capability matrix

| Action | Initial disposition | Local interaction / guards | Result data |
| --- | --- | --- | --- |
| Detect PC | Pilot first; read-only | Reuse the existing diagnostics inventory; no path is accepted from the page | Steam executable/libraries and validated CS2 config/install paths; component-level detected/unavailable states |
| Play + Exec | Pilot after Detect PC | Explicit web confirmation; skip if local profile edits need review; require active Steam and one unique CS2 config path; fetch the current profile revision then its immutable profile/graphics/CFG history bundle from the primary backend; block rollback pending Windows review; recheck Steam session and pin/revalidate the CFG path before writes; install reset baseline then selected profile CFG; do not relaunch CS2 if already running | CFG install and Steam launch state; if CS2 is already running, exact console commands as text; skipped/partial/failure details; uncertain local outcome is `INTERRUPTED` and requires checking the PC before retry |
| Apply Graphics | Later pilot | Require CS2 closed; verified preset/module; preserve module hash pin or version-matched release hash; supported-operation checks and current account/path revalidation | Per-setting applied/skipped/unverified/failed result |
| Apply profile | Later | Web confirmation; may change Windows mouse, display, NVIDIA and device state; keep capability scans, per-setting verification, and any existing UAC prompts | Existing per-step and per-setting outcome records |
| Capture CS2 | Later | Opens review/editor UI and stages pending data; web cannot claim cloud save unless the user separately invokes authorized Save & Sync | Capture summary and staged/pending state, without CFG body or private identifiers |
| Workshop Cleanup | Excluded from unattended web mode | Must keep the native preview, exact-item confirmation, active-account/subscription recheck, CS2-closed check, path containment, and backup safeguards | Candidate count/size and removed/failed counts; avoid publishing item details unless needed |
| Profile editing/sync | Excluded from initial action API | Existing backend token/revision/pending-queue workflow stays in the launcher; never expose sync token to web runner | No web result in initial scope |

## Threat and failure cases to handle

- Forged or malformed URI; unknown protocol/action version; shell metacharacters; oversized arguments.
- Another origin attempts to create a ticket or launch a request; enforce same-origin/session protections and ensure the runner accepts only a valid one-use ticket.
- Expired/replayed ticket; duplicate click; simultaneous tabs; runner already busy.
- Runner or PC crashes after claim; browser closes; progress or terminal result upload fails.
- Backend/API unavailable while the mirror remains available; mirror data must never substitute for an action ticket or release authorization.
- Profile revision changes between page selection and action claim; runner must fetch one fresh coherent bundle and surface any stale or unavailable source according to existing launcher policy.
- Fetch the current profile revision first and then retrieve the complete `/v1/profiles/{name}/history/{revision}` snapshot. Do not combine independent latest profile, graphics, and CFG responses. If a coherent verified bundle cannot be obtained, stop before writing files or launching Steam.
- Wrong Windows session, Steam account, or CS2 library; runner rediscovers and validates locally.
- Hash mismatch, incomplete artifact publication, CDN/proxy cache issue, TLS failure, or release rollback.

## Decisions still requiring live evidence

- Actual Funnel forwarding and service route behavior: on 2026-11-12 the public HTTPS health endpoint and root status page responded, `/viewer` responded, and `/status` returned 404. `tailscale funnel status` on the workstation reported `No serve config`; this does not identify the server-side Funnel configuration. Inspect the Ubuntu host before routing changes.
- The rollout default is the existing kiosk Windows account: players open the website on that café PC, the per-user protocol handler runs as that account, and the runner checks the active Steam session locally. Install the runner at a stable path such as `C:\Program Files\CafeLauncher\Runner` with read/execute access for the kiosk account. Include files and HKCU handler in the Deep Freeze base image; if provisioning happens after freeze, apply it through the café maintenance/thawed cycle or an idempotent login provisioning step. This still needs a real café reboot/restore smoke test.
- If the café needs player identity beyond the local browser session and active Steam account, add authenticated player identity and stronger PC/browser pairing before exposing state-changing actions.
