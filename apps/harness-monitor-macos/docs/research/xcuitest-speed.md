# XCUITest speed optimization for macOS SwiftUI apps

## Problem

UI tests had multi-second delays between actions. After opening the preferences window and clicking a sidebar item, there was a 3-5 second pause before the mouse moved. Total test runtime was 36+ seconds for a single test covering navigation, scrolling, and button verification.

## Root causes

### 1. XCUITest idle-waiting between actions

XCUITest waits for the app to become "idle" before executing each interaction. "Idle" means no pending animations and no in-flight `CATransaction` commits. Every SwiftUI animation (implicit transitions, sheet presentations, NavigationSplitView column animations) forces a delay until completion.

Jesse Squires documents this behavior and recommends disabling or accelerating animations. His recommendation is to use `UIView.setAnimationsEnabled(false)` on iOS via launch arguments, or to accelerate animations with `window.layer.speed = 2.0` as an alternative that preserves callback timing.

Source: https://www.jessesquires.com/blog/2021/03/17/xcode-ui-testing-reliability-tips/

### 2. Accessibility hierarchy snapshot cost

Each XCUITest element query without `.firstMatch` triggers a full accessibility hierarchy traversal to verify uniqueness. On views with many elements this adds measurable time per query. Using `.firstMatch` short-circuits the search at the first match without scanning the entire tree.

This is not well documented by Apple, but the behavior is observable: queries like `app.buttons["X"]` resolve the entire hierarchy first, while `app.buttons["X"].firstMatch` stops immediately.

### 3. waitForExistence polling overhead

`waitForExistence(timeout:)` uses internal polling to check element existence. When called on elements that are already in the accessibility tree, it still has overhead from taking a snapshot before returning. The `XCTWaiter` API provides more control via `Result` enum outcomes (`.completed`, `.timedOut`, `.incorrectOrder`, `.invertedFulfillment`, `.interrupted`), and `XCTNSPredicateExpectation` is recommended for UI automation waits.

Source: https://alexilyenko.github.io/xcuitest-waiting/

## Solution: three-layer animation suppression

macOS SwiftUI apps have three independent animation systems. All three need to be suppressed for maximum test speed.

### Layer 1: SwiftUI transaction - disablesAnimations

The `.transaction` view modifier adjusts the animation context for a view subtree:

```swift
content.transaction { $0.disablesAnimations = true }
```

Applied at root views when `HARNESS_MONITOR_UI_TESTS=1`. This replaces the deprecated `.animation(nil)` modifier. As documented by Antoine van der Lee: "Any adjustments we make to the given transaction only apply to the animations used within the view containing the modifier."

An important nuance from objc.io: `disablesAnimations = true` does NOT disable all animations - it only disables implicit animations (those from `.animation()` modifiers). Explicit animations via `withAnimation {}` still run. For our case this is sufficient since we don't have explicit animations during test-relevant transitions.

The `withTransaction` approach with `Transaction(animation: .none)` plus `disablesAnimations = true` is more aggressive and suppresses both implicit and explicit animations for state changes within the closure. Fat Bob Man recommends this for sheet and NavigationStack transitions where instant presentation is desired.

Sources:
- https://www.avanderlee.com/swiftui/disable-animations-transactions/ - Transaction modifier technique, replaces deprecated .animation(nil)
- https://www.objc.io/blog/2021/11/25/transactions-and-animations/ - Technical analysis: "The flag disablesAnimations has a confusing name: it does not actually disable animations: it only disables the implicit animations"
- https://fatbobman.com/en/snippet/disable-transition-animations-for-sheet-and-navigationstack-in-swiftui/ - withTransaction pattern for instant sheet/navigation presentation, edge cases on scope isolation

### Layer 2: AppKit NSAnimationContext

```swift
NSAnimationContext.current.duration = 0
```

Zeroes out AppKit-level animations: window resizing, sheet presentation, NSView-based transitions. Only affects animations that go through `NSAnimationContext`, not Core Animation or SwiftUI.

Apple documentation (requires JS to view): https://developer.apple.com/documentation/appkit/nsanimationcontext

### Layer 3: NSWindow.animationBehavior

```swift
window.animationBehavior = .none
```

Set on `NSWindow.didBecomeKeyNotification` so every new window gets instant presentation. Without this, new windows (like the Preferences `Window` scene) animate in with a fade/scale that XCUITest waits for.

```swift
NotificationCenter.default.addObserver(
  forName: NSWindow.didBecomeKeyNotification,
  object: nil,
  queue: .main
) { notification in
  let window = notification.object as? NSWindow
  MainActor.assumeIsolated {
    window?.animationBehavior = .none
  }
}
```

Note: there is no macOS equivalent of the iOS `-UIAnimationsDisabled` launch argument. That flag sets a private UIKit property. On macOS the app must handle it explicitly.

Apple documentation (requires JS to view): https://developer.apple.com/documentation/appkit/nswindow/animationbehavior-swift.property

### Launch arguments for test configuration

Pol Piella documents the standard pattern for configuring UI test behavior via launch arguments. Arguments passed via `app.launchArguments` populate `ProcessInfo.processInfo.arguments` in the app. The pattern is: test side passes a flag, app side checks for it at init and disables animations.

