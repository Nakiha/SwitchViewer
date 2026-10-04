# Floating control bar refactor

The app starts with one floating control bar and its menu bar icon. The welcome window and standalone settings panel are removed. Source, picture, audio, charts, and tools are icon-and-label tabs in the bar. Selecting a tab expands the same window downward; selecting it again collapses it. Picture controls use two columns. The preview window opens only through source selection or an explicit preview action.

Configuration is embedded as ViewerSettingsView inside PerformanceToolbar. Capture, presentation, rendering, device selection, diagnostics, and app lifecycle now have separate source files. Custom optical-flow and blending implementations were removed; capture interpolation retains Apple native and Apple proxy modes.

Validation on 2026-10-01:

- Application build and strict deep signature verification passed.
- All 19 interpolation, color, playout, and pressure tests passed.
- Running UI verified: tab switching, repeated-tab collapse, embedded source and picture controls, audio and tools, device/format discovery, and live chart telemetry.
- The built-in game fixture was launched from Tools and stopped from Source; Apple interpolation telemetry reached the bar.
- No camera, microphone, or real-game capture was started for this UI validation.

## State-based workflow (2026-10-03)

The floating bar now starts collapsed with only Video Capture and Game Interpolation tabs. Selecting Video Capture expands capture-card device/format selection or window/display selection. Start Capture opens the preview and switches the bar to runtime controls. Selecting Game Interpolation shows only Wuwa; clicking it launches the game and switches to runtime controls after the child process starts. The generic game picker and developer fixture are removed from the user interface.

Both workflows use the same Processing, Monitoring, Shortcuts, and Tools tabs. Processing routes its interpolation toggle to the active capture or game controller. Capture picture, preview, and audio options appear only for capture. Game launch preferences are editable for the next launch and labelled accordingly. Tools and shortcuts show actions appropriate to the active source. Stop Capture or Exit Game is always available in the running bar. Stopping, game exit, or a lost screen source returns to the relevant selection panel; runtime metrics are cleared on transitions.

Validation:

- Debug and release builds passed; the local SwitchViewer.app bundle was rebuilt and signed.
- All 62 existing interpolation tests passed.
- Scripts/check-ui-workflow.sh exercises the real injected game fixture, live interpolation pause/resume, monitoring and tools, tab collapse, game exit, simulated capture-session start/stop and screen-source loss, and visible control bounds.
- Visual inspection confirmed capture/game selection and game runtime/monitor layouts. The existing user game session was left running in the old application process.
- Capture-session checks exercise UI state and preview-window lifecycle without accessing a camera, microphone, or real capture card. Real device capture and Wuwa launch were not repeated for this interface change.
