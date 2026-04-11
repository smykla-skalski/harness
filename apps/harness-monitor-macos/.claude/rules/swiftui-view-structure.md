---
description: SwiftUI view composition and structure rules for the Harness Monitor macOS app
globs: apps/harness-monitor-macos/Sources/**/*.swift
---

# SwiftUI view structure

## Views over free functions

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

## ForEach identity

Use offset-based identity for collections where duplicates are possible (strings, computed values). Never use `id: \.self` on String arrays.

```swift
// correct
ForEach(Array(values.enumerated()), id: \.offset) { _, value in ... }

// wrong - duplicate strings break identity
ForEach(values, id: \.self) { value in ... }
```

For model types, ensure Identifiable IDs are truly unique. Composite IDs like "title:value" can collide.

## No identity-breaking modifier branches

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

## @ViewBuilder annotation

Only use @ViewBuilder when the function body contains multiple expressions or conditional branches. Single-expression functions returning a view don't need it.

## No unnecessary container wrappers

Don't wrap a single child in ZStack or Group just to apply modifiers. Apply modifiers directly on the content.

## Accessibility probe modifiers

Use single code paths for optional accessibility labels/values. Apply `.accessibilityLabel("")` and `.accessibilityValue("")` unconditionally with empty-string fallbacks rather than branching on optionals. Empty strings are no-ops for VoiceOver.

## Remove dead view code

Views defined but never instantiated should be removed. Unused accessibility identifier constants should be removed with them.
