---
name: swiftui-api-patterns
description: SwiftUI API usage rules for the Harness Monitor macOS app. Covers state wrappers (@State/@Binding/@Observable/@Bindable), view composition (structs over free functions, @ViewBuilder, modifier branches, ForEach identity), Picker/selection identity, button styles (.glass/.glassProminent, no .plain, ButtonStyle conformance, AccentColor), drag-and-drop (.draggable/.dropDestination, DragSession.Phase), navigation, lists, animations, layout, keyboard/focus, window management, commands, and anti-patterns. Invoke when writing or reviewing SwiftUI view structs, view state, selection controls, buttons, drag-drop interactions, navigation, or any SwiftUI-specific API usage in apps/harness-monitor-macos/Sources.
---

# SwiftUI API patterns

How SwiftUI APIs are used in the Harness Monitor macOS app. Hard rules learned from multiple review passes.

## State management

### State wrappers reference

| Wrapper | Use when |
|---|---|
| `@State` | View owns simple value types (Bool, String, Int, enum) |
| `@Binding` | Child needs read-write access to parent's state |
| `@Observable` (macro) | Preferred over ObservableObject for new code (iOS 17+/macOS 14+) |
| `@Environment` | System values or injected dependencies |
| `@AppStorage` | Persistent preferences (small values only) |
| `@SceneStorage` | Per-window state restoration |
| `@FocusState` | Keyboard/focus management |

- State lives at the lowest common ancestor of views that need it.
- Pass state down via parameters, events up via closures.
- With @Observable, no property wrapper needed on the consuming view for read-only (just `var viewModel: ViewModel`). Use `@State` for owned instances.
- Don't store large data in @State.

### @Bindable vs let for @Observable stores

Use `let store: HarnessStore` by default. Only use `@Bindable var store` when the view creates `$store.property` bindings (TextField text:, Picker selection:, sheet isPresented:, etc.). With @Observable, `let` still tracks property access for observation - @Bindable is only needed for the dollar-sign binding syntax.

Currently only two views use @Bindable:
- ContentView ($store.showConfirmation)
- SidebarSessionList ($store.searchText)

### @State must be private

Every @State property must be marked private. This prevents passed values from being declared as @State (which ignores parent updates).

### No closures stored in view structs

Never store closure properties (`let onTap: () -> Void`, `let action: () -> Void`) in view structs. Closures prevent SwiftUI from comparing views during diffing, causing unnecessary body re-evaluations. When closures exist at multiple levels (parent -> child -> grandchild), any state change at the top cascades through the entire tree because none of the intermediate views can be skipped.

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

For toolbar items that need environment values like `openWindow`, read `@Environment(\.openWindow)` directly in the toolbar view instead of passing a closure from the parent. This avoids a closure property on the intermediate view and lets SwiftUI compare it.

```swift
// correct - reads environment directly
struct InspectorToolbarActions: ToolbarContent {
  let store: HarnessMonitorStore
  @Environment(\.openWindow) private var openWindow

  var body: some ToolbarContent {
    Button { openWindow(id: HarnessMonitorWindowID.preferences) } label: { ... }
  }
}

// wrong - closure passed from parent
struct InspectorToolbarActions: ToolbarContent {
  let openPreferences: () -> Void
  var body: some ToolbarContent {
    Button(action: openPreferences) { ... }
  }
}
```

### Prefer owned @State over @Binding + closure combos

When a child view has @Binding for draft/form state plus a closure to submit it, consider whether the child can own its own @State and call store methods directly. This eliminates bindings, closures, and sync logic from the parent.

Example: AgentInspectorCard owns its signal draft fields (@State signalCommand, signalMessage, signalActionHint) and calls store.sendSignal() directly, rather than receiving 3 @Binding props + a sendSignal closure from InspectorColumnView.

Only use @Binding when the parent genuinely needs to read or coordinate the child's draft state.

### @Binding only for mutation

Use @Binding only when a child view modifies the parent's state (Toggle isOn:, TextField text:, Picker selection:). For read-only values, use let. For values where the child reacts to changes, use var + .onChange(of:).

## View composition

### Views over free functions

Functions returning `some View` cannot be skipped by SwiftUI's diffing. Extract reusable view content into struct views so SwiftUI can skip body evaluation when inputs haven't changed.

```swift
// correct - diffable
struct HarnessActionHeader: View {
  let title: String
  let subtitle: String
  var body: some View { ... }
}

// wrong - re-evaluates every parent redraw
func harnessActionHeader(title: String, subtitle: String) -> some View { ... }
```

### Subview extraction

- Extract subviews when body exceeds ~40 lines or a layout pattern appears 2+ times.
- Name views descriptively: `SessionHeaderCard`, not `Header`.
- Pass data as init parameters. Use @Binding only for write access.
- Create custom ViewModifiers for repeated modifier chains.
- Prefer value types (structs) for view models when possible.

