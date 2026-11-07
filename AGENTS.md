# CafeLauncher repository instructions

Before making repository changes, read [`context.md`](./context.md) and inspect `git status --short --branch`, `git branch -vv`, and the relevant diff. `context.md` describes the current checkout's architecture and branch-aware rules; it does not claim that testing-branch changes are in production `main`.

Preserve unrelated user files and edits. Do not use destructive Git cleanup/reset commands. Keep `cafe.bat` in Windows CRLF format. When changing `graphics/ApplyGraphics.ps1`, update its pinned Git blob SHA in `cafe.bat` and bump `CAFE_RELEASE`.

Before commits, merges, or pushes, the configured `.githooks` refreshes/checks the generated release metadata in `context.md`. If a hook refreshes it, review and commit the context change, then retry. New clones should run `tools/Install-GitHooks.ps1`. CI also checks context freshness. On `main`, GitHub Actions automatically bumps `CAFE_RELEASE` when a `cafe.bat` change arrives without a version bump, then validates and commits the generated release metadata. When changing `graphics/ApplyGraphics.ps1`, update its pinned Git blob SHA in `cafe.bat`; the same release workflow handles the version bump if needed.

Do not push, merge, or change remote profile data unless the user requested it. Update `context.md` when implementation architecture, UI behavior, persistence, safety boundaries, or verification workflows change. Keep repository workflow rules here and current implementation details in `context.md`.

## Asynchronous graphics history UI

The profile editor's GitHub graphics-history request completes asynchronously. Do not let its `RunWorkerCompleted` callback depend on PowerShell local variables captured through nested event-handler closures. Put the profile, dialog, controls, and per-editor state in the worker's `RequestContext` before starting it, and have the callback read that context from its sender. Keep all result/error UI updates in `Set-CafeGraphicsHistoryUi`; an HTTP 404 for the history path means no prior versions are available, while other errors should remain visible and retryable. When changing this flow, run `tools/Test-GraphicsHistory.ps1`, `tools/Test-GraphicsHistoryAsync.ps1`, and `tools/Test-GraphicsHistoryUI.ps1`. See [`GRAPHICS_HISTORY_LOADING_DIAGNOSIS.md`](./GRAPHICS_HISTORY_LOADING_DIAGNOSIS.md) for the symptom, root cause, and request flow.
