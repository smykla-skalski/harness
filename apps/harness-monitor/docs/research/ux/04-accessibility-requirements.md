# Accessibility requirements - comprehensive reference

Accessibility is a first-class requirement, not an afterthought. Every feature ships accessible or it doesn't ship.

## 1. VoiceOver

### Every interactive element needs
- **accessibilityLabel**: what the element is ("Delete button", "Search field")
- **accessibilityValue**: current state ("On", "3 of 10", "Selected")
- **accessibilityHint**: what happens when activated ("Double-tap to delete this item")
- **accessibilityTraits**: .isButton, .isHeader, .isSelected, .isLink, etc.

### SwiftUI patterns

```swift
// Good: explicit label
Button(action: deleteItem) {
    Image(systemName: "trash")
}
.accessibilityLabel("Delete")
.accessibilityHint("Removes this item permanently")

// Good: combined element
HStack {
    Image(systemName: "person.fill")
    Text("John Doe")
    Text("Online")
}
.accessibilityElement(children: .combine) // reads as "John Doe, Online"

// Good: custom value
Slider(value: $volume, in: 0...100)
    .accessibilityValue("\(Int(volume)) percent")

// Good: ignore decorative elements
Image("decorative-divider")
    .accessibilityHidden(true)
```

### Grouping rules
- Use `.accessibilityElement(children: .combine)` for card-like views where individual elements don't need separate focus
- Use `.accessibilityElement(children: .contain)` when child elements need individual interaction
- Group label + value pairs so they're read as one unit
- Don't group interactive elements with non-interactive ones if it hides the interactive behavior

### Custom actions
- Swipe actions in lists need VoiceOver alternatives: `.accessibilityAction(.delete) { }`
- Multi-gesture interactions need single-tap alternatives
- Custom rotors for complex navigation patterns

### Screen reader announcements for dynamic content
```swift
// Announce state changes
AccessibilityNotification.Announcement("Item deleted").post()

// Announce after async operation
AccessibilityNotification.Announcement("Search complete. 5 results found.").post()

// Layout change (when elements appear/disappear)
AccessibilityNotification.LayoutChanged(nil).post()

// Screen change (when pushing new screen)
AccessibilityNotification.ScreenChanged(nil).post()
```

