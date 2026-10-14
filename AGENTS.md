# CafeLauncher repository instructions

Before making repository changes, read [`context.md`](./context.md) and inspect `git status --short --branch`, `git branch -vv`, and the relevant diff. `context.md` describes the current checkout's architecture and branch-aware rules; it does not claim that testing-branch changes are in production `main`.

Preserve unrelated user files and edits. Do not use destructive Git cleanup/reset commands. Keep `cafe.bat` in Windows CRLF format. When changing `graphics/ApplyGraphics.ps1`, update its pinned Git blob SHA in `cafe.bat` and bump `CAFE_RELEASE`.

Before commits, merges, or pushes, the configured `.githooks` refreshes/checks the generated release metadata in `context.md`. If a hook refreshes it, review and commit the context change, then retry. New clones should run `tools/Install-GitHooks.ps1`. CI also checks context freshness.
