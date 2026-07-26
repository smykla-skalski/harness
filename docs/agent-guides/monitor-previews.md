# Harness Monitor previews

Use this guide for Harness Monitor SwiftUI preview authoring and shell-rendered PNG snapshots. The default verification path for a visual change is the headless Preview Host, not the full Harness Monitor app and not Xcode Canvas.

## Quick start

Work from the assigned Monitor worktree and reuse its session-scoped build and runtime lanes:

```bash
HARNESS_MONITOR_BUILD_LANE=<session-lane> \
HARNESS_MONITOR_RUNTIME_LANE=<session-lane> \
mise run monitor:preview -- task-board-inspector tmp/preview-snapshots/task-board-inspector/<task>
```

List the registered snapshot suites with:

```bash
mise run monitor:preview -- --list
```

`monitor:preview` builds the `HarnessMonitorUIPreviews` scheme in the active build lane, runs `HarnessMonitorPreviewHost` with no window or Dock presence, verifies that the renderer produced fresh non-empty PNGs, copies them to the requested directory, and prints their absolute paths. Keep generated snapshots under the worktree's ignored `tmp/preview-snapshots/` tree and do not commit them.

After every visual task, render the affected suite and inspect every emitted image with the environment's native image inspection tool. Include clickable snapshot paths in the handoff so the user can review the result without launching the application.

## Authoring rules

All `#Preview` blocks belong to the `HarnessMonitorUIPreviewable` target and must live in the nearest `Views/<Domain>/Previews/` directory. Runtime implementation files stay free of `#Preview`, and preview filenames use a leading `Preview` prefix.

Use deterministic fixtures that exercise the changed state. A layout or typography change should normally provide both the default application font scale and the largest supported scale. Apply `harnessPreviewSceneAppearance(...)` so snapshots use the same appearance and font-scale environment as the application.

Views that use SwiftData or `@Query` must receive `PreviewFixtures.previewContainer()` or an equivalent fixture container. Keep expensive formatters and encoders out of view bodies; use static `@MainActor` values.

Previewable views must not store closure properties such as `let onTap: () -> Void`. Use `HarnessAsyncActionButton.StoreAction` or environment actions such as `@Environment(\.openWindow)` so the Preview Host can construct the view without app-owned callbacks.

Do not wrap `#Preview` in `#if DEBUG`. Add a canonical top-level screen to `apps/harness-monitor/Previews.json` when applicable.

## Adding a shell snapshot suite

1. Add or update the dedicated preview fixture in `HarnessMonitorUIPreviewable`.
2. Add an `@MainActor` renderer that accepts an output directory and reports failure when it cannot create a non-empty PNG.
3. Dispatch the renderer from `HarnessMonitorPreviewHost` before its scene is created. Set `NSApplication.shared.setActivationPolicy(.prohibited)` and exit after rendering so the host cannot steal focus.
4. Register the suite name and environment dispatch in `apps/harness-monitor/Scripts/render-preview-snapshots.sh`.
5. Run `mise run monitor:preview -- <suite> <output-directory>` and inspect every emitted image.

For SwiftUI surfaces, render through an explicitly sized `NSHostingView`, call `layoutSubtreeIfNeeded()`, then capture with `bitmapImageRepForCachingDisplay(in:)` and `cacheDisplay(in:to:)`. This is the established off-screen macOS path and correctly captures containers such as `ScrollView`; do not substitute `ImageRenderer` without proving that the emitted bitmap contains the complete view.

Keep the renderer deterministic: no daemon connection, network request, timer-dependent state, or dependency on the user's running app. The Preview Host links only `HarnessMonitorKit` and `HarnessMonitorUIPreviewable`.

## Validation

The snapshot command proves that the preview target compiles and that the renderer produced current PNGs. Also run `git diff --check` and the smallest relevant Monitor lint, build, or focused test for the product change. A snapshot is visual evidence, not a replacement for behavior tests.

Do not run Xcode Canvas concurrently with a shell snapshot build in the same lane; both can mutate the lane's preview build state and invalidate SDK stat caches. Canvas is optional for interactive exploration only. Automated work and user handoffs use the shell snapshot command.

If a preview crashes with `TableViewListCore_Mac2.swift:5170`, add a TODO that references the macOS 26 SwiftUI bug and disable only the offending preview until the platform defect is resolved.
