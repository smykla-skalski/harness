---
name: swiftui-platform-rules
description: macOS and iOS platform conventions plus XCUITest reliability rules. Covers menu bar ordering, window chrome (traffic lights, corner radius, minimum size), toolbar placements, sidebar width, Settings scene, dock/notifications, standard keyboard shortcuts (Cmd+N/O/S/W/Q/Z/F/,/M), iOS tab bar and safe areas, gestures, and XCUITest patterns (three-layer animation suppression, .firstMatch required, coordinate taps for non-hittable elements, single-launch test design, dragUp scroll helper, no Section-level accessibilityIdentifier). Invoke when writing or reviewing macOS window/menu/toolbar/settings code, platform-convention questions, iOS surfaces, or XCUITest tests in HarnessMonitorUITests.
---

# Platform conventions and UI test reliability

Native platform conventions for macOS (current) and iOS (aspirational) plus XCUITest patterns that keep the test suite fast and reliable.

## macOS platform rules

### Menu bar

- Required menus in order: App menu, File, Edit, View, Window, Help.
- App menu: About, Settings (Cmd+,), Hide (Cmd+H), Hide Others (Cmd+Opt+H), Quit (Cmd+Q).
- Edit menu: Undo (Cmd+Z), Redo (Cmd+Shift+Z), Cut (Cmd+X), Copy (Cmd+C), Paste (Cmd+V), Select All (Cmd+A).
- Disabled menu items are grayed out, never hidden. Hiding breaks muscle memory.
- Keyboard shortcut hints right-aligned in menu items.
- Ellipsis (...) on menu items that open a dialog. No ellipsis for immediate actions.
- Custom menus go between View and Window.
- Every action in the UI must be accessible via the menu bar.

### Windows

- Standard traffic light buttons always top-left. Never hide or replace.
- Red close button closes the window, not the app (unless single-window).
- Cmd+W closes window. Cmd+Q quits.
- Set sensible minimum window size (400x300pt floor). Use `.windowResizability(.contentMinSize)`.
- Restore window position and size on next launch.
- New windows cascade (offset 22pt down and right from previous).
- Full screen support (Ctrl+Cmd+F or green button) for document-based and media apps.
- Window corner radius: 10pt (system standard).

#### Window chrome measurements

| Element | Size |
|---|---|
| Title bar | 22pt (standard), 28pt (large title) |
| Unified toolbar | 52pt (standard), 38pt (compact) |
| Traffic light buttons | 12x12pt, 7pt from leading edge, 6pt spacing |
| Window corner radius | 10pt |
| Minimum window size | 400x300pt recommended |

### Toolbar

- SF Symbols at 13pt/regular weight. Icon + optional label.
- Standard placements: `.principal` (center), `.navigation` (leading), `.primaryAction` (trailing).
- Right-click > "Customize Toolbar" should work unless there's a reason not to.
- Separator: `Divider()` between toolbar item groups.

### Sidebar

- Width: 200-280pt default, user-resizable.
- Minimum: 200pt. Collapses entirely below minimum.
- Sidebar items: SF Symbol icon + label, 28-32pt row height.
- Toggle with keyboard shortcut.
- On macOS 26: sidebar gets automatic Liquid Glass. Don't override with opaque backgrounds.

### Settings window

- Opens with Cmd+, (always). Use `Settings` scene in SwiftUI.
- Tab-based with SF Symbol icons (General, Appearance, etc.).
- Fixed window size, non-resizable. Standard width: 500-650pt.
- Settings apply immediately. No Save/Apply/OK button.
- General tab first, Advanced last.
- "Restore Defaults" with confirmation where appropriate.

### Hover and mouse

- Hover states on all interactive elements: subtle background (5-10% opacity accent).
- Cursor changes: pointer for clickable, I-beam for text, resize for edges.
- Tooltips after 500ms hover on non-obvious controls.
- Right-click context menus on all selectable elements.

### Dock

- Badge count for pending items.
- Right-click dock menu: recent items, quick actions.
- Progress indication on dock icon for long operations.
- Dock bounce only for events needing immediate attention.

### Notifications