### ForEach identity

Use offset-based identity for collections where duplicates are possible (strings, computed values). Never use `id: \.self` on String arrays.

```swift
// correct
ForEach(Array(values.enumerated()), id: \.offset) { _, value in ... }

// wrong - duplicate strings break identity
ForEach(values, id: \.self) { value in ... }
```

For model types, ensure Identifiable IDs are truly unique. Composite IDs like "title:value" can collide.

### No identity-breaking modifier branches

ViewModifier.body must not use if/else that produces different return types when the condition can change at runtime. Use ternaries on modifier parameters instead.

```swift
// correct - single code path
content
  .buttonStyle(.glass)
  .tint(isSelected ? HarnessTheme.accent : HarnessTheme.ink)

// wrong - different return types destroy identity
if isSelected {
  content.buttonStyle(.glassProminent).tint(HarnessTheme.accent)
} else {
  content.buttonStyle(.glass).tint(HarnessTheme.ink)
}
```

Exception: branches on `let` constants that never change during the view's lifetime (like enum Variant) are safe since identity never flips.

### @ViewBuilder annotation

Only use @ViewBuilder when the function body contains multiple expressions or conditional branches. Single-expression functions returning a view don't need it.

### No unnecessary container wrappers

Don't wrap a single child in ZStack or Group just to apply modifiers. Apply modifiers directly on the content.

### Accessibility probe modifiers

Use single code paths for optional accessibility labels/values. Apply `.accessibilityLabel("")` and `.accessibilityValue("")` unconditionally with empty-string fallbacks rather than branching on optionals. Empty strings are no-ops for VoiceOver.

### Remove dead view code

Views defined but never instantiated should be removed. Unused accessibility identifier constants should be removed with them.

## Selection identity

### Bound selections must have a rendered tag

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

### Clamp dynamic selections before render

For option sets derived from session-scoped data, validate selection synchronously in the binding getter, store getter, or parent state before the control renders.

Do not rely on `.task(id:)`, `.onAppear`, or `.onChange` to repair a stale selection after render. SwiftUI validates the picker selection while building the current body, so post-render repair still logs invalid selection warnings.

### Reset state at session boundaries

When switching sessions, agents, tasks, or any parent context that changes the valid option set, either:

- derive the selection from the current context every render, or
- reset the stateful child view with a stable context identity such as `.id(selectedSessionID)`.

Do not carry local `@State` or store-backed selection from one session into another without checking it against the new session's options.

Avoid random identity resets like `.id(UUID())`. They hide state bugs and destroy useful view identity. Use a stable ID only when the local state is genuinely scoped to that parent context.

### Harness Monitor inspector fallback order

For inspector actor pickers and action senders:

- First keep the previously selected actor only if it exists in the current session detail.
- Then fall back to the current session leader only if that leader exists in the current session detail.
- Then fall back to the first current agent that can receive the action.
- Otherwise return nil, disable the action, and render a clear empty state.

If an inactive or missing leader must remain visible for explanation, render a disabled option with the same tag. Never bind to a missing leader ID without rendering a matching tag.

### Selection regression coverage

Any fix for `Picker: the selection ... is invalid and does not have an associated tag` must include a regression that creates stale selection state from a previous session and proves the current session does not bind controls or actions to stale IDs.

Prefer store-level tests for selection normalization and action target derivation. Add UI tests only when the bug depends on view identity or AppKit/SwiftUI runtime behavior that the store cannot cover.

## Button styling

### Never use .buttonStyle(.plain)

`.plain` strips all native button behavior: hover highlight, press feedback, accessibility affordances, and Liquid Glass integration. There is no valid use case for it in this app.

- For compact inline buttons (icon buttons, delete actions), use `.borderless`
- For card-style tappable regions, use a proper `ButtonStyle` conformance
- For standard actions, use `.glass` or `.glassProminent`

```swift
// correct
.buttonStyle(.borderless)
.buttonStyle(.glass)
.buttonStyle(.glassProminent)
.buttonStyle(InteractiveCardButtonStyle(...))

// wrong - kills all native feedback
.buttonStyle(.plain)
```

### Button styles must conform to ButtonStyle

When custom press/hover behavior is needed, create a struct conforming to `ButtonStyle` and implement `makeBody(configuration:)`. Never use a `ViewModifier` that applies `.buttonStyle(.plain)` and reimplements feedback by hand.

```swift
// correct - proper ButtonStyle with native integration
private struct InteractiveCardButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .opacity(configuration.isPressed ? 0.85 : 1)
  }
}

// wrong - ViewModifier faking a button style
private struct CardModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .buttonStyle(.plain)
      .background { RoundedRectangle(...) }
  }
}
```

### No redundant .contentShape() on styled buttons