```swift
// Test side
app.launchArguments = ["UITEST"]

// App side
if ProcessInfo.processInfo.arguments.contains("UITEST") {
    UIView.setAnimationsEnabled(false) // iOS only
}
```

On macOS there is no `UIView.setAnimationsEnabled` so we use the three-layer approach above instead.

Source: https://www.polpiella.dev/configuring-ui-tests-with-launch-arguments

## Test-side optimizations

### Always use .firstMatch

Avoids full hierarchy resolution:

```swift
app.buttons["Clear Session Cache"].firstMatch  // fast
app.buttons["Clear Session Cache"]              // slow - scans everything
```

Exception observed: `app.staticTexts["Statistics"]` without `.firstMatch` works for macOS SwiftUI Form section headers. With `.firstMatch`, the header text element is sometimes missed because the accessibility tree exposes it through a different query path.

### Use .exists before waitForExistence

Skip polling when the element is already rendered:

```swift
if databaseSidebarItem.exists {
  databaseSidebarItem.tap()  // instant
}
```

### Coordinate-based taps for custom layouts

Elements inside custom `Layout` implementations (like `HarnessMonitorWrapLayout`) exist in the accessibility tree but may report `isHittable = false`. Resolve via coordinate:

```swift
guard let coordinate = centerCoordinate(in: app, for: element) else { return }
coordinate.tap()
```

### Escape key to dismiss dialogs

`app.typeKey(.escape, modifierFlags: [])` avoids the hierarchy search that finding and tapping a Cancel button requires.

### Single-launch tests

Each `XCUIApplication.launch()` takes 8-10 seconds. Group related assertions into one test method that launches once and tests navigation, scrolling, buttons, and confirmations sequentially.

## macOS-specific findings

### Section accessibilityIdentifier clobbers children

On macOS 26, `.accessibilityIdentifier` on a SwiftUI `Section` propagates to ALL child elements, overriding their individual identifiers. All 6 buttons inside a Section got the Section's identifier. Fix: put identifiers on children, not the Section.

### Sidebar item element types vary

macOS SwiftUI `List` sidebar items appear as `.button`, `.cell`, or `.radioButton` depending on the macOS version. The `button(in:title:)` helper that checks all three types is the reliable approach.

### Swift 6.2 and NotificationCenter closures

`NSWindow.animationBehavior` is main-actor-isolated. In Swift 6.2, the NotificationCenter closure can't be `@MainActor` (type mismatch) and can't capture `notification` into `MainActor.assumeIsolated` (sending diagnostic). Fix: extract the window from the notification into a local `let` before entering `MainActor.assumeIsolated`.

## Results

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| Total test time | 36s | 29s | -19% |
| Settings window open delay | 3-5s visible | <1s | eliminated |
| Confirmation dialog cycle | ~8s each | ~3s each | -62% |

The remaining 29 seconds breaks down as: app launch ~8s, main window render ~3s, preferences window open + navigate ~4s, 3 confirmation cycles ~9s, scroll + verify ~5s. The launch and main window render are irreducible overhead from XCUITest's process management.

## References

1. Jesse Squires - Xcode UI Testing Reliability Tips (2021-03-17)
   https://www.jessesquires.com/blog/2021/03/17/xcode-ui-testing-reliability-tips/
   Covers: animation disabling via launch args, window.layer.speed acceleration, timeout management

2. Antoine van der Lee - Disable Animations in SwiftUI Using Transactions
   https://www.avanderlee.com/swiftui/disable-animations-transactions/
   Covers: .transaction modifier replacing deprecated .animation(nil), scope of effect

3. objc.io - Transactions and Animations (2021-11-25)
   https://www.objc.io/blog/2021/11/25/transactions-and-animations/
   Covers: how transactions propagate, disablesAnimations only kills implicit animations, explicit animation override behavior

4. Fat Bob Man - Disable Transition Animations for Sheet and NavigationStack
   https://fatbobman.com/en/snippet/disable-transition-animations-for-sheet-and-navigationstack-in-swiftui/
   Covers: withTransaction pattern, scope isolation edge cases, sheet + navigation instant presentation

5. Alex Ilyenko - Waits in XCUITest
   https://alexilyenko.github.io/xcuitest-waiting/
   Covers: XCTWaiter API, expectation types (KVO, notification, predicate), explicit vs implicit waits

6. Pol Piella - Configuring UI Tests with Launch Arguments
   https://www.polpiella.dev/configuring-ui-tests-with-launch-arguments
   Covers: ProcessInfo.processInfo.arguments pattern, UIView.setAnimationsEnabled in test host, locale configuration

7. Apple - NSAnimationContext
   https://developer.apple.com/documentation/appkit/nsanimationcontext
   Covers: animation context duration, grouping, implicit animation control (requires JS to render)

8. Apple - NSWindow.animationBehavior
   https://developer.apple.com/documentation/appkit/nswindow/animationbehavior-swift.property
   Covers: window presentation animation control (requires JS to render)

9. Apple - Transaction (SwiftUI)
   https://developer.apple.com/documentation/swiftui/transaction
   Covers: state-processing update context, disablesAnimations property (requires JS to render)
