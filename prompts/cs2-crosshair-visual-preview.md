# Implementation prompt: CS2 crosshair visual preview

This document records the implementation requirements and acceptance criteria for CafeLauncher's CS2 crosshair visual preview. Use this prompt when reviewing or changing that behavior.

## Repository workflow

- Read `AGENTS.md` and `context.md` first. Inspect `git status --short --branch`, `git branch -vv`, and the relevant diff before editing. Follow the checked-out source tree and preserve unrelated changes.
- Keep the change focused on the preview. Do not push, merge, change remote profile data, or bump the launcher release solely for this feature unless separately requested.
- Keep rendering local to CafeLauncher and do not bundle screenshots or map images. For Static Quadrant geometry, follow the MIT-licensed `setposgg/cs2-crosshair` implementation and retain its attribution in `THIRD_PARTY_NOTICES.md`. For native pixel coverage and color blending, use an independent local implementation informed by the public crosshair.club shader reconstruction.

## Existing behavior to preserve

- `ConvertFrom-CafeCS2CrosshairShareCode` decodes supported share codes and returns decoded convars and conversion warnings.
- The existing **Preview & Import** handler decodes the pasted value, shows a text confirmation, and stages settings for the selected profile only after confirmation.
- Import stages values; it does not edit CS2 files, save locally, or sync to GitHub. Save and sync remain separate actions.
- Keep existing current and legacy format support, checksum validation, warning text, scope-dot handling, and sensitivity preservation intact.

## Intended implementation

1. Reuse the decoder's returned values. Do not parse the share code again for rendering.
2. Convert decoded values into a small validated preview model. Parse numeric values with invariant culture, check supported ranges, and represent missing or unsupported fields explicitly rather than inventing values.
3. Replace or extend the text-only confirmation with a WinForms dialog containing:
   - A preview panel rendered from the validated preview model.
   - A few locally drawn backgrounds (stone, dark, light, and foliage-like) so the user can judge contrast. Do not bundle external map screenshots or add network requests.
   - Optional dragging of the crosshair within the preview to inspect contrast on different parts of the sample background, plus a clear way to recenter it. Dragging is only for visual inspection; import values must not change.
   - The existing settings summary and conversion warnings.
   - **Import** and **Cancel** actions.
4. Draw through the WinForms panel's `Paint` event with .NET `System.Drawing`. Select geometry by decoded style. Static Quadrant uses four short diagonal ring arcs whose outer radius is `max(1, gap) + thickness`, an angular span of `ratio × 90°`, a one-pixel outline, and a square center dot when enabled. Its length setting does not affect the arc geometry. Rasterize this style in an even-sized game-pixel frame with per-pixel radial/angular coverage and linear-light fill/outline/background blending, then enlarge with nearest-neighbor sampling. Render length, pixel gap, thickness, color/alpha, outline, and T-shape where applicable to other styles. Repaint on resize or background/position changes; do not use a continuous animation loop.
5. Import stages values only after the user selects **Import**. Cancel, closing the dialog, rendering failures, or unsupported values must leave the current staged profile state untouched. Invalid codes continue to show the existing error path.
6. Label the result as an approximate preview. Dynamic movement/recoil behavior may be displayed at rest or called out as unsupported. A byte-for-byte match with a public shader reconstruction is useful evidence, but do not claim an exact Source 2 render without a lossless in-game capture under known resolution and postprocessing settings.

## Verification and acceptance criteria

- Add focused regression coverage for decoding-to-preview mapping and safe handling of missing, out-of-range, or malformed values. Extend the existing crosshair share-code test where practical; keep fixture tests isolated from live Steam/CS2 files and remote profile data.
- Cover supported current and legacy codes, including a style-9 Static Quadrant reference, invalid/checksum-failing codes, unusual color and alpha values, optional/missing fields, and cancel versus import behavior.
- Confirm that previewing and dragging never mutate staged values, profile files, CFGs, or GitHub data; only **Import** stages the decoded settings.
- Perform a Windows Forms smoke check at the repository's supported Windows PowerShell 5.1 runtime. Compare representative static previews with known CS2 appearances at a documented resolution when a trustworthy reference is available; record any remaining approximation.
- Run only the focused checks relevant to the change plus the repository-required syntax/context checks. Report what was run and any UI or visual verification that could not be performed.