When a `ButtonStyle` defines its own `.contentShape()`, call sites must not add another one. Duplicate content shapes create confusion about which one defines the tap area.

When using `.buttonBorderShape()`, don't also add `.contentShape()` with the same radius - the border shape already defines the hit region.

```swift
// correct - style owns the content shape
Button { ... } label: { ... }
  .harnessInteractiveCardButtonStyle()

// wrong - redundant with the style's built-in shape
Button { ... } label: { ... }
  .harnessInteractiveCardButtonStyle()
  .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
```

### Use native glass styles for standard buttons

Action buttons use `.glass` or `.glassProminent` via `.harnessActionButtonStyle()`. Don't create custom backgrounds or overlays that replicate what the native glass styles provide.

Thin ViewModifier wrappers that bundle `.buttonStyle(.glass)` + `.tint()` are fine - they add convenience without fighting the system.

### AccentColor asset required for .glassProminent

`.glassProminent` reads the AppKit accent color (asset catalog `AccentColor`), NOT the SwiftUI `.tint()` environment. Without an `AccentColor.colorset`, `.glassProminent` falls back to the macOS system accent (user-configurable, often red on "Multicolor" default). The `AccentColor.colorset` must match `HarnessAccent` values so both resolution paths agree.

The SwiftUI `.tint(HarnessTheme.accent)` on the root view only covers `.glass` (bordered) buttons. `.glassProminent` (filled) buttons require the asset catalog entry.

### Use .glassProminent for selected/active states

For toggle/chip/segmented controls, use `.glassProminent` for the selected state and `.glass` for unselected. This matches the Liquid Glass design language where prominence = selection.

For tinted action buttons (`.orange`, `.red`), prefer `.glassProminent` (opaque fill) over `.glass` (translucent). The opaque fill gives the system enough room to pick a high-contrast text color.

### System colors for button tints

Glass buttons derive background appearance and text contrast from the `.tint()` color. Custom asset colors from `HarnessTheme` are not calibrated for glass contrast.

For accent-colored buttons, pass `nil` tint so the button inherits from the environment and AccentColor asset. Never use `Color.accentColor` - it resolves to the macOS system accent, not the app's custom accent.

For non-accent buttons, use system semantic colors:
- **Primary/accent**: `nil` (inherit from environment + AccentColor asset)
- **Neutral/secondary**: `.secondary` (translucent gray glass)
- **Destructive**: `.red`
- **Warning**: `.orange`
- **Success**: `.green`

`HarnessTheme` colors stay valid for non-button UI: status badges, indicator bars, text foreground, decorative accents.

```swift
// correct - nil inherits app accent, system colors for overrides
.harnessActionButtonStyle(variant: .prominent)
.harnessActionButtonStyle(variant: .prominent, tint: .orange)
.harnessActionButtonStyle(variant: .bordered, tint: .secondary)
.harnessActionButtonStyle(variant: .bordered, tint: .red)

// wrong - .accentColor is the macOS system accent, not the app's
.tint(.accentColor)

// wrong - custom asset colors fight glass contrast
.tint(HarnessTheme.accent)
.tint(HarnessTheme.ink)
.tint(HarnessTheme.danger)
```

## Drag and drop

These rules apply to `.draggable`, `.dropDestination`, `onDragSessionUpdated`, and related drag-drop APIs in the Harness Monitor macOS app. They lock in patterns learned from a drag-drop system rewrite that fixed silent drop rejection, animation snap-backs, and identity-breaking modifier branches.

### Unconditional `.draggable`

Never wrap `.draggable` in a `@ViewBuilder if/else`. Conditional drag produces `_ConditionalContent<Draggable, Self>`, which tears down the internal drag gesture state every time the condition flips, and violates the "no identity-breaking modifier branches" rule under view structure.

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

### Drop rejections must surface user-visible feedback

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

### `DragSession.Phase` switches must be exhaustive

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

### Drag-state animations must be unconditional

Never write `.animation(isDragging ? .someAnimation : nil, value: isDragging)`. A nil animation cancels `.transition(...)` on removal, so overlays snap away instead of fading. Use a single non-nil animation:

```swift
// correct - overlay fades both in and out
.animation(.easeOut(duration: 0.10), value: isDragging)

// wrong - overlay snaps out because animation is nil when going false
.animation(isDragging ? .easeOut(duration: 0.10) : nil, value: isDragging)
```

Do not stack an explicit `withAnimation { ... }` inside the drag session update handler on top of an outer `.animation(_:value:)`. Pick one animation source. The outer `.animation(_:value:)` is usually the right choice because it applies uniformly to every derived visual (overlay, border, opacity, scale).

### Click + drag cards use `Button` + `harnessInteractiveCardButtonStyle`

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

Benefits of the Button pattern: native press/hover/focus rings, keyboard activation (Return/Space), automatic `.isButton` accessibility trait, automatic label combination, and consistent visual treatment with other card surfaces.