- Use `UNUserNotificationCenter`.
- Default to banner (auto-dismiss ~5 seconds). Alert only for genuinely urgent information.
- Don't spam. Respect notification settings.
- Up to 4 actions in expanded notification.

### Drag and drop (platform conventions)

- Support drag and drop between windows and apps where it makes sense.
- Visual feedback: lift with shadow (1.05x scale), reduce source opacity (0.5).
- Drop target: background color change or dashed border.
- Cancel: Escape key returns to source with spring animation.
- Minimum drop zone: 32x32pt.

For SwiftUI `.draggable` / `.dropDestination` API rules, see the `swiftui-api-patterns` skill.

### Standard keyboard shortcuts

These shortcuts must work in any macOS app:

| Action | Shortcut |
|---|---|
| New | Cmd+N |
| Open | Cmd+O |
| Save | Cmd+S |
| Close | Cmd+W |
| Quit | Cmd+Q |
| Undo | Cmd+Z |
| Redo | Cmd+Shift+Z |
| Cut/Copy/Paste | Cmd+X/C/V |
| Select All | Cmd+A |
| Find | Cmd+F |
| Settings | Cmd+, |
| Minimize | Cmd+M |
| Full Screen | Ctrl+Cmd+F |
| Hide | Cmd+H |

## iOS platform rules

These rules apply to current and future iOS apps in this repository. The Harness Monitor app is macOS-only today, so these are aspirational reference for any future iOS target.

### Safe areas

- Always respect safe areas. Interactive controls must remain within safe areas.
- Use `.ignoresSafeArea()` only for background content (images, maps, gradients).
- Bottom safe area: 34pt on Face ID devices. Don't place interactive controls within 34pt of the bottom edge.
- Status bar always visible unless in immersive content (video, photos).

### Tab bar

- Bottom of screen, always visible during in-tab navigation.
- 2-5 tabs maximum. More than 5 uses a "More" tab.
- Icon + short label for each. Filled for selected, outline for unselected.
- Active tab: accent color tint. Inactive: gray.
- Tab bar height: 49pt (83pt with home indicator on Face ID devices).
- Each tab maintains independent navigation state.

### Navigation bar

- Large title for top-level screens (`.navigationBarTitleDisplayMode(.large)`), inline for drill-down.
- Back button: system chevron + previous screen title. Never hide or replace.
- Trailing side: 1-2 action buttons maximum.
- Leading side: back button only (or close for modal presentations).
- Search: `.searchable()` modifier.

### Gestures

- Swipe from left edge navigates back. Never override this system gesture.
- Swipe actions on list rows: trailing for destructive (red), leading for positive actions.
- Full swipe triggers the first action (delete, archive).
- Maximum 3 swipe actions per side.
- Long press for context menus on selectable content.
- Pull-to-refresh: `.refreshable()` modifier for refreshable content.
- Shake to undo is a system behavior. Don't disable it.

### Touch targets

- 44x44pt minimum touch target. No exceptions.
- If the visual element is smaller, expand the hit area.
- Haptic feedback for significant interactions.
- No hover states - design for touch-first.

### Scroll behavior

- Large titles collapse on scroll (automatic with NavigationStack).
- Scroll-to-top: tapping the status bar scrolls to top. Don't interfere.
- Rubber-banding at scroll limits. Never disable.
- System manages content insets for safe areas, bars, and keyboard. Don't manually set unless custom layout.

### Launch (iOS)

- Cold launch to content: under 400ms target. Absolute max 3 seconds before watchdog kills the app.
- Launch screen matches initial screen layout (same background, layout skeleton). No logos or splash art.
- Don't show onboarding or login on every launch. Once, then straight to content.
- Restore previous state: last tab, scroll position, selection.

### Permissions (iOS)

- Never request all permissions at launch.
- Ask in context: request camera when user taps "Scan QR code".
- Explain before asking: "We need camera access to scan QR codes" then system prompt.
- If denied: inline message explaining how to enable in Settings, with direct link.
- Graceful degradation: feature unavailable but app still works.

## XCUITest speed and reliability

### Animation suppression in the test host

