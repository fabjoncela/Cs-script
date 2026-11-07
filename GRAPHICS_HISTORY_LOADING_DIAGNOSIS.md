# Graphics history loading diagnosis

## What the user's log showed

The launcher completed startup and opened the Provmode editor. Loading that profile's graphics history then produced an HTTP 404, followed by two separate UI errors:

- The error handler could not set the status label's `Text` property.
- Completion cleanup could not re-enable the Load button's `Enabled` property.

The second and third messages were launcher defects. They hid the original network result and left the history UI in a bad state.

## Request-to-UI flow

1. **Load history click.** The editor checks the per-profile 24-hour cache. If it has no fresh entry, it builds a GitHub commits URL for `graphics/<ProfileName>.json` on the configured branch, disables the history controls, and displays a loading message.
2. **Background request.** `CafeGraphicsHistoryBackgroundWorker` sends the HTTP GET. It records response text on success and the exception plus HTTP status on failure.
3. **Completion callback.** `RunWorkerCompleted` converts successful commit JSON into the three revisions before the current file and updates the controls. On failure it reports the error and restores the controls.
4. **History selection.** Selecting a revision fetches that graphics JSON at its commit SHA, validates the preset, and stages it into the editor. It does not save or apply the preset.

## Root cause

The completion callback was registered inside the Load button handler, which is itself a PowerShell `GetNewClosure()` event handler. Its nested closure tried to update WinForms controls using values captured from the outer closure. Replacing the state object's control properties with direct variables did not fix that nested capture: the user's release 2026.11.07.15 still logged missing `Text` and `Enabled` properties.

This strongly indicates the callback was not reliably holding the original Label and Button instances. The GitHub 404 was the triggering error; the nested callback's UI references caused the follow-on failures.

## Fix

- Attach a hashtable containing the profile name, dialog, history controls, and per-editor state to the worker instance's `RequestContext` property before starting the request.
- Read that exact object from the worker instance's `RequestContext` property. The completion handler no longer captures UI controls from a nested PowerShell closure.
- Route success, empty-history, HTTP 404, and other failure states through `Set-CafeGraphicsHistoryUi`, which validates the expected WinForms control types and restores the Load/Refresh button.
- Log the actual request URI and HTTP status on failures. A 404 for a profile's history path is presented as no earlier versions, while other failures remain visible and retryable.
- Keep the same handler and behavior for every profile. No local or GitHub history is deleted.

## Prevention and regression checks

Keep these rules when editing this flow:

1. Treat the HTTP result and UI result separately. A GitHub 404 is a normal “no history at this path” result; it must not prevent completion cleanup or turn a valid WinForms control into a string/null reference.
2. Do not add another nested `.GetNewClosure()` callback that directly references `$dialog`, `$status`, `$loadHistory`, `$historyChoice`, or `$restoreHistory`. Put the owning controls and profile in `RequestContext` before `RunWorkerAsync`, and read them from `$sender.RequestContext` in the completion callback.
3. Route success, empty history, 404, and retryable failures through `Set-CafeGraphicsHistoryUi`. Its error path must always re-enable Load/Refresh, and the completion `finally` path must restore the cursor and dispose the worker even when the editor has closed.
4. Keep a request URL and HTTP status in failure logs. That distinguishes a wrong/missing GitHub path from a failure while updating the UI.

Run these focused Windows PowerShell 5.1 checks after changing the history flow:

- `tools/Test-GraphicsHistory.ps1` for commit parsing, caching, and restore behavior.
- `tools/Test-GraphicsHistoryAsync.ps1` for background-thread execution, request-context retention, and request diagnostics.
- `tools/Test-GraphicsHistoryUI.ps1` for callback wiring plus WinForms success, empty-history/404, error, retry, and control-recovery states. This is standalone so unrelated dashboard tests cannot hide a history regression.

The full `Test-CafeLauncher.ps1` script also exercises the dashboard. If it stops at an unrelated dashboard assertion, report that separately; do not remove or weaken the graphics-history checks to make the broader script appear green.

## Provmode history check

The `main` branch currently has `graphics/Provmode.json`, and GitHub's commits API returned its creation commit, `5f782626d0b5f13d9bbdeb0acdd76f5d00f0d83a` (`Add Provmode profile`). The history reader omits the newest commit because it represents the current preset; with only that one commit, there are no older Provmode versions to restore. During this investigation the same public request returned HTTP 200 with that single commit. The 404 from the user's log therefore was not reproduced by the current request from this machine; the new failure log includes the actual URL so a future discrepancy can be identified.

## Verification

All focused Windows PowerShell 5.1 checks passed on launcher release `2026.11.07.16`: history parsing/cache (`Test-GraphicsHistory.ps1`), worker-thread/request-context behavior (`Test-GraphicsHistoryAsync.ps1`), callback wiring and WinForms recovery states (`Test-GraphicsHistoryUI.ps1`), the full launcher regression suite (`Test-CafeLauncher.ps1`), and context freshness (`Test-ContextFreshness.ps1`). The standalone UI test remains useful because it isolates this flow from unrelated dashboard changes.
