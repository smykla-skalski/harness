---
description: SwiftUI startup focus and persisted UI state rules for the Harness Monitor macOS app
globs: apps/harness-monitor-macos/Sources/**/*.swift
---

# SwiftUI startup focus

## Do not drive focus-bearing modifiers from persisted state on the first frame

Never wire `@AppStorage` or `@SceneStorage` directly into startup-sensitive modifiers like `.inspector(isPresented:)`, `.searchable(isPresented:)`, scene-level `FocusedValue`, or programmatic `@FocusState` changes during the initial body evaluation.

If a persisted preference must affect one of those modifiers, hydrate it into local `@State` after the first frame settles, for example in `.task { await Task.yield(); ... }`.

## No mirror-state loops for store-backed selection or search

Do not mirror store-backed values such as `selectedSessionID`, `searchText`, or similar UI control state through local `@State` plus paired `.onAppear` and `.onChange` sync handlers.

That pattern creates double updates during startup and restoration. Prefer a single `Binding(get:set:)` that talks directly to the store or UI slice.

## Scene restoration may seed state, not replay the full load path

When restoring `@SceneStorage` values, seed the store once with an idempotent or lightweight setter. Do not call a second full startup load path from `onAppear` if bootstrap or persisted restoration already owns selection and hydration.

For session selection, prefer a `prime...` or other no-extra-fetch path over replaying `selectSession(...)` during startup.

## Keep command state out of startup FocusedValue churn

Do not bridge command or menu enablement through `FocusedValue` or `.focusedSceneValue(...)` when plain snapshot data injection is sufficient.

Use focus-coupled command state only when macOS requires it and the path has been validated to avoid multiple updates in one frame.

## Geometry persistence must ignore the first inspector measurement

When persisting geometry from `.onGeometryChange(...)` into `@AppStorage`, skip the first startup measurement for focus-bearing chrome such as the inspector. Writing persisted layout back during the initial presentation can create another same-frame update loop.

## Validation before commit

For any change that touches `.inspector`, `.searchable`, `@FocusState`, `FocusedValue`, `@SceneStorage`, `@AppStorage`, or startup presentation state in Harness Monitor:

- Run the smallest macOS build lane that covers the change.
- Launch the app at least twice through the XcodeBuildMCP or `xcodebuild` path.
- Check the unified log for `FocusedValue update tried to update multiple times per frame`.
- Do not commit while a fresh launch still emits that fault.
