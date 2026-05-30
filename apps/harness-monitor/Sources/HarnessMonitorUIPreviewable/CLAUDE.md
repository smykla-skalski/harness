# CLAUDE.md

Read `AGENTS.md` first. It is the canonical layout and preview-organization contract for this directory.

## Claude-specific working rules

1. Do not add files directly under `Views/`; always choose the nearest domain folder first.
2. Prefer `Views/<Domain>/Previews/Preview<Name>.swift` companion files over inline previews in runtime files.
3. Runtime implementation files in this directory should not contain `#Preview`; preview code belongs in the nearest `Previews/` folder.
4. Keep moves feature-local. Examples: `Workspace/Window/`, `Workspace/Sidebar/`, and `Settings/Supervisor/`.
5. Before finishing a layout change here, confirm that every file containing `#Preview` lives under `Previews/`.
6. If Settings or toolbar clicks feel laggy, inspect the shared MCP-tracking path before refactoring the local SwiftUI layout. Dense panes here often mount tracked action controls, and a probe that resolves `accessibilityFrame()` or republishes on every `NSWindow.didUpdateNotification` can be the real bottleneck.
7. Keep SwiftUI action handlers light: enqueue real work on `HarnessMonitorAsyncWorkQueue.shared`, never on per-feature queues or directly on the main thread, and return to the MainActor only for final UI state/toast updates.