The `InteractiveCardButtonStyle` defined in `HarnessMonitorInteractiveCardChrome.swift` already sets the content shape internally; don't add another `.contentShape(...)` to a view that has this style.

### One `DragSession.Phase?` snapshot, not multiple flags

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

### Do not reset unrelated state in drag-session cleanup

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

### `onDragSessionUpdated` is macOS-only

`onDragSessionUpdated` and `DragSession` are `@available(macOS 26.0, *)` with `@available(iOS, unavailable)` / `@available(tvOS, unavailable)` / `@available(watchOS, unavailable)`. If you ever share drag code with an iOS/visionOS target, gate it with `#if os(macOS)`. The Harness Monitor app is macOS-only today, so no gate is needed.

### Do not react to external state changes during an active drag

Do not use `.onChange(of: isDragEnabled)` or similar to tear down drag state mid-gesture. External state may flip while the user is dragging (e.g. task status transitions), and ripping drag state out from under an in-flight gesture produces a visual snap and leaves the drag session in an inconsistent state. Let the natural `DragSession.Phase` transitions drive cleanup.

## Navigation

- Use `NavigationStack` with `navigationDestination(for:)` and value-based `NavigationLink`.
- Use `NavigationSplitView` for master-detail (macOS primary).
- Don't nest NavigationStack inside NavigationSplitView or another NavigationStack.
- Every sheet needs cancel + primary action buttons.
- Don't nest sheets (one level only).
- Always provide a clear "no selection" state for NavigationSplitView detail pane.

## Lists

- Use `List` for 50+ items (cell recycling). `LazyVStack` for custom layouts.
- Selection: `List(items, selection: $selection)` for single/multi-select.
- Swipe actions: `.swipeActions(edge:)`. Trailing for destructive (red), leading for positive.
- Empty state: `ContentUnavailableView` with label, description, and action.
- Context menus: `.contextMenu { }` on all selectable items. Destructive at bottom with divider.

## Animations

- Explicit animation preferred: `withAnimation(.spring) { state = newValue }`.
- Always specify the `value:` parameter on `.animation()`: `.animation(.default, value: isExpanded)`.
- Use `.transition(.opacity)` for insert/remove. Combine: `.transition(.move(edge:).combined(with: .opacity))`.
- Spring for interactive: `response: 0.35, dampingFraction: 0.75`.
- Respect Reduce Motion: `@Environment(\.accessibilityReduceMotion)`.
- Haptic feedback: `.sensoryFeedback(.success, trigger:)` for significant state changes.

## Layout

- Use VStack/HStack/ZStack with explicit spacing.
- `.frame(maxWidth: .infinity)` to fill, not GeometryReader.
- `.containerRelativeFrame()` (iOS 17+) for relative sizing, not GeometryReader.
- GeometryReader: last resort only. It proposes zero size to children.
- `.safeAreaInset(edge:)` for custom toolbars/bars.
- `.ignoresSafeArea()` only for background content, never interactive elements.

## Keyboard and focus

- Use `@FocusState` for form field management.
- `.onSubmit { }` to advance to next field or submit.
- `.submitLabel(.done)` / `.submitLabel(.next)` for keyboard return key text.
- Keyboard shortcuts: `.keyboardShortcut("n", modifiers: .command)`.

## Window management (macOS)

- `WindowGroup` for main content. `Window` for auxiliary windows.
- `.defaultSize(width:height:)` and `.windowResizability(.contentMinSize)`.
- `Settings { }` scene for preferences (Cmd+, opens it).
- `MenuBarExtra` for menu bar items.
- `@AppStorage` for user preferences. Changes apply immediately, no Save button.

## Commands (macOS)

- `.commands { }` modifier on Scene for app-level commands.
- `CommandGroup(after:)` to extend standard menus.
- `CommandMenu("Name")` for custom menus.
- Every action in the UI must also be accessible via menu bar.

## Anti-patterns (never do these)

- Don't use `AnyView` (breaks diffing). Use `@ViewBuilder`, `Group`, or `some View`.
- Don't perform work in view initializers. Use `.task` or `.onAppear`.
- Don't use `.onAppear` for async work when `.task` handles cancellation.
- Don't use bare `.animation(.default)` without value parameter.
- Don't create @StateObject in a view that doesn't own the lifecycle.
- Don't use index-based ForEach for mutable collections. Use Identifiable.
- Don't force unwrap optionals in views. Handle nil gracefully.
- Don't use Timer.publish when `.task` with AsyncStream works.

## Research backing

Rationale for these rules lives under `apps/harness-monitor-macos/docs/research/ux/`:

- `05-swiftui-best-practices.md` - SwiftUI state management, view composition, navigation, anti-patterns
- `01-apple-hig-principles.md` - HIG principles applied to SwiftUI controls
