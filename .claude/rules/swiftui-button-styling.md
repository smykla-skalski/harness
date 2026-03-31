---
description: SwiftUI button styling rules for the AI Harness macOS app
globs: apps/harness-macos/Sources/**/*.swift
---

# SwiftUI button styling

## Never use .buttonStyle(.plain)

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

## Button styles must conform to ButtonStyle

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

## No redundant .contentShape() on styled buttons

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

## Use native glass styles for standard buttons

Action buttons use `.glass` or `.glassProminent` via `.harnessActionButtonStyle()`. Don't create custom backgrounds or overlays that replicate what the native glass styles provide.

Thin ViewModifier wrappers that bundle `.buttonStyle(.glass)` + `.tint()` are fine - they add convenience without fighting the system.
