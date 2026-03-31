---
globs: "**/*.swift"
description: "Accessibility requirements for macOS and iOS apps. Non-negotiable - every feature ships accessible."
---

# Accessibility requirements

Every feature ships accessible or it doesn't ship. These are hard requirements, not suggestions.

## VoiceOver

- Every interactive element has `.accessibilityLabel()`. Icon-only buttons always need one.
- Labels are concise (2-5 words), start with capital, omit control type ("Save" not "Save button").
- Set `.accessibilityHint()` when the action isn't obvious from the label.
- Set `.accessibilityValue()` for stateful controls (toggles, sliders, progress).
- Decorative images use `.accessibilityHidden(true)`.
- Group related non-interactive elements with `.accessibilityElement(children: .combine)`.
- Swipe actions in lists must have VoiceOver alternatives via `.accessibilityAction()`.
- Announce dynamic content changes with `AccessibilityNotification.Announcement("message").post()`.
- Announce errors immediately with the error content, not just "error occurred".
- Use `.accessibilityAddTraits(.isHeader)` on section/screen titles.
- Reading order follows visual layout. Fix with `.accessibilitySortPriority()` if needed.

## Dynamic Type

- All text uses text styles (`.font(.body)`), never hardcoded sizes (`.font(.system(size: 16))`).
- Use `@ScaledMetric` for non-text dimensions that should scale (icon sizes, spacing, container heights).
- Layouts must reflow at accessibility sizes: HStack becomes VStack. Use `@Environment(\.dynamicTypeSize)` with `.isAccessibilitySize` or `ViewThatFits`.
- Text that truncates at AX3+ is a bug. Fix the layout.
- Never clamp text below the user's chosen size.
- Test at: default (Large), XXL (largest non-accessibility), AX3 (mid-range), AX5 (largest).

## Color and contrast

- WCAG 2.1 AA minimum: 4.5:1 for normal text (< 18pt), 3:1 for large text (18pt+ or 14pt+ bold), 3:1 for UI components (icons, borders, focus rings).
- Aim for AAA: 7:1 normal text, 4.5:1 large text.
- Never convey information by color alone. Always pair with icon, text, or pattern.
- Status indicators: color + icon + text label. Not just a colored dot.
- Error fields: red border + error icon + error message text.
- Every custom color needs light AND dark variants meeting contrast requirements.
- Test with Accessibility Inspector for contrast ratios.

## Reduce Motion

- Check `@Environment(\.accessibilityReduceMotion)`.
- Replace slide/spring/bounce with crossfade or instant when enabled.
- Disable parallax and auto-playing animations.
- Keep essential state feedback (progress bars, selection highlights, opacity changes).
- Reduce Motion does not mean no animation - simple fades are fine.

## Reduce Transparency

- Check `@Environment(\.accessibilityReduceTransparency)`.
- Every translucent surface needs a solid-color fallback.
- Glass effects (Liquid Glass) need opaque alternatives.
- Blur overlays need solid-color backgrounds when transparency is reduced.

## Increase Contrast

- Check `@Environment(\.colorSchemeContrast)` for `.increased`.
- Thicker borders (1pt -> 2pt), higher opacity separators, more opaque backgrounds.
- System colors auto-provide high-contrast variants. Custom colors must too (asset catalog).

## Keyboard navigation (macOS)

- Every interactive element reachable via Tab key.
- Tab order follows visual layout: top-to-bottom, leading-to-trailing.
- Arrow keys navigate within groups (lists, grids, segmented controls).
- Visible focus ring on focused element. Never hide the system focus ring.
- Return/Enter activates the default/primary action.
- Escape dismisses modals, sheets, popovers.
- Space toggles checkboxes and buttons.
- No focus traps - user can always Tab out.

## Target sizes

- iOS: 44x44pt minimum touch target. No exceptions.
- macOS: 24x24pt minimum click target with 4pt+ spacing between targets.
- If visual element is smaller, expand hit area with `.contentShape(Rectangle())` and a larger `.frame()`.
- No tiny close buttons (12x12pt X is a violation).

## Cognitive accessibility

- Simple, clear language. No jargon in user-facing text.
- Consistent navigation across the entire app.
- No time pressure for decisions (no auto-advancing, no countdown timers).
- Undo for all destructive actions.
- Don't clear forms on error.

## Environment values reference

| Value | Type | Check for |
|---|---|---|
| `\.accessibilityReduceMotion` | Bool | Replace animations |
| `\.accessibilityReduceTransparency` | Bool | Opaque fallbacks |
| `\.colorSchemeContrast` | ColorSchemeContrast | `.increased` = boost contrast |
| `\.legibilityWeight` | LegibilityWeight | `.bold` = heavier weights |
| `\.dynamicTypeSize` | DynamicTypeSize | Layout adaptation |
| `\.accessibilityDifferentiateWithoutColor` | Bool | Don't rely on color alone |
