---
name: swiftui-performance-macos
description: SwiftUI and Harness Monitor performance rules. Covers no DateFormatter/JSONEncoder/NumberFormatter allocation in view body, cached @MainActor formatters, no .repeatForever on always-visible views, no persisted state in .inspector/.searchable on first frame, no mirror-state loops for store-backed selection, no geometry feedback loops during animation, OSSignposter contract (io.harnessmonitor/perf/<scenario>), perf test env vars (HARNESS_MONITOR_KEEP_ANIMATIONS), and isolated worktree requirements for `mise run monitor:macos:audit`. Invoke when writing or reviewing performance-sensitive SwiftUI code, animations, formatters, startup flow, persisted layout state, XCTest perf tests, or running Instruments audits in apps/harness-monitor-macos.
---

# SwiftUI performance rules for Harness Monitor

Performance-critical patterns for the Harness Monitor macOS app. Hard rules learned from idle CPU audits, startup investigations, and Instruments traces.

## SwiftUI body performance

### No object creation in body path

Never create DateFormatter, JSONEncoder, NumberFormatter, or similar objects inside a view body or any function called from body. Use static lets.

```swift
// correct
private static let prettyEncoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  return encoder
}()

// wrong - allocates per render
func prettyPrint() -> String {
  let encoder = JSONEncoder()  // created every body call
  ...
}
```

### Thread safety for formatters

DateFormatter and RelativeDateTimeFormatter are not thread-safe. Mark them and their calling functions `@MainActor` (not `nonisolated(unsafe)`) since view bodies always run on the main actor.

### Animation scoping

Place `.animation(_:value:)` on the narrowest view that changes, not on parent containers. Always include the `value:` parameter. Wrap conditionally-shown content in `Group {}` when applying animation to avoid animating unrelated siblings.

### No geometry feedback loops during animation

`onGeometryChange` fires every frame during an animation. Writing geometry values to `@State` or `@AppStorage` inside `onGeometryChange` creates a feedback loop: geometry change -> state write -> body re-evaluation -> geometry change. This runs at 60fps and rebuilds the entire view tree each frame.

When tracking geometry for persistence (inspector width, detail column width), suppress writes during animation transitions. Use a boolean flag that goes true before the animation starts and resets after the animation duration.

```swift
// correct - suppress during animation
@State private var isAnimating = false

.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
  guard !isAnimating else { return }
  persistedWidth = width
}

// wrong - writes every animation frame
.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
  persistedWidth = width
}
```

### No computed properties reading multiple observable slices in view body

Computed properties on views that read multiple `@Observable` properties register observation for all of them, causing the body to re-evaluate when any one changes. Pre-compute these values during the store's UI sync phase and store the result on a single slice property.

```swift
// correct - reads one pre-computed property
var body: some View {
  switch inspectorUI.primaryContent { ... }
}

// wrong - reads 4 properties across 3 slices per body call
private var primaryContent: InspectorPrimaryContentState {
  .init(
    selectedSession: selection.matchedSelectedSession,
    selectedSessionSummary: contentUI.selectedSessionSummary,
    inspectorSelection: selection.inspectorSelection,
    isPersistenceAvailable: inspectorUI.isPersistenceAvailable
  )
}
```

## Idle CPU prevention

### Never use .repeatForever() on always-visible views

`.repeatForever()` forces the rendering pipeline to run at 60fps permanently, consuming CPU even when the app is idle. This applies to any animation modifier - scale, opacity, rotation, offset.

Allowed uses of `.repeatForever()`:
- Spinner/loading indicators that are **only visible during transient loading states** (seconds, not minutes)
- Content that the user explicitly started and will explicitly stop

Banned uses:
- Status indicators that are visible during normal idle operation (connection dots, activity pulses)
- Decorative ambient animations (breathing effects, idle hints, attention-seeking loops)
- Any view that remains on screen indefinitely

For state-change feedback on always-visible elements, use `phaseAnimator` with a trigger that fires once per transition:

```swift
// correct - fires once on state change, then idle
@State private var flashTrigger = 0
.onChange(of: isActive) { _, active in
  guard active else { return }
  flashTrigger += 1
}
.phaseAnimator(Phase.allCases, trigger: flashTrigger) { view, phase in
  view.scaleEffect(phase.scale)
} animation: { phase in
  switch phase {
  case .idle: .easeOut(duration: 0.3)
  case .bright: .easeIn(duration: 0.12)
  case .settle: .easeOut(duration: 0.3)
  }
}

// wrong - runs at 60fps forever while connected
.animation(
  .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
  value: isPulsing
)
```

### Never allocate formatters in view body or functions called from body

DateFormatter, NumberFormatter, JSONEncoder, ByteCountFormatter - all are expensive to allocate. Cache as `@MainActor` static lets at file scope or on the type.