### Testing VoiceOver
- Navigate entire app with VoiceOver on
- Every interactive element should be reachable and announce clearly
- Dynamic content changes must be announced
- No orphaned focus (focus shouldn't land on invisible or irrelevant elements)
- Custom views must not be VoiceOver dead ends

## 2. Dynamic Type

### All text must scale
- Use text styles (.body, .headline, .caption, etc.), never hardcoded point sizes
- If custom font sizes needed, use `UIFontMetrics` or `@ScaledMetric`

```swift
// Good: scales automatically
Text("Hello").font(.body)

// Good: custom size that scales
@ScaledMetric(relativeTo: .body) var iconSize: CGFloat = 24

// Bad: doesn't scale
Text("Hello").font(.system(size: 16))
```

### @ScaledMetric for non-text elements
- Icon sizes: scale with adjacent text style
- Spacing that should grow with text: padding, margins
- Container minimum heights that accommodate larger text
- Avatar sizes in list rows

### Layout at accessibility sizes
- HStack must become VStack when text gets large enough
- Use `@Environment(\.dynamicTypeSize)` to detect and adapt
- Use `ViewThatFits` to automatically switch layouts
- Content must remain scrollable - never clip or hide text

```swift
// Adapts layout based on Dynamic Type
@Environment(\.dynamicTypeSize) var typeSize

var body: some View {
    if typeSize.isAccessibilitySize {
        VStack(alignment: .leading) { content }
    } else {
        HStack { content }
    }
}
```

### Size categories to test
- Default (Large)
- Extra Extra Extra Large (largest non-accessibility)
- AX1 through AX5 (accessibility sizes - increasingly large)
- Test at AX3 minimum for accessibility compliance

## 3. Color and contrast

### WCAG 2.1 requirements (AA minimum)
- Normal text (< 18pt, or < 14pt bold): 4.5:1 contrast ratio minimum
- Large text (>= 18pt, or >= 14pt bold): 3:1 contrast ratio minimum
- Non-text UI components (icons, borders, focus rings): 3:1 minimum
- Inactive/disabled controls: exempt but should still be readable

### WCAG AAA (preferred targets)
- Normal text: 7:1 contrast ratio
- Large text: 4.5:1 contrast ratio
- Graphical objects: 3:1

### Rules
- Never use color as the only means of conveying information
- Status indicators: color + icon + text label (not just a colored dot)
- Links: color + underline (not just color)
- Error fields: red border + error icon + error message text
- Charts: color + pattern/shape + label

### Testing
- Use Accessibility Inspector to verify contrast ratios
- Test in both light and dark mode
- Test with Increase Contrast enabled
- Test with color filters simulating color blindness
- Every custom color must have a light and dark variant that meets contrast requirements

## 4. Reduce Motion

### Detect and respect
```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion

// Replace animation
withAnimation(reduceMotion ? .none : .spring()) {
    showContent = true
}

// Or use cross-fade instead of slide
.transition(reduceMotion ? .opacity : .slide)
```

### What to change
- Slide transitions -> instant or cross-fade (150ms)
- Spring/bounce animations -> linear/instant
- Parallax effects -> remove entirely
- Auto-playing animations -> pause by default, play button
- Scroll-based animations -> static state
- Hero/zoom transitions -> cross-fade
- Loading spinners: keep (essential feedback), but reduce rotation speed

### What to keep even with Reduce Motion
- Progress bar advancement (informational, not decorative)
- Essential state feedback (checkbox appearing, selection highlight)
- Cursor movement in text fields
- Content appearing/disappearing (use opacity, not movement)

## 5. Reduce Transparency

### Detect and provide opaque fallbacks
```swift
@Environment(\.accessibilityReduceTransparency) var reduceTransparency

var background: some View {
    if reduceTransparency {
        Color(.systemBackground) // opaque
    } else {
        Rectangle().fill(.ultraThinMaterial) // translucent
    }
}
```

### Rules
- Every translucent surface needs a solid-color fallback
- Vibrancy effects need non-vibrant alternatives
- Glass effects (Liquid Glass) need opaque mode alternatives
- Blur overlays need solid-color backgrounds when transparency is reduced

## 6. Increase Contrast

### Detect and respond
```swift
@Environment(\.colorSchemeContrast) var contrast

var borderColor: Color {
    contrast == .increased ? .primary : .secondary
}
```

### Adjustments when Increase Contrast is enabled
- Borders: thicker (1pt -> 1.5-2pt), higher contrast color
- Separators: more opaque, darker/lighter
- Subtle backgrounds: increase tint opacity by 50-100%
- Placeholder text: darker/lighter for better visibility
- Disabled items: higher opacity (40% -> 60%)
- Focus rings: thicker, higher contrast

## 7. Bold Text

### Detect and respect
```swift
@Environment(\.legibilityWeight) var legibilityWeight

var fontWeight: Font.Weight {
    legibilityWeight == .bold ? .semibold : .regular
}
```

### Rules
- Don't override font weights when Bold Text is enabled
- System text styles automatically adjust - use them
- Custom fonts must respond to the bold text setting
- Icons may also benefit from heavier weight (use heavier SF Symbol weight)

## 8. Switch Control and Dwell Control

### Sequential navigation requirements
- All functionality reachable through sequential navigation (no hover-only interactions)
- Logical item order: left-to-right, top-to-bottom
- Grouped items: navigate group first, then items within
- Every custom gesture must have a button/tap alternative

### Rules
- No multi-finger gestures without alternative
- No timed interactions (no "hold to delete" without alternative)
- No precision-demanding interactions (small targets, exact drag positions)
- Context menus accessible through button alternative (not just long-press)

## 9. Full Keyboard Access (macOS)

### Focus management
```swift
@FocusState private var focusedField: Field?

enum Field: Hashable {
    case username, password, submit
}

TextField("Username", text: $username)
    .focused($focusedField, equals: .username)
    .onSubmit { focusedField = .password }
```

### Focus order
- Tab key moves focus forward through interactive elements
- Shift+Tab moves backward
- Order follows visual layout: left-to-right, top-to-bottom
- Don't create focus traps (user must be able to Tab out of any component)
- Skip decorative/non-interactive elements
- Group focus within modal dialogs (Tab cycles within the modal)

### Required keyboard shortcuts
- Return/Enter: activate default/primary action
- Escape: dismiss modal, sheet, popover, cancel search
- Space: toggle buttons, checkboxes
- Arrow keys: navigate within lists, grids, segmented controls, tab views
- Cmd+A: select all (in applicable contexts)
- Delete/Backspace: delete selected items

### Visible focus indicator
- System default: blue ring (don't suppress)
- Custom focus styles must be visible: 2pt+ border, contrasting color
- Focus ring must be visible in both light and dark mode
- Focus ring must meet 3:1 contrast against adjacent backgrounds

## 10. Pointer accessibility

### Minimum target sizes
- iOS: 44x44pt minimum touch target (Apple HIG hard requirement)
- macOS: 24x24pt minimum click target
- Spacing between targets: 4pt+ minimum to prevent mis-taps
- Small visual elements (12pt icon) must have expanded hit area

```swift
// Visual element smaller than hit area
Image(systemName: "xmark")
    .font(.caption)
    .frame(width: 44, height: 44) // hit area
    .contentShape(Rectangle()) // make entire frame tappable
```

### Rules
- No tiny close buttons (common violation: 12x12pt X buttons)
- No precision-demanding interactions for primary actions
- Generous spacing between destructive and non-destructive actions
- Drag handles: minimum 44x44pt
- Slider thumbs: minimum 28pt diameter visual, 44pt touch target

## 11. Cognitive accessibility

### Language
- Simple, clear language in all UI text
- No jargon in user-facing text
- Short sentences: one idea per sentence
- Active voice: "Save your file" not "Your file will be saved"
- Consistent terminology: one word for one concept

### Behavior
- Consistent navigation across the entire app
- Predictable outcomes: same action always produces same result
- No time pressure for any interaction (no auto-advancing, no countdown timers for decisions)
- Clear indication of required vs optional fields
- Summary/review before committing multi-step actions

### Safety nets
- Undo for all destructive actions
- Confirmation for irreversible operations
- Auto-save user work
- Don't clear forms on error
- Allow editing after submission where possible

## 12. Screen reader announcements

### When to announce
- Content loaded: "5 results found"
- Error occurred: "Error: email address is invalid"
- Action completed: "Message sent"
- State changed: "Notifications enabled"
- Content updated: "List refreshed"

### How to announce
```swift
// Immediate announcement
AccessibilityNotification.Announcement("3 new messages").post()

// Layout change (new elements appeared)
AccessibilityNotification.LayoutChanged(focusElement).post()

// Screen change (new screen pushed)
AccessibilityNotification.ScreenChanged(nil).post()

// Page scroll
AccessibilityNotification.PageScrolled("Page 2 of 5").post()
```

### Rules
- Don't over-announce: only announce meaningful state changes
- Don't announce what VoiceOver already reads from labels
- Announce errors immediately with the error content
- Set focus to error elements after announcement
- Announce loading state beginning and completion

## 13. Semantic markup

### Heading levels
```swift
Text("Settings")
    .font(.title)
    .accessibilityAddTraits(.isHeader)

Text("Notifications")
    .font(.headline)
    .accessibilityAddTraits(.isHeader)
```

### Element roles
- Buttons: use Button or add .isButton trait
- Links: add .isLink trait
- Headers: add .isHeader trait
- Images: use .isImage trait, provide label or mark decorative
- Search fields: add .isSearchField trait
- Adjustable (sliders, steppers): add .allowsDirectInteraction trait

### Lists and groups
```swift
// Semantic list
List {
    ForEach(items) { item in
        // Automatically announces list semantics
    }
}

// Manual grouping
VStack {
    ForEach(items) { item in
        ItemView(item)
    }
}
.accessibilityElement(children: .contain)
.accessibilityLabel("Items list, \(items.count) items")
```

### Sorting and actions
```swift
// Sort order
.accessibilitySortPriority(1) // higher = read first

// Custom actions
.accessibilityAction(named: "Delete") {
    deleteItem()
}

// Multiple custom actions
.accessibilityActions {
    Button("Archive") { archiveItem() }
    Button("Share") { shareItem() }
    Button("Delete") { deleteItem() }
}
```

## 14. Testing checklist

### Automated testing
- [ ] Accessibility Inspector: zero warnings
- [ ] All images have accessibility labels or are marked hidden
- [ ] All interactive elements have accessibility labels
- [ ] Contrast ratios pass WCAG AA (4.5:1 normal text, 3:1 large text)

### VoiceOver testing
- [ ] Navigate the entire app with VoiceOver enabled
- [ ] Every interactive element is reachable via swipe navigation
- [ ] Every element announces clearly (label, value, hint)
- [ ] Dynamic content changes are announced
- [ ] No focus traps (can always navigate away)
- [ ] Dismiss gestures work (two-finger scrub for back/dismiss)
- [ ] Custom views are fully navigable

### Dynamic Type testing
- [ ] Test at default size (Large)
- [ ] Test at XXL (largest non-accessibility)
- [ ] Test at AX3 (mid-range accessibility)
- [ ] Test at AX5 (largest)
- [ ] Layout adapts (HStack -> VStack) at accessibility sizes
- [ ] No text clipping or truncation at large sizes (scrollable)
- [ ] Non-text elements scale (@ScaledMetric)

### Keyboard testing (macOS)
- [ ] Tab through all interactive elements in order
- [ ] Visible focus ring on every focused element
- [ ] Return/Enter activates primary action
- [ ] Escape dismisses modals/sheets/popovers
- [ ] Arrow keys navigate within groups
- [ ] All keyboard shortcuts work as documented
- [ ] No focus traps in modals

### Reduce Motion testing
- [ ] Enable Reduce Motion in System Settings
- [ ] All slide/spring animations replaced with crossfade or instant
- [ ] No auto-playing animations
- [ ] No parallax effects
- [ ] App remains fully functional without motion

### Contrast and color testing
- [ ] Enable Increase Contrast - verify borders and separators adapt
- [ ] Enable color filters (Accessibility > Display > Color Filters) - verify information not lost
- [ ] Verify no information is conveyed by color alone
- [ ] Test Reduce Transparency - verify opaque fallbacks work

### Target size verification
- [ ] All iOS touch targets >= 44x44pt
- [ ] All macOS click targets >= 24x24pt
- [ ] Adequate spacing between adjacent targets (>= 4pt)
- [ ] No precision-demanding interactions for primary actions

---

## Quick reference: accessibility environment values

| Environment value | Type | Purpose |
|------------------|------|---------|
| \.accessibilityReduceMotion | Bool | Replace animations |
| \.accessibilityReduceTransparency | Bool | Use opaque backgrounds |
| \.colorSchemeContrast | ColorSchemeContrast | .increased = boost contrast |
| \.legibilityWeight | LegibilityWeight | .bold = use heavier weights |
| \.dynamicTypeSize | DynamicTypeSize | Current text size category |
| \.accessibilityDifferentiateWithoutColor | Bool | Don't rely on color alone |
| \.accessibilityInvertColors | Bool | Colors are inverted |
| \.accessibilityShowButtonShapes | Bool | Show button outlines |
| \.accessibilityEnabled | Bool | VoiceOver or other assistive tech active |

## Quick reference: minimum contrast ratios

| Content type | AA minimum | AAA preferred |
|-------------|-----------|--------------|
| Normal text (< 18pt) | 4.5:1 | 7:1 |
| Large text (>= 18pt or >= 14pt bold) | 3:1 | 4.5:1 |
| UI components (icons, borders) | 3:1 | 4.5:1 |
| Inactive/disabled | Exempt | 3:1 |
| Decorative | Exempt | Exempt |