The app disables animations when `HARNESS_MONITOR_UI_TESTS=1` via three layers:
- SwiftUI: `.transaction { $0.disablesAnimations = true }` on root views
- AppKit: `NSAnimationContext.current.duration = 0`
- NSWindow: `.animationBehavior = .none` on every window via `didBecomeKeyNotification`

Do not add animations that bypass these layers (e.g. CADisplayLink-driven animations) without also checking the UI test environment flag.

### Always use .firstMatch

Every element query must end with `.firstMatch`. Without it, XCUITest resolves the entire accessibility hierarchy to verify uniqueness, adding seconds per query.

```swift
// correct
app.buttons["Clear Session Cache"].firstMatch

// wrong - full hierarchy scan
app.buttons["Clear Session Cache"]
```

Exception: `app.staticTexts["Statistics"]` without `.firstMatch` works for section headers because macOS SwiftUI exposes them differently and `.firstMatch` can miss them.

### Prefer .exists over waitForExistence

Use `.exists` for elements already rendered. Only use `waitForExistence(timeout:)` when genuinely waiting for something to appear (window opening, async content loading). Keep timeouts as short as possible - 2-3 seconds for post-action waits, `Self.uiTimeout` only for app launch and window creation.

### Coordinate-based taps for non-hittable elements

Elements inside custom layouts (WrapLayout, GlassEffectContainer) may exist in the accessibility tree but report `isHittable = false`. Use coordinate-based tapping via `centerCoordinate(in:for:)`.

### Escape key to dismiss dialogs

Use `app.typeKey(.escape, modifierFlags: [])` to dismiss confirmation dialogs instead of searching for and tapping the Cancel button. It avoids an extra hierarchy search.

### No Section-level accessibilityIdentifier

On macOS, `.accessibilityIdentifier` on a SwiftUI `Section` propagates to all child elements, clobbering their individual identifiers. Put identifiers on the children, not the Section.

### Sidebar item element types

macOS SwiftUI List sidebar items appear as `.button`, `.cell`, or `.radioButton` depending on the version. Use the `button(in:title:)` helper that searches all three types.

### Single-launch test design

Prefer one test method that launches the app once and tests multiple related assertions sequentially. Each `launch(mode:)` call adds 8-10 seconds of overhead. Group related assertions (navigation, scrolling, button verification, confirmation dialogs) into a single test flow.

### Scroll with dragUp

Use the `dragUp(in:element:distanceRatio:)` helper anchored on a visible element inside the scroll region. `element.scroll(byDeltaX:deltaY:)` often targets the wrong scroll view. The `distanceRatio` of 3.0 works well for scrolling past a full section.

### XCUITest references

- [Jesse Squires - Xcode UI Testing Reliability Tips](https://www.jessesquires.com/blog/2021/03/17/xcode-ui-testing-reliability-tips/) - animation disabling, layer.speed acceleration, timeout management
- [Antoine van der Lee - Disable Animations Using Transactions](https://www.avanderlee.com/swiftui/disable-animations-transactions/) - .transaction modifier replacing deprecated .animation(nil)
- [objc.io - Transactions and Animations](https://www.objc.io/blog/2021/11/25/transactions-and-animations/) - disablesAnimations only kills implicit animations, not explicit
- [Fat Bob Man - Disable Transition Animations](https://fatbobman.com/en/snippet/disable-transition-animations-for-sheet-and-navigationstack-in-swiftui/) - withTransaction for instant sheet/navigation, scope isolation
- [Alex Ilyenko - Waits in XCUITest](https://alexilyenko.github.io/xcuitest-waiting/) - XCTWaiter, expectation types, explicit vs implicit waits
- [Pol Piella - Configuring UI Tests with Launch Arguments](https://www.polpiella.dev/configuring-ui-tests-with-launch-arguments/) - ProcessInfo.processInfo.arguments pattern

## Research backing

Rationale for these rules lives under `apps/harness-monitor-macos/docs/research/`:

- `ux/01-apple-hig-principles.md` - HIG principles for macOS and iOS
- `xcuitest-speed.md` - XCUITest reliability and speed investigation report