```swift
// correct - allocated once
@MainActor private let timestampFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "d MMM HH:mm:ss"
  return formatter
}()

// wrong - allocated every render
func formatTimestamp(_ date: Date) -> String {
  let formatter = DateFormatter()
  formatter.dateFormat = "d MMM HH:mm:ss"
  return formatter.string(from: date)
}
```

If the formatter needs per-call configuration (timezone, calendar), reuse the cached instance and set only the varying properties. Property assignment is orders of magnitude cheaper than allocation.

### No gratuitous periodic animations

`while !Task.isCancelled { sleep; withAnimation { ... } }` loops that run idle hint animations, attention-seeking morphs, or decorative effects burn CPU for no user benefit. Every `withAnimation` triggers a view tree diff.

Acceptable periodic patterns:
- Status ticker rotating messages every 4+ seconds (one state change, minimal cost)
- Connection probe pinging health every 10+ seconds (network I/O, not animation)

Unacceptable periodic patterns:
- Multi-step spring animation sequences on timers (multiple withAnimation + Task.sleep per cycle)
- Idle hint animations that morph between states to attract attention
- Any animation cycle that touches 3+ @State properties

### Don't stack animations on the same view

One animation communicating a state is enough. Two competing animations on the same view (e.g., spinner rotation + pulse opacity/scale) double the rendering cost for no perceptual benefit.

```swift
// correct - spinner alone communicates loading
HStack {
  HarnessMonitorSpinner(size: 14)
  Text(title)
}

// wrong - spinner + redundant pulse animation
HStack {
  HarnessMonitorSpinner(size: 14)
  Text(title)
}
.opacity(animates ? 1 : 0.62)
.scaleEffect(animates ? 1 : 0.97)
.animation(.easeInOut(duration: 1.1).repeatForever(), value: animates)
```

## Startup focus and persisted state

### Do not drive focus-bearing modifiers from persisted state on the first frame

Never wire `@AppStorage` or `@SceneStorage` directly into startup-sensitive modifiers like `.inspector(isPresented:)`, `.searchable(isPresented:)`, scene-level `FocusedValue`, or programmatic `@FocusState` changes during the initial body evaluation.

If a persisted preference must affect one of those modifiers, hydrate it into local `@State` after the first frame settles, for example in `.task { await Task.yield(); ... }`.

### No mirror-state loops for store-backed selection or search

Do not mirror store-backed values such as `selectedSessionID`, `searchText`, or similar UI control state through local `@State` plus paired `.onAppear` and `.onChange` sync handlers.

That pattern creates double updates during startup and restoration. Prefer a single `Binding(get:set:)` that talks directly to the store or UI slice.

### Scene restoration may seed state, not replay the full load path

When restoring `@SceneStorage` values, seed the store once with an idempotent or lightweight setter. Do not call a second full startup load path from `onAppear` if bootstrap or persisted restoration already owns selection and hydration.

For session selection, prefer a `prime...` or other no-extra-fetch path over replaying `selectSession(...)` during startup.

### Keep command state out of startup FocusedValue churn

Do not bridge command or menu enablement through `FocusedValue` or `.focusedSceneValue(...)` when plain snapshot data injection is sufficient.

Use focus-coupled command state only when macOS requires it and the path has been validated to avoid multiple updates in one frame.

### Geometry persistence must ignore the first inspector measurement

When persisting geometry from `.onGeometryChange(...)` into `@AppStorage`, skip the first startup measurement for focus-bearing chrome such as the inspector. Writing persisted layout back during the initial presentation can create another same-frame update loop.

### Validation before commit

For any change that touches `.inspector`, `.searchable`, `@FocusState`, `FocusedValue`, `@SceneStorage`, `@AppStorage`, or startup presentation state in Harness Monitor:

- Run the smallest macOS build lane that covers the change.
- Launch the app at least twice through the XcodeBuildMCP or `xcodebuild` path.
- Check the unified log for `FocusedValue update tried to update multiple times per frame`.
- Do not commit while a fresh launch still emits that fault.

## Performance instrumentation

### Signpost contract

The perf driver and XCTest perf tests share a signpost contract. Both sides must agree on all three values:

- Subsystem: `"io.harnessmonitor"`
- Category: `"perf"`
- Name: the scenario's raw value (e.g. `"launch-dashboard"`)

If the subsystem or category drifts between the driver (`OSSignposter`) and the tests (`XCTOSSignpostMetric`), the metric captures zero data silently. No error, just empty results.

The driver uses `beginAnimationInterval` (not `beginInterval`). The animation variant tells the system to track rendering hitches during the interval. Using plain `beginInterval` would lose hitch/frame data.

### Adding a new perf scenario

When adding a case to `HarnessMonitorPerfScenario`, update all of these:

