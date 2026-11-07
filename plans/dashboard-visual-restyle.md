# CafeLauncher Dashboard Visual Restyle Plan

**Status:** Implemented locally; screenshot-based visual review remains pending  
**Scope:** Visual restyle of the existing dashboard only. Preserve its layout, control order, labels, and actions.

## Goal

Bring the CafeLauncher dashboard closer to the modern concept shown in the design discussion: minimal dark surfaces, restrained cyan emphasis, less profile-specific color, and consistent rounded corners. Keep the dashboard recognizable and keep menus, controls, and profile actions in their current positions.

## Source of truth and implementation

- The launcher UI is PowerShell WinForms embedded in `cafe.bat`; there is no separate XAML or web frontend.
- The dashboard layout is constructed in the `$form`, `$root`, `$tabs`, `$dashGrid`, `$profilesGrid`, and `$rightGrid` section.
- Profile action rows are created by `New-Tile` and paged by `Set-ProfileDashboardPage`.
- Shared labels and buttons use `New-CafeLabel` and `Style-CafeButton`.
- The form currently uses a 1080×825 client size, a 960×780 minimum size, font-based WinForms autoscaling, and a 57/43 dashboard split.

Before implementation, re-read `context.md`, check `git status --short --branch`, `git branch -vv`, and inspect the relevant diff. At plan capture time, `cafe.bat` already had uncommitted graphics-history UI edits. Recheck and preserve any current user changes; do not assume that old diff is still present or safe to overwrite.

## Layout invariants

Keep the current information architecture and positions:

1. Header title, subtitle, version, and GitHub status.
2. Dashboard and Tools & Apps tabs.
3. Dashboard profile area on the left and selected-profile details on the right.
4. Five visible profile rows per page, with the same action order: Apply, Game Graphics, Play + Settings, Edit, Capture CS2.
5. Previous / page count / Next pager below the profile rows.
6. Log status and log controls at the bottom, followed by the existing footer.

Keep the existing grid and anchoring. Make sizing and spacing adjustments only inside the existing regions; do not move or reorder menus, rows, or actions. Preserve the profile selection, paging, hover, and click behavior.

## Visual direction

Use a compact token set rather than per-control colors:

- **Base:** deep graphite/navy background.
- **Surfaces:** subtly lighter panel and row surfaces with thin low-contrast borders.
- **Text:** high-contrast soft white for primary text and cool gray for secondary text.
- **Accent:** one restrained cyan/ice-blue for primary Apply actions, selected states, and small focus details.
- **Profiles:** neutral row surfaces with, at most, a muted profile accent. Remove the bright rainbow row fills.
- **Actions:** consistent secondary button treatment; differentiate actions mainly through hierarchy and hover/focus states, not unrelated bright colors.
- **Shape:** consistent modest corner radii (roughly 6–10 px) for buttons, profile rows, detail surfaces, and log panel.
- **Typography:** retain a readable Segoe UI family; refine size, weight, and hierarchy without causing label wrapping or clipping.

Avoid adding new controls or decorative content as part of this pass. Do not copy generated mockup text or icons if they do not match the actual app.

## Implementation approach

1. Capture a baseline screenshot of the current app at its current client size and Windows display scaling. Record the scaling factor so later comparisons use the same conditions.
2. Define named colors, border, radius, typography, and spacing values near the existing shared style helpers.
3. Restyle the shared button helper for consistent typography, fill, border, and interaction feedback. Keep each button's existing event handler and enabled state.
4. Replace the bright per-profile row color treatment with a neutral surface and restrained accent treatment. Restyle the existing row hover timer so it gives subtle feedback instead of changing the entire row to near-white.
5. Apply the same visual rules to the selected-profile details, pager, tabs, log controls, and status panel while keeping them in their existing layout slots.
6. If standard WinForms controls cannot render the target rounded corners cleanly, add a small reusable owner-drawn control/style for the affected surfaces. Preserve keyboard focus indication, disabled appearance, click hit areas, and high-DPI scaling. Prefer a small, centralized implementation over one-off drawing logic scattered through the dashboard.
7. Iterate against screenshots at the baseline size. Compare fixed anchors, text baselines, margins, control bounds, colors, border thickness, and corner radii. Make corrections until the rendered result matches the chosen concept closely without clipping or shifting the layout.
8. Review the final diff to ensure it contains only the intended dashboard appearance changes and does not alter profile actions, persistence, API calls, release workflow, or graphics behavior.

## Verification checklist

- All five profile rows and all five actions remain in the original order and locations.
- Both dashboard pages work; Previous / Next enabled states and page text remain correct.
- Selected-profile details still update when a profile action is clicked.
- Buttons remain clickable and retain their existing behavior, including disabled controls.
- Hover and keyboard focus are visible but restrained; disabled controls remain distinguishable.
- Tabs, logs, Hide/Show Logs, Clear Logs, Send Logs, and footer remain legible and usable.
- No text is clipped or unexpectedly wrapped at the standard client size or minimum window size.
- Check the dashboard at the normal Windows scaling and a higher scaling factor for layout/autoscale regressions.
- Run the repository's relevant syntax and focused validation checks after implementation; do not treat a successful parse alone as visual verification.

## Reference

The generated dashboard concept is in the Codex conversation that established this plan. Treat it as a styling reference; the live app's labels, layout, and behavior remain authoritative.

## Implementation record

- The dashboard uses a unified graphite/navy palette, restrained cyan primary actions, neutral profile rows, rounded buttons and summary/log surfaces, and owner-drawn dark tabs. The existing grids and action handlers remain in place.
- `CAFE_RELEASE` is `2026.11.07.16`; the restyle is committed and pushed to `origin/main`.
- `Test-CafeLauncher.ps1` checks that the owner-drawn tab handler uses `RectangleF` bounds with `DrawString`, covering the overload regression without relying on platform-specific WinForms painting. `Test-StartupApiTimings.ps1` and `Test-ContextFreshness.ps1` also pass.
- The desktop capture tool could not target the launcher window, so compare a live screenshot at the reference size and DPI before calling the visual match pixel perfect.
