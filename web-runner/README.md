# CafeLauncher Web Runner (development)

This is the local runner for the optional web-action flow. It targets Windows PowerShell 5.1 and .NET Framework already present on supported Windows café PCs; it adds no runtime package. It supports **Detect PC** and **Play + Exec**. Play + Exec uses the verified `cafe.bat` release and its existing profile, baseline CFG, profile CFG, and Steam launch logic. This source is not yet published, installed, or validated on a café PC.

## Build

From this directory, run:

```powershell
.\Build-WebRunner.ps1
```

The script uses the .NET Framework C# compiler and writes `build\CafeLauncherWebRunner.exe` by default. The executable is a per-user URI handler; after it is copied to its permanent café image path, run `CafeLauncherWebRunner.exe --register` once in the kiosk user's Windows session. Registration refuses to replace another handler; `--unregister` removes the key only when it still points to this executable. Do not register a copy in a temporary or Deep Freeze-reverted directory.

## Request safety

- Accepts exactly one URI matching `cafelauncher://v1/run/<43-character-base64url-id>`.
- The URI carries no action name, profile, command, path, or script.
- Claims through the HTTPS backend with a fresh random capability; an ambiguous claim retry reuses that capability.
- Downloads only the latest immutable launcher artifact from the pinned backend origin, validates the same-origin release path, size, SHA-256, and embedded release marker, then caches it by release version under the current user's LocalAppData.
- Runs the verified launcher's embedded PowerShell in a separate Windows PowerShell process with a fixed action context. No URI text is passed to PowerShell as a command or script argument.
- Keeps the result capability in process memory and uploads bounded structured events. No browser sync token is used.

## Current limits

- No protocol registration has been applied on this workstation or a café PC.
- The web-action API and launcher action-mode changes are local source changes. The backend is not configured or deployed for this API, and no compatible launcher release is published yet.
- Play + Exec requires an active Steam session, a uniquely detected CS2 CFG path, no unresolved local profile edits, and a current primary-backend profile/graphics/CFG history bundle. It fails closed on a backend rollback or unavailable snapshot and does not silently use mirror or local fallback data.
- CFG writes use the detected path pinned at the start of the action, revalidated immediately before each install. If a write or Steam launch may have happened but no complete result is available, the runner reports `INTERRUPTED`; the web page stays locked until the player confirms they checked the PC.
- Deep Freeze persistence, protocol activation, real Steam/CS2 discovery, and the web result round trip remain unverified on a café PC.
