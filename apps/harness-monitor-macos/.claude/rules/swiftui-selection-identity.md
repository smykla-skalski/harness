---
description: SwiftUI selection identity rules for dynamic Harness Monitor controls
globs: apps/harness-monitor-macos/Sources/**/*.swift
---

# SwiftUI selection identity

## Bound selections must have a rendered tag

Every `Picker`, segmented control, or tagged selection control must render a `.tag(...)` matching the bound `selection` value in the same body evaluation.

If a nil or empty selection is valid, render an explicit nil or empty-state tag. Never bind to a synthetic ID that is not present in the control's current option set.

```swift
// correct - selection is clamped before Picker validates it
Picker("Actor", selection: Binding(
  get: { store.validInspectorActorID(for: sessionID) },
  set: { store.selectInspectorActor($0, for: sessionID) }
)) {
  ForEach(actorOptions) { actor in
    Text(actor.displayName).tag(actor.id)
  }
}

// wrong - staleActorID can belong to a previous session and has no tag here
Picker("Actor", selection: $staleActorID) {
  ForEach(actorOptions) { actor in
    Text(actor.displayName).tag(actor.id)
  }
}
```

## Clamp dynamic selections before render

For option sets derived from session-scoped data, validate selection synchronously in the binding getter, store getter, or parent state before the control renders.

Do not rely on `.task(id:)`, `.onAppear`, or `.onChange` to repair a stale selection after render. SwiftUI validates the picker selection while building the current body, so post-render repair still logs invalid selection warnings.

## Reset state at session boundaries

When switching sessions, agents, tasks, or any parent context that changes the valid option set, either:

- derive the selection from the current context every render, or
- reset the stateful child view with a stable context identity such as `.id(selectedSessionID)`.

Do not carry local `@State` or store-backed selection from one session into another without checking it against the new session's options.

Avoid random identity resets like `.id(UUID())`. They hide state bugs and destroy useful view identity. Use a stable ID only when the local state is genuinely scoped to that parent context.

## Harness Monitor inspector fallback order

For inspector actor pickers and action senders:

- First keep the previously selected actor only if it exists in the current session detail.
- Then fall back to the current session leader only if that leader exists in the current session detail.
- Then fall back to the first current agent that can receive the action.
- Otherwise return nil, disable the action, and render a clear empty state.

If an inactive or missing leader must remain visible for explanation, render a disabled option with the same tag. Never bind to a missing leader ID without rendering a matching tag.

## Regression coverage

Any fix for `Picker: the selection ... is invalid and does not have an associated tag` must include a regression that creates stale selection state from a previous session and proves the current session does not bind controls or actions to stale IDs.

Prefer store-level tests for selection normalization and action target derivation. Add UI tests only when the bug depends on view identity or AppKit/SwiftUI runtime behavior that the store cannot cover.
