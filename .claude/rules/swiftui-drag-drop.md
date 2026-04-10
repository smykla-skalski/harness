# SwiftUI drag and drop

These rules apply to `.draggable`, `.dropDestination`, `onDragSessionUpdated`, and related drag-drop APIs in the Harness Monitor macOS app. They lock in patterns learned from a drag-drop system rewrite that fixed silent drop rejection, animation snap-backs, and identity-breaking modifier branches.

## Unconditional `.draggable`

Never wrap `.draggable` in a `@ViewBuilder if/else`. Conditional drag produces `_ConditionalContent<Draggable, Self>`, which tears down the internal drag gesture state every time the condition flips, and violates the "no identity-breaking modifier branches" rule in `swiftui-view-structure.md`.

```swift
// correct - drag is always installed, destination validates
Button { inspect(task) } label: { ... }
  .harnessInteractiveCardButtonStyle()
  .draggable(dragPayload) { DragPreview(...) }

// wrong - @ViewBuilder branch on a mutable condition
@ViewBuilder
func conditionalDrag(isEnabled: Bool) -> some View {
  if isEnabled {
    draggable(payload) { preview }
  } else {
    self
  }
}
```

Conditional draggability is a validation concern of the destination, not the source. Users may initiate a drag on a currently-invalid task; every drop destination must reject it with a clear reason (see next rule).

## Drop rejections must surface user-visible feedback

`.dropDestination` action closures that return `false` MUST set `store.lastError` with a specific reason. A silently-cancelled drop is a bug - users perceive it as "drag-drop is broken".

```swift
// correct
private func handleDrop(_ payloads: [Payload], _: CGPoint) -> Bool {
  guard let payload = payloads.first else {
    store.reportDropRejection("Cannot assign task: no task payload in drop.")
    return false
  }
  guard payload.sessionID == sessionID else {
    store.reportDropRejection(
      "Cannot assign task: drag source does not belong to this session."
    )
    return false
  }
  guard let targetID = action.targetID else {
    store.reportDropRejection(action.feedback.accessibilityLabel)
    return false
  }
  Task { await store.performDrop(...) }
  return true
}

// wrong - silent failure
private func handleDrop(_ payloads: [Payload], _: CGPoint) -> Bool {
  guard let payload = payloads.first,
    payload.sessionID == sessionID,
    let targetID = action.targetID
  else { return false }
  ...
}
```

Reuse existing human-readable copy from feedback types when possible. `AgentTaskDropFeedback.accessibilityLabel` in `SessionAgentLaneViews.swift` is a good example.

`store.reportDropRejection(_:)` in `HarnessMonitorStore+Actions.swift` is the canonical entry point; it routes through `store.lastError` and the existing inspector error display.

## `DragSession.Phase` switches must be exhaustive

Enumerate every case explicitly. Never use a catch-all `default` for phase transitions.

```swift
// correct
switch session.phase {
case .initial, .active:
  dragPhase = session.phase
case .ended, .dataTransferCompleted:
  dragPhase = nil
@unknown default:
  dragPhase = nil
}

// wrong - default hides intent and silently swallows future phases
switch session.phase {
case .initial, .active:
  dragPhase = session.phase
default:
  dragPhase = nil
}
```

`DragSession.Phase` on macOS 26 is `.initial`, `.active`, `.ended(DropOperation)`, `.dataTransferCompleted`. The `.ending(_)` case is `@available(macOS, unavailable)` and must not be written on macOS code paths. Use `@unknown default` only for SDK forward-compat.

## Drag-state animations must be unconditional

Never write `.animation(isDragging ? .someAnimation : nil, value: isDragging)`. A nil animation cancels `.transition(...)` on removal, so overlays snap away instead of fading. Use a single non-nil animation:

```swift
// correct - overlay fades both in and out
.animation(.easeOut(duration: 0.10), value: isDragging)

// wrong - overlay snaps out because animation is nil when going false
.animation(isDragging ? .easeOut(duration: 0.10) : nil, value: isDragging)
```

