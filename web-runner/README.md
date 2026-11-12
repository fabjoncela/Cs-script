# CafeLauncher Web Runner (development)

This is the local runner for the optional web-action flow. It targets Windows PowerShell 5.1 and .NET Framework already present on supported Windows café PCs; it adds no runtime package. It supports **Detect PC** and **Play + Exec**. Play + Exec uses the verified `cafe.bat` release and its existing profile, baseline CFG, profile CFG, and Steam launch logic. Runner v0.2.0 and its first-run installer are published; the compatibility fallback described below is a local v0.3.0 change and is not published or café-validated yet.

## Build

From this directory, run:

```powershell
.\Build-WebRunner.ps1
```

The script uses the .NET Framework C# compiler and writes `build\CafeLauncherWebRunner.exe` by default. The website download link points to the latest GitHub Release asset. The player must open the downloaded executable once: it copies itself to `%LOCALAPPDATA%\CafeLauncher\Runner\CafeLauncherWebRunner.exe`, verifies the copied bytes, and registers `cafelauncher://` for that Windows account. This needs no admin rights. Reopening the same installer is safe and updates the installed copy when the bytes differ. If a different protocol handler is already registered, setup stops instead of replacing it. `--register` and `--unregister` remain available for staff provisioning; unregister removes the key only when it still points to this executable.

The app cannot be installed silently by a browser. On a PC where user files survive reboot, the download-and-open step is a one-time setup for that Windows account. If Deep Freeze or another reset discards LocalAppData or the registry at reboot, café staff must install/register it in the saved base image or reprovision it during maintenance. The website calls this out; a player download cannot make a reset-protected installation persistent.

## Request safety

- Accepts exactly one URI matching `cafelauncher://v1/run/<43-character-base64url-id>`.
- The URI carries no action name, profile, command, path, or script.
- Claims through the HTTPS backend with a fresh random capability; an ambiguous claim retry reuses that capability.
- Downloads only the latest immutable launcher artifact from the pinned backend origin, validates the same-origin release path, size, SHA-256, and embedded release marker, then caches it by release version under the current user's LocalAppData.
- If that backend artifact predates the requested web action, fetches the current `cafe.bat` from the fixed Cs-script GitHub Contents API endpoint, verifies the reported size and Git blob SHA-1, checks the release marker and action entry point, then caches it under a SHA-addressed LocalAppData folder. This avoids opening the old dashboard/updater just to upgrade to web-action support.
- Runs the verified launcher's embedded PowerShell in a separate Windows PowerShell process with a fixed action context. No URI text is passed to PowerShell as a command or script argument.
- Keeps the result capability in process memory and uploads bounded structured events. No browser sync token is used.

## Current limits

- The protocol is registered for the current Windows account on this workstation. Its reboot and Deep Freeze persistence have not been tested on a café PC.
- The runner's first-run self-install copies it under the current account's LocalAppData and registers the protocol. `tools/Test-WebRunnerInstall.ps1` exercises initial copy, same-version no-op, and replacement using temporary test files only.
- `tools/Test-WebRunnerCompatibility.ps1` checks GitHub blob verification, requested-action support detection, and tampered-payload rejection using synthetic data only.
- The backend web-action API is deployed and configured. Its latest immutable launcher artifact is currently `2026.11.08.4`, which predates web-action support; runner v0.3.0's GitHub-verified fallback is local and must be published before retrying the browser action.
- Play + Exec requires an active Steam session, a uniquely detected CS2 CFG path, no unresolved local profile edits, and a current primary-backend profile/graphics/CFG history bundle. It fails closed on a backend rollback or unavailable snapshot and does not silently use mirror or local fallback data.
- CFG writes use the detected path pinned at the start of the action, revalidated immediately before each install. If a write or Steam launch may have happened but no complete result is available, the runner reports `INTERRUPTED`; the web page stays locked until the player confirms they checked the PC.
- Deep Freeze persistence, protocol activation, real Steam/CS2 discovery, and the web result round trip remain unverified on a café PC.
