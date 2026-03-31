---
description: SwiftUI state management rules for the AI Harness macOS app
globs: apps/harness-macos/Sources/**/*.swift
---

# SwiftUI state management

## @Bindable vs let for @Observable stores

Use `let store: HarnessStore` by default. Only use `@Bindable var store` when the view creates `$store.property` bindings (TextField text:, Picker selection:, sheet isPresented:, etc.). With @Observable, `let` still tracks property access for observation - @Bindable is only needed for the dollar-sign binding syntax.

Currently only two views use @Bindable:
- ContentView ($store.showConfirmation)
- SidebarSessionList ($store.searchText)

## @State must be private

Every @State property must be marked private. This prevents passed values from being declared as @State (which ignores parent updates).

## No closures stored in view structs

Never store closure properties (let onTap: () -> Void, let action: () -> Void) in view structs. Closures prevent SwiftUI from comparing views during diffing, causing unnecessary body re-evaluations.

Instead, pass the store and have the child call methods directly. For HarnessAsyncActionButton, use the StoreAction enum:

```swift
// correct
HarnessAsyncActionButton(
  title: "Start Daemon",
  ...,
  store: store,
  storeAction: .startDaemon
)

// wrong - closure prevents diffing
HarnessAsyncActionButton(title: "Start Daemon", ...) {
  await store.startDaemon()
}
```

New store actions require adding a case to `HarnessAsyncActionButton.StoreAction` and a dispatch entry in `performAction()`.

## Prefer owned @State over @Binding + closure combos

When a child view has @Binding for draft/form state plus a closure to submit it, consider whether the child can own its own @State and call store methods directly. This eliminates bindings, closures, and sync logic from the parent.

Example: AgentInspectorCard owns its signal draft fields (@State signalCommand, signalMessage, signalActionHint) and calls store.sendSignal() directly, rather than receiving 3 @Binding props + a sendSignal closure from InspectorColumnView.

Only use @Binding when the parent genuinely needs to read or coordinate the child's draft state.

## @Binding only for mutation

Use @Binding only when a child view modifies the parent's state (Toggle isOn:, TextField text:, Picker selection:). For read-only values, use let. For values where the child reacts to changes, use var + .onChange(of:).