Do not stack an explicit `withAnimation { ... }` inside the drag session update handler on top of an outer `.animation(_:value:)`. Pick one animation source. The outer `.animation(_:value:)` is usually the right choice because it applies uniformly to every derived visual (overlay, border, opacity, scale).

## Click + drag cards use `Button` + `harnessInteractiveCardButtonStyle`

Cards that combine click-to-inspect and drag-to-reassign must use `Button { action } label: { cardSurface }` with `.harnessInteractiveCardButtonStyle()`. Do NOT use `.onTapGesture` on top of `.draggable`.

```swift
// correct - native button semantics + drag
Button {
  inspect(item.id)
} label: {
  cardSurface
}
.harnessInteractiveCardButtonStyle()
.draggable(payload) { DragPreview(...) }

// wrong - hand-rolled tap, manual hover, manual accessibility traits
cardSurface
  .onContinuousHover { ... }
  .onTapGesture { inspect(item.id) }
  .draggable(payload) { DragPreview(...) }
  .accessibilityAddTraits(.isButton)
  .accessibilityAction { inspect(item.id) }
```

Benefits of the Button pattern: native press/hover/focus rings, keyboard activation (Return/Space), automatic `.isButton` accessibility trait, automatic label combination, and consistent visual treatment with other card surfaces. See `swiftui-button-styling.md` for general button-style rules.

The `InteractiveCardButtonStyle` defined in `HarnessMonitorInteractiveCardChrome.swift` already sets the content shape internally; don't add another `.contentShape(...)` to a view that has this style.

## One `DragSession.Phase?` snapshot, not multiple flags

Mirror drag state as a single optional phase. Derive all visual effects from it. Do NOT split drag state across multiple `@State` flags (e.g. `isDragSessionActive` plus `isDragStarted` plus `isDragPreviewPresented`) because they drift.

```swift
// correct
@State private var dragPhase: DragSession.Phase?

private var isDragging: Bool {
  switch dragPhase {
  case .initial, .active: true
  default: false
  }
}

// wrong - two flags tracking the same underlying state
@State private var isDragSessionActive = false
@State private var isDragPreviewPresented = false
```

## Do not reset unrelated state in drag-session cleanup

A drag-end cleanup must only clear drag-related state. Do not reset hover, focus, or other unrelated UI state in the same handler - `.onContinuousHover` will not re-fire until the next pointer movement, leaving the hover highlight stuck off.

```swift
// correct - only drag state
private func updateDragSession(_ session: DragSession) {
  switch session.phase {
  case .initial, .active: dragPhase = session.phase
  case .ended, .dataTransferCompleted: dragPhase = nil
  @unknown default: dragPhase = nil
  }
}

// wrong - clobbers hover, which stays false until cursor moves
private func resetAll() {
  isDragSessionActive = false
  isHovered = false
}
```

When using `Button + harnessInteractiveCardButtonStyle`, hover is handled by the button style internally and is not visible to your code - another reason to prefer that pattern.

## `onDragSessionUpdated` is macOS-only

`onDragSessionUpdated` and `DragSession` are `@available(macOS 26.0, *)` with `@available(iOS, unavailable)` / `@available(tvOS, unavailable)` / `@available(watchOS, unavailable)`. If you ever share drag code with an iOS/visionOS target, gate it with `#if os(macOS)`. The Harness Monitor app is macOS-only today, so no gate is needed.

## Do not react to external state changes during an active drag

Do not use `.onChange(of: isDragEnabled)` or similar to tear down drag state mid-gesture. External state may flip while the user is dragging (e.g. task status transitions), and ripping drag state out from under an in-flight gesture produces a visual snap and leaves the drag session in an inconsistent state. Let the natural `DragSession.Phase` transitions drive cleanup.
