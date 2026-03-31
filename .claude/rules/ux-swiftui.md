---
globs: "**/*.swift"
description: "SwiftUI code patterns, state management, navigation, performance, and anti-patterns for macOS and iOS apps."
---

# SwiftUI rules

## State management

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
- @State is private. Never pass @State between unrelated views.
- With @Observable, no property wrapper needed on the consuming view for read-only (just `var viewModel: ViewModel`). Use `@State` for owned instances.
- Don't put closures or computed values in @State.
- Don't store large data in @State.

## View composition

- Extract subviews when body exceeds ~40 lines or a layout pattern appears 2+ times.
- Name views descriptively: `SessionHeaderCard`, not `Header`.
- Pass data as init parameters. Use @Binding only for write access.
- Create custom ViewModifiers for repeated modifier chains.
- Prefer value types (structs) for view models when possible.

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

## Performance

- @Observable only re-evaluates when read properties change. Prefer over ObservableObject.
- No network calls, disk I/O, or heavy computation in view body.
- Use `.task` for async work tied to view lifecycle (auto-cancels on disappear).
- Use `.task(id:)` to cancel and restart when input changes (search debouncing).
- Image loading: use AsyncImage with placeholder. Downsample to display size.
- Don't use GeometryReader inside scrollable content.
- 60fps minimum during scroll. Avoid shadows with large blur radius on every cell.

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