1. The enum case and `rawValue` in `HarnessMonitorAppConfiguration.swift`
2. `defaultPreviewScenario` and `initialPreferencesSection` on the enum
3. `signpostName` in the private extension in `HarnessMonitorAppSceneSupport.swift` (must return `StaticString` matching the raw value exactly)
4. The scenario's execution branch in `HarnessMonitorPerfDriver.run(scenario:store:openWindow:)`
5. A `testXxxHitchRate()` method in `HarnessMonitorPerfTests.swift`
6. `scenarioWaitDuration` in `HarnessMonitorPerfTests.swift`
7. The `ALL_SCENARIOS` array in `Scripts/run-instruments-audit.sh`
8. The `SWIFTUI_SCENARIOS` or `ALLOCATIONS_SCENARIOS` array in `Scripts/run-instruments-audit.sh`
9. The `preview_scenario_for` and `duration_for` functions in `Scripts/run-instruments-audit.sh`
10. The `templates` dict in the manifest generation Python block in `Scripts/run-instruments-audit.sh`

Missing any of these causes silent failures - the test runs but captures no signpost data, or the xctrace pipeline skips the scenario.

### Perf test environment variables

Perf tests must set `HARNESS_MONITOR_KEEP_ANIMATIONS=1`. Without it, the UI test animation modifier (`HarnessMonitorUITestAnimationModifier`) disables all SwiftUI animations and the app delegate disables AppKit animations when `HARNESS_MONITOR_UI_TESTS=1`. Measuring hitches with animations disabled is meaningless.

Do not set `HARNESS_MONITOR_LAUNCH_MODE` explicitly in perf tests. The scenario's `applyingDefaults(to:)` sets it to `preview` automatically. Setting it manually creates a second source of truth.

### Never run perf tests in the default suite

Perf tests take 8-12 seconds per scenario per iteration (3 iterations default). They steal window focus and are inherently noisy. Do not add them to the default `xcodebuild test` lane. Run them with `-only-testing:HarnessMonitorUITests/HarnessMonitorPerfTests` or as individual methods.

### Isolate instrumentation runs in a temporary worktree

Instrumentation/audit runs must not execute from a dirty shared worktree. They build, stage, launch, and trace app bundles, so parallel edits in the main checkout can make the run measure the wrong source revision or mix unrelated changes into the build.

For every audit run that is intended to prove a performance fix, prefer the dedicated wrapper:

```bash
mise run monitor:macos:audit:from-ref -- \
  --ref <sha-or-ref> \
  --label <name> \
  ...
```

It creates the temporary worktree, runs `mise trust`, delegates to
`mise run monitor:macos:audit`, verifies `manifest.json` provenance, and
removes the worktree on exit.

If you need to reason about that behavior or change it, the required contract is:

1. Create a temporary worktree from the exact commit or ref under test, preferably under a scratch directory, for example:

   ```bash
   git worktree add /tmp/harness-monitor-audit-<sha>-<date> <sha-or-ref>
   ```

2. Immediately run `mise trust` inside that new worktree before any build, audit,
   or inspection command:

   ```bash
   (cd /tmp/harness-monitor-audit-<sha>-<date> && mise trust)
   ```

   This is required so audit logs do not get polluted by mise trust warnings and
   so the worktree uses the expected repo tool configuration. Do not continue
   after creating the worktree until `mise trust` has completed cleanly.

3. Run `mise run monitor:macos:audit -- ...` from inside that worktree. Compare against the baseline path from the main repo only when needed; do not run the audit from the main worktree just to access the baseline.

4. Verify the generated `manifest.json` before trusting the numbers. The embedded commit, dirty flag, workspace fingerprint, host binary hash, and staged host bundle ID must match the worktree/ref being measured.

5. Before removing the worktree, copy the relevant audit artifacts back to the
   main workspace so the run can be compared later. Preserve the whole run
   directory when storage is acceptable. If storage is constrained, preserve at
   least `manifest.json`, `summary.json`, `summary.csv`, `comparison.json`,
   `comparison.md`, `captures.tsv`, and the `metrics/` directory. Use an
   explicit copy command that bypasses shell aliases, such as `command rsync -a`,
   so local aliases cannot accidentally preserve the temporary worktree path.

6. Clean up the temporary worktree only after required artifacts have been
   copied or recorded:

   ```bash
   git worktree remove /tmp/harness-monitor-audit-<sha>-<date>
   ```

Leaving audit worktrees behind is not acceptable. If cleanup fails because a process still owns files in the worktree, stop the leftover process and rerun `git worktree remove`.

### xctrace scripts

The Python scripts under `apps/harness-monitor-macos/Scripts/` parse Instruments XML exports. They must stay compatible with the xctrace export format, which uses ref-based deduplication for elements. The `dereference` function in `extract-instruments-metrics.py` handles transitive refs (ref -> ref -> element).

When modifying the extractor or comparator, run the parser regression tests:

```
mise run monitor:macos:test:scripts
```

Test fixtures in `Scripts/tests/fixtures/` are minimal XML samples. Update them when adding new schema parsers.

## Research backing

Rationale for these rules lives under `apps/harness-monitor-macos/docs/research/ux/`:

- `07-performance-responsiveness.md` - response time thresholds, 60fps budget, main thread budget
- `05-swiftui-best-practices.md` - SwiftUI body performance, @Observable observation rules
