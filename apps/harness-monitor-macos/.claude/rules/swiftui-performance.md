---
description: SwiftUI performance rules for the Harness Monitor macOS app
globs: apps/harness-monitor-macos/Sources/**/*.swift
---

# SwiftUI performance

## No object creation in body path

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

## Thread safety for formatters

DateFormatter and RelativeDateTimeFormatter are not thread-safe. Mark them and their calling functions @MainActor (not nonisolated(unsafe)) since view bodies always run on the main actor.

## Animation scoping

Place .animation(_:value:) on the narrowest view that changes, not on parent containers. Always include the value: parameter. Wrap conditionally-shown content in Group {} when applying animation to avoid animating unrelated siblings.

## No geometry feedback loops during animation

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

## No computed properties reading multiple observable slices in view body

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
