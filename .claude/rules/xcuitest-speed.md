---
description: XCUITest speed and reliability rules for macOS UI tests
globs: apps/harness-monitor-macos/Tests/**/*.swift
---

# XCUITest speed and reliability

## Animation suppression in the test host

The app disables animations when `HARNESS_MONITOR_UI_TESTS=1` via three layers:
- SwiftUI: `.transaction { $0.disablesAnimations = true }` on root views
- AppKit: `NSAnimationContext.current.duration = 0`
- NSWindow: `.animationBehavior = .none` on every window via `didBecomeKeyNotification`

Do not add animations that bypass these layers (e.g. CADisplayLink-driven animations) without also checking the UI test environment flag.

## Always use .firstMatch

Every element query must end with `.firstMatch`. Without it, XCUITest resolves the entire accessibility hierarchy to verify uniqueness, adding seconds per query.

```swift
// correct
app.buttons["Clear Session Cache"].firstMatch

// wrong - full hierarchy scan
app.buttons["Clear Session Cache"]
```

Exception: `app.staticTexts["Statistics"]` without `.firstMatch` works for section headers because macOS SwiftUI exposes them differently and `.firstMatch` can miss them.

## Prefer .exists over waitForExistence

Use `.exists` for elements already rendered. Only use `waitForExistence(timeout:)` when genuinely waiting for something to appear (window opening, async content loading). Keep timeouts as short as possible - 2-3 seconds for post-action waits, `Self.uiTimeout` only for app launch and window creation.

## Coordinate-based taps for non-hittable elements

Elements inside custom layouts (WrapLayout, GlassEffectContainer) may exist in the accessibility tree but report `isHittable = false`. Use coordinate-based tapping via `centerCoordinate(in:for:)`.

## Escape key to dismiss dialogs

Use `app.typeKey(.escape, modifierFlags: [])` to dismiss confirmation dialogs instead of searching for and tapping the Cancel button. It avoids an extra hierarchy search.

## No Section-level accessibilityIdentifier

On macOS, `.accessibilityIdentifier` on a SwiftUI `Section` propagates to all child elements, clobbering their individual identifiers. Put identifiers on the children, not the Section.

## Sidebar item element types

macOS SwiftUI List sidebar items appear as `.button`, `.cell`, or `.radioButton` depending on the version. Use the `button(in:title:)` helper that searches all three types.

## Single-launch test design

Prefer one test method that launches the app once and tests multiple related assertions sequentially. Each `launch(mode:)` call adds 8-10 seconds of overhead. Group related assertions (navigation, scrolling, button verification, confirmation dialogs) into a single test flow.

## Scroll with dragUp

Use the `dragUp(in:element:distanceRatio:)` helper anchored on a visible element inside the scroll region. `element.scroll(byDeltaX:deltaY:)` often targets the wrong scroll view. The `distanceRatio` of 3.0 works well for scrolling past a full section.

## References

- [Jesse Squires - Xcode UI Testing Reliability Tips](https://www.jessesquires.com/blog/2021/03/17/xcode-ui-testing-reliability-tips/) - animation disabling, layer.speed acceleration, timeout management
- [Antoine van der Lee - Disable Animations Using Transactions](https://www.avanderlee.com/swiftui/disable-animations-transactions/) - .transaction modifier replacing deprecated .animation(nil)
- [objc.io - Transactions and Animations](https://www.objc.io/blog/2021/11/25/transactions-and-animations/) - disablesAnimations only kills implicit animations, not explicit
- [Fat Bob Man - Disable Transition Animations](https://fatbobman.com/en/snippet/disable-transition-animations-for-sheet-and-navigationstack-in-swiftui/) - withTransaction for instant sheet/navigation, scope isolation
- [Alex Ilyenko - Waits in XCUITest](https://alexilyenko.github.io/xcuitest-waiting/) - XCTWaiter, expectation types, explicit vs implicit waits
- [Pol Piella - Configuring UI Tests with Launch Arguments](https://www.polpiella.dev/configuring-ui-tests-with-launch-arguments/) - ProcessInfo.processInfo.arguments pattern
