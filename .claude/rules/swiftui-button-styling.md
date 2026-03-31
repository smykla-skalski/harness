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

## AccentColor asset required for .glassProminent

`.glassProminent` reads the AppKit accent color (asset catalog `AccentColor`), NOT the SwiftUI `.tint()` environment. Without an `AccentColor.colorset`, `.glassProminent` falls back to the macOS system accent (user-configurable, often red on "Multicolor" default). The `AccentColor.colorset` must match `HarnessAccent` values so both resolution paths agree.

The SwiftUI `.tint(HarnessTheme.accent)` on the root view only covers `.glass` (bordered) buttons. `.glassProminent` (filled) buttons require the asset catalog entry.

## Use .glassProminent for selected/active states

For toggle/chip/segmented controls, use `.glassProminent` for the selected state and `.glass` for unselected. This matches the Liquid Glass design language where prominence = selection.

For tinted action buttons (`.orange`, `.red`), prefer `.glassProminent` (opaque fill) over `.glass` (translucent). The opaque fill gives the system enough room to pick a high-contrast text color.

## System colors for button tints

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
