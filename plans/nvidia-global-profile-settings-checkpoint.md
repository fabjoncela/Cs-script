# NVIDIA Global Profile Settings Checkpoint

Date: 2026-11-09

## Request

Extend CafeLauncher profile Apply to set NVIDIA **Power management mode** globally to **Prefer maximum performance**, and try to set global **Low Latency Mode** to **Ultra**, reporting whether the driver accepts and applies it.

## Done

- Inspected the current checkout: `main` at `3c31fb9`, matching `origin/main`. The existing untracked `plans/backend-vs-cs-script-audit.md` was left untouched.
- Added Power management mode to the global DRS routine in `cafe.bat`, using NVIDIA's public `PREFERRED_PSTATE_ID` (`0x1057EB71`) and `PREFERRED_PSTATE_PREFER_MAX` (`0x00000001`) values. The routine logs and verifies the saved value alongside the other global driver settings.
- Updated `context.md` and `tools/Test-NvidiaCompatibility.ps1` to document and guard the supported setting and reject the unsupported legacy Low Latency IDs in the normal apply path.
- A live Low Latency probe checked and attempted both legacy IDs (`0x10835000`, `0x0005F543`). Both reads and writes returned NVAPI status `-160`; the DRS session was discarded without saving. No Low Latency setting changed.
- Checked the alternate NVIDIA App UI at **Graphics → Global Settings**. Its accessible driver-settings page exposes **Low Latency Mode** with `Off`, `On`, and `Ultra` choices, unlike the NVIDIA Control Panel window's unavailable accessibility tree. The NVIDIA App currently reports global **Low Latency Mode = Ultra** and **Power Management Mode = Prefer maximum performance**. The Control Panel's Global Settings also showed Low Latency Mode = Ultra.
- NVIDIA's supported route remains the NVIDIA App/Control Panel UI: NVIDIA's own developer forum says Low Latency Mode has no supported NVAPI SDK setter, and its response to the CLI question says there is no Control Panel CLI. NVIDIA's App documentation confirms its Graphics tab exposes global Driver Settings. This confirms the UI route and the current value, but does not establish a supported app API or prove that CafeLauncher can safely automate it.
- The live global DRS apply returned `True`, verified `12/12` settings, and confirmed Power management mode persisted as `0x00000001` (Prefer maximum performance). Its prior value was already `0x00000001`.
- `Test-NvidiaCompatibility.ps1`, `Test-CafeLauncher.ps1`, and `Test-ContextFreshness.ps1` passed. CafeLauncher source retained Windows CRLF and release metadata `2026.11.08.9` remains current.

## Remaining work

- The requested Low Latency value is already Ultra globally. CafeLauncher cannot set it through the installed driver's NVAPI DRS interface. If automatic application is still wanted, the remaining engineering task is to prototype accessibility-based automation of the NVIDIA App and verify it survives app/driver updates; NVIDIA does not provide a documented API for that route. Avoid screen-coordinate automation because it would be fragile.
- The launcher source change and this checkpoint are tracked separately from any machine-side NVIDIA setting state. This file does not claim a commit, push, or release state; use Git and the release workflow for that status.

## References

- NVIDIA NVAPI driver settings: https://docs.nvidia.com/nvapi/_nv_api_driver_settings_8h_source.html
- NVIDIA developer forum response on Low Latency Mode support: https://forums.developer.nvidia.com/t/low-latency-mode-setting/241104
- NVIDIA Control Panel CLI/API response: https://forums.developer.nvidia.com/t/nvidia-control-panel-cli-api-change/278097
- NVIDIA App Graphics and Global Settings documentation: https://www.nvidia.com/en-us/geforce/news/gfecnt/202411/nvidia-app-download-and-features/
- NVIDIA Profile Inspector issue describing legacy Low Latency setting read/write failures since R445.75: https://github.com/Orbmu2k/nvidiaProfileInspector/issues/46
