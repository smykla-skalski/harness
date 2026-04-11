# Apple Human Interface Guidelines - enforceable reference

This document distills Apple's Human Interface Guidelines into concrete, enforceable rules for macOS and iOS app development. Every rule here is meant to be turned into a hard requirement. Values are in points unless stated otherwise.

---

## 1. Platform conventions

### macOS expectations

- Every app has a menu bar with standard menus in this order: App menu, File, Edit, View, Window, Help. Omit menus that don't apply but never reorder the standard ones.
- The App menu contains About, Preferences/Settings (Cmd+,), Services, Hide (Cmd+H), Hide Others (Cmd+Opt+H), Show All, Quit (Cmd+Q).
- Edit menu contains Undo (Cmd+Z), Redo (Cmd+Shift+Z), Cut (Cmd+X), Copy (Cmd+C), Paste (Cmd+V), Select All (Cmd+A). If the app handles text, these must work.
- Window menu contains Minimize (Cmd+M), Zoom, Bring All to Front, and a list of open windows.
- Windows are resizable by default. If a window cannot be resized, it must have a fixed aspect ratio or functional reason.
- The red close button closes the window but does not quit the app (unless the app is single-window and has no menu bar presence). Cmd+W closes the current window. Cmd+Q quits.
- Standard traffic light buttons are always top-left. Never hide them. Never replace them with custom controls.
- Full screen (Ctrl+Cmd+F or green button) is expected for document-based and media apps. The app must handle full-screen transitions gracefully.
- Right-click (Control+click) shows a context menu. Every selectable element should have a context menu with relevant actions.
- Trackpad gestures: two-finger scroll, pinch to zoom (where applicable), three-finger swipe for navigation. Never hijack system gestures.
- Keyboard shortcuts must follow system conventions. Cmd is the primary modifier. Opt is for alternate actions. Ctrl is reserved for system use except in terminal-style apps.
- Drag and drop: windows and views that display files or transferable data must support drag and drop where it makes sense.
- Focus ring: a visible focus indicator must appear on the currently focused control when using keyboard navigation (Full Keyboard Access).
- Mouse hover states on all interactive elements - cursor changes, highlight, tooltip.
- Multiple windows: support multiple windows for document-based apps. Use WindowGroup in SwiftUI.

### iOS expectations

- The status bar is always visible unless the app is playing full-screen media. Never draw custom content in the status bar area.
- Swipe from left edge navigates back. Never override this gesture. If a custom gesture conflicts, use `UIScreenEdgePanGestureRecognizer` and coordinate properly.
- The home indicator area at the bottom of the screen (iPhone X and later) must remain unobstructed. Do not place interactive controls within 34pt of the bottom edge.
- Rotation: support both portrait and landscape unless the app has a strong reason for a single orientation (games, camera). iPad apps must support all orientations.
- Shake to undo is a system behavior. Do not disable it.
- Pull-to-refresh is the standard pattern for refreshing list content. Use `UIRefreshControl` or SwiftUI's `.refreshable()`.
- Long press reveals context menus. Selectable content should support long-press menus with preview when appropriate.
- Volume buttons should not be overridden for non-media purposes.
- No hover states - design for touch-first. Haptic feedback for significant interactions.
- System gestures: swipe up for home, swipe down for notification center/control center - never conflict with these.

### Shared conventions

- Undo/redo: Cmd+Z / Cmd+Shift+Z (macOS), shake to undo (iOS), always available.
- Copy/paste works everywhere text is displayed.
- System share sheet for sharing content.
- Respect system appearance (light/dark mode).
- Respect text size preferences (Dynamic Type).
- Respect reduce motion preferences.
- Standard alert/confirmation dialog patterns.

### Standard keyboard shortcuts (macOS)

| Action | Shortcut |
|---|---|
| New | Cmd+N |
| Open | Cmd+O |
| Save | Cmd+S |
| Save As | Cmd+Shift+S |
| Print | Cmd+P |
| Close | Cmd+W |
| Quit | Cmd+Q |
| Undo | Cmd+Z |
| Redo | Cmd+Shift+Z |
| Cut | Cmd+X |
| Copy | Cmd+C |
| Paste | Cmd+V |
| Select All | Cmd+A |
| Find | Cmd+F |
| Find Next | Cmd+G |
| Preferences/Settings | Cmd+, |
| Minimize | Cmd+M |
| Full Screen | Ctrl+Cmd+F |
| Hide | Cmd+H |
| Hide Others | Cmd+Opt+H |
| Bold | Cmd+B |
| Italic | Cmd+I |
| Underline | Cmd+U |
| Zoom In | Cmd++ |
| Zoom Out | Cmd+- |
| Actual Size | Cmd+0 |
| Toggle Sidebar | Cmd+Ctrl+S (or Cmd+Opt+S) |

---

## 2. Navigation patterns

### NavigationSplitView (macOS, iPadOS)

- Use for apps with a primary list that reveals detail content: mail, notes, file managers, settings.
- Two-column: sidebar + detail. Three-column: sidebar + content list + detail.
- Sidebar column width: 200-300pt on macOS (default ~250pt). Content column: 250-400pt. Detail fills remaining space.
- Sidebar minimum width: 200pt. Never make it narrower. The sidebar collapses entirely below its minimum rather than squeezing.
- Sidebar items: SF Symbol icon + label, 28-32pt row height.
- Automatic column visibility management on resize.
- On iPad in portrait, the sidebar becomes an overlay or hides behind a toolbar button.
- On macOS 26+, the sidebar gets automatic Liquid Glass treatment. Do not paint an opaque background over it.
- Each column in a multi-column layout maintains independent selection and scroll state.

### TabView

- iOS: Tab bar sits at the bottom of the screen. Maximum 5 tabs visible; a "More" tab appears if there are more than 5. Each tab has an icon and a short label.
- macOS: Tab views typically appear as segmented controls or toolbar-style tabs, not at the bottom of the window. Use for settings/preferences windows (toolbar tab style).
- Tab bar icons: 25x25pt (regular), 18x18pt (compact). Use filled SF Symbols for the selected state, outlined for unselected.
- Tab labels are single words or very short phrases. Sentence case, not title case.
- The tab bar is always visible during navigation within a tab. Never hide it when pushing a detail view in a NavigationStack.
- Each tab maintains independent navigation state.
- Badge counts on tabs for unread/pending items.
- iPadOS 18+ / iOS 26+: The tab bar can appear at the top as a sidebar-style layout. Use `.tabViewStyle(.sidebarAdaptable)` for iPadOS/visionOS adaptability.

### Sheets

- Use for focused tasks that require completion or dismissal before returning to the parent: compose, create, edit, confirm.
- On iOS, sheets are presented modally as cards that can be swiped down to dismiss. Support detents: `.medium` (half height), `.large` (full height), and custom heights.
- On macOS, sheets slide down from the title bar area of the parent window. They are document-modal (block interaction with the parent window but not other windows).
- Every sheet must have a clear dismiss action: Cancel button (top-left) and a confirm/save button (top-right) on iOS; Cancel and OK/Save buttons on macOS.
- Don't nest sheets (one level only). If deeper navigation is needed, use a full-screen presentation or a new window.
- Dismissable by drag-down on iOS, Escape key on macOS.

### Popovers

- Use for non-modal, contextual content that relates to a specific control or area.
- On iPad and macOS, popovers appear as floating bubbles anchored to the source control with an arrow pointing to the anchor.
- On iPhone, popovers automatically present as sheets (no arrow).
- Popovers dismiss when the user taps/clicks outside them. Do not prevent this behavior.
- Maximum width: ~320-400pt. Maximum height: roughly 60% of the screen. If content needs more room, use a sheet instead.
- Popover arrow direction: let the system choose. Don't force an arrow direction unless necessary for layout reasons.
- Don't put complex multi-step flows in popovers.

### Inspector (macOS, iPadOS)

- Floating detail panel for editing properties of a selected item. Appears on the trailing edge of the content area.
- On macOS, inspectors are part of the window and don't create separate windows. Default width: 240-320pt.
- Use `.inspector()` modifier in SwiftUI. The inspector is toggled by a toolbar button, typically using the `sidebar.trailing` symbol.
- Inspectors are not a replacement for detail views. Use them for metadata, properties, and secondary editing - not primary content.
- Content updates based on current selection.

### Alerts

- Short title (1-2 lines), optional message body.
- 2-3 buttons maximum.
- Destructive actions in red.
- Default button: the safe/expected choice.
- Cancel always present for reversible choices.
- Don't use alerts for information display - use banners or inline messages.

### When to use each pattern

| Pattern | Use when |
|---|---|
| NavigationSplitView | Browsing collections with master-detail relationships |
| NavigationStack | Linear, hierarchical navigation (settings, drill-down lists) |
| TabView | Top-level app sections (3-5 major areas) |
| Sheet | Modal task requiring user completion (create, edit, confirm) |
| Popover | Quick contextual info or small form anchored to a button |
| Inspector | Property editing for a selected item |
| Full-screen cover | Immersive experience (photo viewer, video player, onboarding) |
| Alert | Simple confirmation or error with 1-3 buttons |
| Confirmation dialog | Destructive action confirmation with action sheet style |

---

## 3. Typography

### System fonts

- **SF Pro (San Francisco Pro)**: Primary system font for iOS, iPadOS, macOS, tvOS. Two optical sizes:
  - **SF Pro Text**: Optimized for sizes below 20pt. Wider letter spacing, more open apertures.
  - **SF Pro Display**: Optimized for sizes 20pt and above. Tighter tracking, refined proportions.
  - The system switches between Text and Display automatically at 20pt. Do not manually select one or the other.
- **SF Compact**: Used on watchOS. Slightly narrower, optimized for small displays.
- **SF Mono (San Francisco Mono)**: Monospaced variant for code, terminal output, fixed-width data.
- **New York**: Serif system font. Four optical sizes: Small, Regular, Medium, Large. Available as `.serif` design in SwiftUI.
- Never use custom fonts for UI controls - system fonts only for buttons, labels, navigation. Custom fonts are acceptable for branding elements, marketing content, display text.

### iOS text styles (default sizes at Large, the default Dynamic Type size)

| Style | Default size | Weight | Usage |
|---|---|---|---|
| `.largeTitle` | 34pt | Regular | Screen titles, onboarding headers |
| `.title` | 28pt | Regular | Section headers |
| `.title2` | 22pt | Regular | Subsection headers |
| `.title3` | 20pt | Regular | Tertiary headers, card titles |
| `.headline` | 17pt | Semibold | Row labels, emphasized body text |
| `.body` | 17pt | Regular | Primary content, paragraphs |
| `.callout` | 16pt | Regular | Callout text, secondary labels |
| `.subheadline` | 15pt | Regular | Section footers, supplementary labels, metadata |
| `.footnote` | 13pt | Regular | Timestamps, captions, tertiary text |
| `.caption` | 12pt | Regular | Fine print, auxiliary info, annotation |
| `.caption2` | 11pt | Regular | Smallest readable text |

### macOS text styles (default sizes)

| Style | Default size | Weight |
|---|---|---|
| `.largeTitle` | 26pt | Regular |
| `.title` | 22pt | Regular |
| `.title2` | 17pt | Regular |
| `.title3` | 15pt | Regular |
| `.headline` | 13pt | Bold |
| `.body` | 13pt | Regular |
| `.callout` | 12pt | Regular |
| `.subheadline` | 11pt | Regular |
| `.footnote` | 10pt | Regular |
| `.caption` | 10pt | Regular |
| `.caption2` | 10pt | Medium |

### Dynamic Type scaling (iOS)

Text styles scale automatically across 12 size categories:

| Category | body pt | footnote pt | caption pt |
|---|---|---|---|
| xSmall | 14 | 11 | 11 |
| Small | 15 | 12 | 11 |
| Medium | 16 | 12 | 11 |
| Large (default) | 17 | 13 | 12 |
| xLarge | 19 | 14 | 13 |
| xxLarge | 21 | 16 | 14 |
| xxxLarge | 23 | 17 | 15 |
| AX1 | 28 | 19 | 17 |
| AX2 | 33 | 23 | 20 |
| AX3 | 40 | 27 | 22 |
| AX4 | 47 | 33 | 26 |
| AX5 | 53 | 38 | 29 |

### Typography rules

- Always use text styles (`.font(.body)`) rather than fixed sizes (`.font(.system(size: 17))`). Fixed sizes do not respond to Dynamic Type.
- Use `@ScaledMetric` for spacing and sizing that should scale with text.
- Never set a minimum scale factor below 0.5 with `.minimumScaleFactor()`. Below that, text becomes illegible.
- Minimum readable text size: 11pt on iOS, 10pt on macOS. Never go smaller.
- Line length: 50-75 characters per line for body text (70 optimal). Use `.frame(maxWidth:)` to constrain wide text on large screens.
- Line spacing (line height): 1.2-1.5x font size. Body text at 1.4x minimum. Use system defaults when possible.
- Paragraph spacing: 0.5-1.0x the line height.
- Weight hierarchy: use at most 2-3 weights in a single view to establish hierarchy. Overuse of bold dilutes emphasis. Use font weight for hierarchy, not just size changes.
- Letter spacing (tracking): use system defaults. If customizing, only tighten tracking for display sizes (20pt+) and loosen for small sizes (below 14pt).
- Truncation: use trailing ellipsis (`...`) for single-line truncation. For multi-line, use `.lineLimit()` with `.truncationMode(.tail)`.
- Numbers in tables or lists: use monospaced digits (`.monospacedDigit()`) so columns align.
- Never use ALL CAPS for body text. ALL CAPS is acceptable only for short labels (2-3 words), buttons, or section headers and must use proper tracking (+2% minimum for readability).
- Left-align body text (never justify on screens).
- Test at all Dynamic Type sizes including the 5 accessibility sizes. Layout must not break at the largest sizes - use ScrollView.

---

## 4. Color and contrast

### System colors

Apple provides these named system colors that automatically adapt between light and dark mode:

| Color | Light mode | Dark mode | Usage |
|---|---|---|---|
| `.red` | #FF3B30 | #FF453A | Errors, destructive actions, badges |
| `.orange` | #FF9500 | #FF9F0A | Warnings, caution |
| `.yellow` | #FFCC00 | #FFD60A | Caution, starred items |
| `.green` | #34C759 | #30D158 | Success, positive status, completion |
| `.mint` | #00C7BE | #63E6E2 | Fresh, light accent |
| `.teal` | #30B0C7 | #40CBE0 | Information |
| `.cyan` | #32ADE6 | #64D2FF | Links, informational |
| `.blue` | #007AFF | #0A84FF | Primary actions, links, selection |
| `.indigo` | #5856D6 | #5E5CE6 | Special branding |
| `.purple` | #AF52DE | #BF5AF2 | Creative, premium |
| `.pink` | #FF2D55 | #FF375F | Social |
| `.brown` | #A2845E | #AC8E68 | Earthy, natural |
| `.gray` | #8E8E93 | #8E8E93 | Neutral, disabled, secondary |

### Semantic colors

| SwiftUI | Purpose |
|---|---|
| `.primary` | Main text color. Black in light, white in dark. |
| `.secondary` | Secondary text. Gray that adapts to mode. |
| `.tertiary` | Tertiary text. Lighter gray, placeholder text, disabled. |
| `.quaternary` | Quaternary text. Very light, used sparingly. |
| `.accentColor` / `.tint` | The app's tint color. Defaults to system blue. Interactive elements, your app's brand color. |
| `Color(uiColor: .systemBackground)` | Primary background. White in light, #000000 in dark (iOS). |
| `Color(uiColor: .secondarySystemBackground)` | Grouped content area. #F2F2F7 in light, #1C1C1E in dark. |
| `Color(uiColor: .tertiarySystemBackground)` | Elevated surface. #FFFFFF in light, #2C2C2E in dark. |
| `Color(uiColor: .separator)` | Standard separator line (use `.opacity` variant for subtle dividers). |
| `Color(uiColor: .opaqueSeparator)` | Non-translucent separator. |
| `Color(uiColor: .systemGroupedBackground)` | Grouped-style table background. |

### Contrast ratios (WCAG 2.1, enforced by Apple)

| Element | Minimum ratio (AA) | Enhanced ratio (AAA) |
|---|---|---|
| Normal text (below 18pt, or below 14pt bold) | 4.5:1 | 7:1 |
| Large text (18pt+ regular, or 14pt+ bold) | 3:1 | 4.5:1 |
| Non-text elements (icons, borders, controls) | 3:1 | not specified |
| Inactive/disabled controls | exempt | exempt |
| Decorative elements | exempt | exempt |

Preferred: aim for AAA (7:1 normal text, 4.5:1 large text). Interactive elements must be visually distinguishable from non-interactive.

### Dark mode rules

- Not a simple color inversion. Depth reversal: elevated surfaces get lighter, not darker.
- Background hierarchy: darkest at the back, lighter as surfaces elevate. A card on a dark background should be a slightly lighter gray.
- Never use pure black (#000000) for backgrounds on macOS. Use elevated system backgrounds that have a slight warmth (~#1C1C1E). iOS uses true black for OLED screens only in the base background level.
- Reduce contrast slightly in dark mode (pure white on pure black is harsh).
- Shadows are ineffective in dark mode. Use lighter surface colors and subtle borders to indicate elevation.
- System colors automatically shift between light and dark variants. Always use system colors or assets with light/dark variants rather than hardcoded hex values.
- All custom colors need both light AND dark variants.
- Test every screen in both light and dark mode. Test with increased contrast enabled.
- On macOS, respect `NSAppearance` and never force a specific appearance unless the user explicitly chose it in your app's settings.

### Accent colors

- One accent color per app for interactive elements: buttons, links, selection highlights, switch on-state, slider fill, navigation tints.
- On macOS, the user can override the accent color in System Settings > Appearance. The app must respect this unless the brand color is essential.
- Accent color should have sufficient contrast (3:1 minimum) against both light and dark backgrounds.
- Do not use the accent color for large background fills. It is for interactive elements and highlights only.
- On iOS, set the accent color in the asset catalog. On macOS, set it in the asset catalog or via `NSColor.controlAccentColor` awareness.
- Never use color as the sole indicator of meaning - pair with icon, text, or pattern.

### Vibrancy (macOS)

- Vibrancy makes text and icons blend with the content behind them. Used in sidebars, toolbars, and system chrome.
- Use `.primary` label color in vibrancy contexts - it automatically adjusts.
- Label vibrancy levels: `.primary`, `.secondary`, `.tertiary`, `.quaternary`. The system applies these in standard chrome areas.
- Never force a specific text color in a vibrancy context. Use semantic colors that adapt.
- Vibrancy is not available in dark mode opaque areas. It only works over translucent materials.
- Don't apply vibrancy to solid backgrounds.

---

## 5. Iconography

### SF Symbols

- SF Symbols is the canonical icon library for Apple platforms. 6000+ symbols as of SF Symbols 6.
- Symbols are vector-based and scale with text. They align with text baselines and x-height automatically.
- Always prefer an SF Symbol over a custom icon when a matching symbol exists.
- Symbols auto-adapt to Dynamic Type when using text-relative sizing.

### Rendering modes

| Mode | Behavior | Use when |
|---|---|---|
| `.monochrome` | Single color, uniform. Respects `.foregroundStyle()`. | Default for most UI. Toolbars, lists, labels. |
| `.hierarchical` | Single color with primary/secondary/tertiary opacity layers. | Adding depth to a single-color symbol. |
| `.palette` | Two or three explicit colors for different layers. | Custom color combinations (e.g., colored folder icons). |
| `.multicolor` | Fixed Apple-defined colors per symbol layer. | When the symbol has canonical colors (e.g., weather icons, file type icons). |

### Symbol weights and scales

- Symbols have 9 weights matching font weights: ultralight, thin, light, regular, medium, semibold, bold, heavy, black.
- Symbol weight should match the surrounding text weight. A `.body` label gets `.regular` weight symbol. A `.headline` label gets `.semibold`.
- Consistent stroke weight within a screen.
- Three scales: `.small`, `.medium` (default), `.large`. Scale adjusts the symbol relative to adjacent text.
  - `.small`: 20% smaller than font cap height. Use for dense UI, inline with small text.
  - `.medium`: matches font cap height. Default for most uses.
  - `.large`: 30% larger than cap height. Use for standalone symbols, tab bar icons, prominent actions.

### Symbol sizing

- Let symbols size automatically with text styles. Use `Image(systemName:).font(.body)` rather than `.resizable().frame(width:height:)`.
- If explicit sizing is needed, use `.imageScale()` or `.symbolRenderingMode()` with `.font()`.
- Standard sizes: 17pt for body-adjacent, 22pt for navigation, 28pt for toolbar (macOS).
- Tab bar icons: use `.large` scale at the `.title3` text style equivalent (~22pt).
- Toolbar icons: use `.medium` scale at the `.body` text style equivalent (~17pt on iOS, ~13pt on macOS).
- Navigation bar icons: 22x22pt touch target, symbol at `.medium` scale.
- Minimum touch target for any tappable symbol: 44x44pt on iOS, 24x24pt on macOS (with adequate spacing between targets).
- Icon-to-label spacing: 6-8pt.
- Use filled variants for selected state, outline for unselected (tab bars, toolbars).
- Don't add text labels to every icon - use tooltips for non-obvious icons on macOS.

### Custom icon guidelines

- Match the visual weight of SF Symbols. Use the SF Symbols template from Apple as a starting point.
- Align to the SF Symbols grid: icons sit on a baseline, have consistent cap height, and use the same stroke weight as the current font weight.
- Export at 1x, 2x, 3x for raster assets. Use SVG or PDF for vector assets in asset catalogs.
- App icons: 1024x1024px master size. The system generates all needed sizes. No transparency allowed. No rounded corners in the asset (the system applies the mask).
- macOS 26 app icons: the system applies a circular or roundedRect glass effect. The icon should have visual content that works within the system-applied shape.
- Small visual icons can have larger hit areas using `.contentShape`.

---

## 6. Layout and spacing

### 8-point grid

All spacing and sizing should be multiples of 4pt (ideally 8pt). Standard spacing scale:

| Token | Value | Usage |
|---|---|---|
| Extra small | 4pt | Tight spacing between related elements (icon to label) |
| Small | 8pt | Compact spacing within groups, related element spacing |
| Medium | 12pt | Standard spacing between controls, compact container padding |
| Regular | 16pt | Standard cell padding, section spacing, standard container padding |
| Large | 20pt | Between content sections, spacious container padding |
| Extra large | 24pt | Major section breaks |
| Double | 32pt | Screen-level vertical padding, section spacing |
| Triple | 40pt | Major vertical breaks |
| Quad | 48pt | Hero spacing |
| Max | 64pt | Largest standard spacing |

### Platform-specific margins

**iOS:**
- Standard horizontal margin: 16pt (iPhone), 20pt (larger iPhones in landscape or iPads).
- Readable content width: system applies `.readableContentGuide` which limits text columns to approximately 672pt on iPad (about 70 characters of body text).
- Section insets in grouped tables: 16pt horizontal, 35pt from section header to first row.
- Table/list content: 16pt leading/trailing.
- Card content padding: 12-16pt all sides.
- Safe area bottom: 34pt on devices with home indicator. 0pt on devices with home button.
- Safe area top: 44pt (standard navigation bar), 88pt (large title navigation bar), status bar height varies by device (47pt on iPhone 14 Pro with Dynamic Island, 54pt on iPhone 15 Pro, 59pt on iPhone 16 Pro).

**macOS:**
- Window content padding: 20pt from window edges.
- Standard padding: 12-16pt inside containers.
- Toolbar height: standard toolbar is 52pt. Compact toolbar is 38pt (unified title/toolbar).
- Sidebar width: default 250pt, user-resizable 200-350pt.
- Standard list row height: 24pt (small), 28pt (medium), 34pt (large).
- Menu item height: 22pt standard, 18pt small.
- Standard button height: 21pt (small), 24pt (regular), 28pt (large).

### Alignment rules

- Left-align text in LTR locales. Right-align in RTL. Use `.leading` and `.trailing` in SwiftUI, never `.left` and `.right`.
- Right-align numbers in columns/tables.
- Center-align is only for: buttons, short labels, empty states, onboarding text, badges, actions in modal dialogs.
- Align controls on a shared leading edge within a form or settings screen. Consistent leading edge alignment within a section.
- In a form with labels and fields, labels are trailing-aligned and fields are leading-aligned, separated by a consistent gap (16pt minimum).
- Baseline-align text at different sizes that appears on the same horizontal line.
- Use alignment guides for cross-stack alignment.

### Safe areas

- Always respect safe areas. Content must not extend under the status bar, home indicator, or Dynamic Island unless it is background content (images, maps).
- Use `.ignoresSafeArea()` only for background elements that extend edge-to-edge. Interactive controls must remain within safe areas.
- Use `.safeAreaInset()` for custom bars/toolbars.
- On macOS, the safe area includes the title bar and toolbar area. Content scrolling under a transparent toolbar should use `.safeAreaInset()` for proper spacing.
- Navigation bar content: system-managed, don't override.
- Tab bar: system height (49pt on iOS), don't customize.

### Grid systems

- LazyVGrid / LazyHGrid: use adaptive column sizes (`GridItem(.adaptive(minimum: 160))`) for responsive grids that work across device sizes.
- Fixed grid: use when card sizes are constant (e.g., 160x200pt album art).
- Minimum inter-item spacing in grids: 8pt. Recommended: 12-16pt.
- Grid items should maintain consistent aspect ratios within the same collection.

---

## 7. Controls

### Buttons

**Styles:**
- **Bordered Prominent** (`.borderedProminent`): Primary action. One per screen or section. Filled with accent color.
- **Bordered** (`.bordered`): Secondary action. Standard background tint, not filled.
- **Borderless** (`.borderless`): Tertiary or inline action. Text-only appearance.
- **Plain** (`.plain`): No visual treatment. For custom styled buttons.
- **Glass** (`.glass`): Translucent secondary action on macOS 26+ / iOS 26+. For floating controls over content.
- **Glass Prominent** (`.glassProminent`): Opaque primary action on macOS 26+ / iOS 26+.
- **Destructive role** (`.destructive`): System renders in red. Use for delete, remove, discard.

**Sizing rules:**
- iOS minimum touch target: 44x44pt. Never smaller.
- macOS minimum click target: 24x24pt for icon-only buttons, full width for text buttons.
- Button padding: horizontal 12-16pt, vertical 6-10pt for bordered styles.
- Minimum button width: 44pt on iOS, 50pt on macOS for text buttons.
- Button corner radius: system default for bordered styles. Do not override unless you have a design system reason.
- Button labels: verb phrases ("Save changes", "Delete item"), not nouns ("OK").
- Disabled state: reduced opacity (0.3-0.4), not hidden.
- Loading state: replace label with progress indicator, disable button.

### Toggles

- Use for binary on/off state. Label must describe the on-state. ("Show Preview" not "Preview Toggle").
- Label on the left, toggle on the right.
- Immediate effect - no Save button needed.
- On iOS, toggles render as switches by default. On macOS, they render as checkboxes.
- Use `.toggleStyle(.switch)` to force switch appearance on macOS when the setting is an on/off preference.
- Never use a toggle for an action that has immediate irreversible effects. Use a button with confirmation instead.
- Grouped in Form or List sections.

### Pickers

- **Segmented control** (`.segmented`): 2-5 mutually exclusive options, visible at once. All options must be visible simultaneously.
- **Menu picker** (default on macOS): Compact dropdown. Use for 5-15 options, or when space is limited.
- **Wheel picker** (iOS): Use for date/time or cyclic values. Avoid for simple lists.
- **Date picker**: Use system DatePicker, supports compact/graphical/wheel styles.
- **Inline picker**: Expanding row in a list for selection. Use in settings and forms.
- **Navigation link picker**: Pushes to a full list. Use when there are more than 15 options.
- Don't nest pickers - flatten choices where possible.

### Sliders

- Use for continuous values within a defined range. Not for precise numeric input - pair with a text field for exact values.
- Minimum track length: 100pt. Do not use sliders in narrow spaces.
- Include min/max labels or value display when the scale is not obvious.
- Slider step values: use `.step()` for discrete increments (e.g., volume in 5% steps).

### Steppers

- Use for small numeric adjustments with clear increment/decrement (quantity, counts).
- Always show the current value next to the stepper.
- Define sensible min/max bounds.

### Segmented controls

- Maximum 5 segments. Each segment should have roughly equal width.
- Labels: short text (1-2 words) or icons. Not both in the same control unless all segments have both.
- Segmented controls affect the view they're in immediately. No "apply" button needed.
- Place at the top of the content they control, typically in a toolbar or below a navigation title.

### Context menus

- Every selectable item should have a context menu (right-click on macOS, long press on iOS).
- Order actions by frequency: most common first. Put destructive actions last, separated by a divider.
- Limit menu depth: 2 levels maximum. Deep submenus are hard to navigate.
- Include keyboard shortcut hints in macOS menus.
- Preview where relevant (links, images).

### Text menus and pull-down buttons

- Use `Menu` for pull-down action lists (not navigation). The button shows a label; tapping reveals options.
- Picker-style menus show the currently selected value as the button label.
- Action-style menus show a fixed label (like "Add" with a plus icon) and list actions on tap.
- Sort and filter menus should show the current selection state with a checkmark.

### Text fields

- Clear button visible when field has content.
- Placeholder text shows expected format or example (describes what to enter, not the field name).
- Label above or leading the field (not just placeholder - placeholder is not a label, it disappears on input).
- Appropriate keyboard type on iOS (`.keyboardType(.emailAddress)`, `.URL`, `.numberPad`, `.phonePad`).
- Auto-correction and auto-capitalization settings appropriate to content.
- Secure field for passwords (`.textContentType(.password)`).
- Focus ring visible when active (macOS default).

---

## 8. Feedback and responsiveness

### Loading states

- If an operation takes more than 1 second, show an indeterminate progress indicator (spinner).
- If the operation duration is known, use a determinate progress bar with percentage or fraction.
- Full-screen loading: centered spinner with optional text label below. Never block the entire screen if only part of the content is loading.
- Skeleton views (placeholder shapes matching content layout) are preferred over spinners for initial content loading in lists and grids.
- Never show a loading indicator for less than 0.5 seconds. If the operation completes faster, skip the indicator entirely.
- Never leave the user without feedback for more than 100ms after an action.
- Activity indicator in navigation bar for background sync.

### Progress indicators

- **ProgressView (indeterminate)**: Spinning wheel. Use for unknown duration operations, expected under 10 seconds. 20x20pt on iOS, 16x16pt on macOS.
- **ProgressView (determinate)**: Horizontal bar. Fill left-to-right. Width matches the context (toolbar, sheet, full-width). Minimum height: 4pt.
- **Circular determinate**: Ring that fills clockwise. Use for upload/download progress on individual items.
- Progress must be accurate. If you can't estimate, use indeterminate. Faked progress that jumps or stalls destroys trust.

### Haptics (iOS)

| Feedback type | Use when |
|---|---|
| `.success` | Task completed successfully (save, send, confirm) |
| `.warning` | Action needs attention (approaching limit, soft error) |
| `.error` | Action failed |
| `.selection` | Picker value changed, toggle flipped |
| `.impact(.light)` | Subtle UI interaction (button press, snap to position) |
| `.impact(.medium)` | Standard interaction (toggle, segment change) |
| `.impact(.heavy)` | Significant interaction (drag threshold crossed) |
| `.impact(.rigid)` | Hard stop (collision, snap to grid) |
| `.impact(.soft)` | Cushioned stop (elastic bounce) |

- Do not use haptics for scrolling, typing, or continuously triggered events. Haptics for significant state changes only.
- Haptics must match the visual feedback. A success haptic without a success visual is confusing.
- Respect the system Haptics setting. If the user has disabled haptics, do not play them.

### Sounds

- System sounds are appropriate for: notifications, alerts, sent message confirmation, payment success.
- Use system sounds for system-like actions (send, receive, error).
- Do not play sounds for routine UI interactions (button taps, navigation transitions).
- Custom sounds: short (under 2 seconds), not annoying on repeat.
- All sounds must respect the silent/mute switch and system volume. Media playback is the exception.
- Sound is supplementary, never the only indicator.

### Animations

- All meaningful state changes should be animated. Use `.animation(.default, value:)` or `withAnimation {}` for implicit transitions.
- Default animation duration: 0.2-0.35 seconds. Never exceed 0.5 seconds for UI transitions.
- Don't animate everything - animate meaningful state changes.
- Spring animations: use for interactive, physical-feeling transitions. SwiftUI default spring is appropriate for most cases.
- Ease-in-out: use for automated transitions, general movement (appear/disappear).
- Ease-out: use for elements entering the screen (decelerate into view).
- Ease-in: use for elements leaving the screen (accelerate out of view).
- Entry: fade in + scale up from 0.95, or slide from edge.
- Exit: fade out + scale down to 0.95, or slide to edge.
- State changes: cross-fade (150-200ms).
- Match animation direction to the navigation direction. Pushing a view: new view slides in from the trailing edge. Popping: view slides out to the trailing edge.
- Respect the Reduce Motion accessibility setting. Replace movement-based animations with crossfade (`.opacity` transition) when Reduce Motion is on.

---

## 9. Accessibility

### VoiceOver

- Every interactive element must have an accessible label. If the control has no visible text, set `.accessibilityLabel("description")`.
- Labels must be concise (2-5 words), start with a capital letter, and not include the control type (the system announces "button" automatically).
- Bad: `.accessibilityLabel("Button to save the document")`. Good: `.accessibilityLabel("Save")`.
- Set `.accessibilityHint()` for what the action does when it's not obvious from the label.
- Set `.accessibilityValue()` for state (on/off, 3 of 10, etc.).
- Images that convey information need `.accessibilityLabel()`. Decorative images use `.accessibilityHidden(true)`.
- Group related elements with `.accessibilityElement(children: .combine)` to reduce swipe count.
- Custom actions: use `.accessibilityAction()` for actions beyond the default tap. Swipe-to-delete actions must be exposed as accessibility custom actions.
- Announce dynamic content changes with `AccessibilityNotification.Announcement("message").post()`.
- Reading order follows the visual layout order. If programmatic order differs from visual order, fix it with `.accessibilitySortPriority()`.
- Adjustable controls (sliders, steppers) must implement `.accessibilityAdjustableAction()` with increment/decrement.
- Every screen transition must post a screen change notification so VoiceOver moves focus appropriately.

### Dynamic Type

- All text must use text styles or otherwise respond to the user's preferred content size category.
- Use `@ScaledMetric` for non-text dimensions that should scale with text.
- Layouts must reflow at Accessibility sizes (AX1 through AX5). Horizontal layouts should stack vertically. Use `@Environment(\.dynamicTypeSize)` to detect and `AnyLayout` or `ViewThatFits` for conditional layout.
- Truncation at large sizes is a bug. Content that truncates in AX3+ needs a layout adjustment.
- Images and icons used as text (badges, indicators) must scale with Dynamic Type. Use `.dynamicTypeSize()` or scale images with `@ScaledMetric`.
- Minimum text size: never clamp text styles below the user's chosen size. If an element truly cannot fit, allow horizontal scrolling rather than clamping.
- Test at all sizes, including the 5 accessibility sizes. Layout must remain usable at largest sizes - use ScrollView.

### Reduce Motion

- When `UIAccessibility.isReduceMotionEnabled` is true (or `@Environment(\.accessibilityReduceMotion)` in SwiftUI):
  - Replace slide/zoom/bounce animations with crossfade.
  - Replace spring animations with linear.
  - Disable parallax effects.
  - Disable auto-playing animations and video.
  - Hero transitions become simple crossfades.
  - Reduce or eliminate spring animation overshoot.
- Reduce Motion does not mean "no animation." Simple fade transitions are acceptable.
- Provide static alternatives for animated content.

### Increase Contrast

- When `@Environment(\.accessibilityHighContrast)` is true:
  - Borders on controls become more prominent (1pt to 2pt, higher opacity).
  - Background fills become more opaque.
  - Text colors shift to higher contrast variants.
  - System colors automatically provide higher contrast alternatives. Custom colors must also provide high-contrast variants in the asset catalog.

### Keyboard navigation (macOS) and Switch Control

- Every interactive element must be reachable via Tab key (or Switch Control scanning).
- Tab order follows logical reading order: top-to-bottom, leading-to-trailing.
- Arrow keys navigate within groups (lists, grids, segmented controls).
- Focus ring must be visible on the focused element. Never hide the system focus ring.
- All actions available through touch or click must also be available through keyboard or switch.
- Custom controls must implement `.focusable()` and handle `.onKeyPress()` or `.onMoveCommand()`.
- Escape key must dismiss modals (sheets, popovers, alerts).
- Enter/Return key activates the default/primary action.
- Space toggles checkboxes and buttons.

### Additional accessibility requirements

- Color must never be the only way to convey information. Use shape, text, or pattern in addition.
- Touch targets: 44x44pt minimum on iOS, 24x24pt minimum on macOS (with 4pt+ spacing between targets). Elements smaller than this fail accessibility.
- Small visual icons can have larger hit areas using `.contentShape`.
- Motion sensitivity: no strobing or flashing content. If unavoidable, never exceed 3 flashes per second.
- Time limits: if content auto-dismisses (toast notifications, banners), provide at least 5 seconds and allow the user to extend or disable auto-dismiss.
- Media: provide closed captions and audio descriptions for video content.

---

## 10. Data entry

### Text fields

- Use `TextField` for single-line input. Use `TextEditor` for multi-line.
- Placeholder text describes what to enter, not the label. "Search apps and games" not "Search".
- Labels must be visible. A placeholder is not a label - it disappears on input. Use a `LabeledContent` wrapper or persistent label above/beside the field. Vertical layout (label above field) is clearest and most accessible.
- Set the correct keyboard type on iOS: `.keyboardType(.emailAddress)`, `.keyboardType(.URL)`, `.keyboardType(.numberPad)`, `.keyboardType(.phonePad)`.
- Set `.textContentType()` for autofill: `.emailAddress`, `.password`, `.newPassword`, `.oneTimeCode`, `.name`, `.addressCity`, `.postalCode`, etc.
- Set `.autocapitalization(.none)` for email and URL fields. `.autocapitalization(.words)` for name fields.
- Set `.autocorrectionDisabled()` for fields where autocorrect is harmful: usernames, code, IDs.
- Secure fields: use `SecureField` for passwords. Show/hide toggle is acceptable but never default to showing.

### Forms

- Group related fields into sections with headers and optional footers (explanation text).
- Field order: most important first, then follow natural data order. Left-to-right, top-to-bottom, matching the logical completion order.
- Pre-fill fields when data is available (defaults, previous entries, system data like name from contacts).
- Required fields: mark optional ones with "Optional" label. Assume required by default. Do not use color alone to indicate required status.
- Limit the number of fields per screen. If a form has more than 7 fields, split into multiple steps or collapsible sections.
- Submit button: always visible. On iOS, place at the bottom of the form or as a toolbar button. On macOS, place at the trailing bottom of the form.
- Don't auto-advance between fields (disrupts correction).

### Validation

- Validate inline on field blur (`.onSubmit` or `onEditingChanged`), not on every keystroke. Do not wait until form submission.
- Validate all on submit as a safety net.
- Error messages appear directly below the field, in red (`.red` system color), with a clear description of what's wrong.
- Bad: "Invalid input". Good: "Email must include @ and a domain". What's wrong + what's expected.
- Success indication: subtle green checkmark or border when a field passes validation. Keep it subtle.
- Don't mark fields as invalid before the user has interacted with them.
- Do not disable the submit button for validation. Let the user tap it and show all errors at once if they try to submit an incomplete form.
- Real-time character counters for fields with maximum lengths (bios, comments).

### Autocomplete and suggestions

- Use `.textContentType` for semantic auto-fill (name, email, address, password).
- Use `.searchSuggestions()` in SwiftUI for search fields with live suggestions.
- Suggestions appear in a dropdown below the field. Maximum 5-8 visible suggestions.
- Recent entries: show last 5-10 used values. Recent searches appear first, followed by predictions.
- Search: show suggestions after 2+ characters, debounce 300ms.
- Clear button (x icon) in the text field is required for search fields. Escape key also clears.
- On iOS, the keyboard has a toolbar with "Previous", "Next", and "Done" for form navigation. Use `.toolbar` with `ToolbarItemGroup(placement: .keyboard)`.

### Paste behavior

- Standard paste (Cmd+V / long press > Paste) must work in all editable fields.
- If pasting structured data (URLs, phone numbers, addresses), parse and populate the correct fields.
- Rich text pasting into plain text fields must strip formatting silently.
- Large paste operations (images, files into text fields) should show a confirmation if the paste would replace existing content.

---

## 11. macOS-specific patterns

### Window chrome

- Title bar height: 22pt (standard), 28pt (large title). Unified title bar + toolbar: 52pt combined, 38pt in compact mode.
- Title bar: displays document name, proxy icon for file-based apps.
- Traffic light buttons (close, minimize, zoom): centered vertically in the title bar, 7pt from the leading edge, 6pt spacing between buttons. Each button is 12x12pt.
- The title text is centered in the title bar. For unified toolbar, the title appears leading-aligned next to the toolbar controls.
- Window corner radius: 10pt (standard macOS windows).
- Window minimum size: set a sensible minimum that prevents controls from overlapping. 400x300pt is a common floor.
- Window position: new windows cascade (offset 22pt down and right from the previous window). Remember window position and restore it on next launch.
- Status bar: bottom of window for supplementary info (item count, sync status).

### Toolbar

- Toolbar items use SF Symbols at 13pt/regular weight (macOS native sizing). Icon + optional label.
- Toolbar items have labels below icons in the default style. Compact mode shows icons only.
- Standard toolbar placements: `.principal` (center), `.automatic` (system decides), `.navigation` (leading), `.primaryAction` (trailing).
- Toolbar is customizable by default (right-click > "Customize Toolbar"). Allow this unless there's a reason not to.
- Search field in the toolbar: place in `.principal` or use `.searchable()` modifier which handles placement automatically.
- Toolbar separator: use `Divider()` in toolbar items to visually group sections.
- Sidebar: 200-280pt, collapsible, keyboard shortcut to toggle (Cmd+Ctrl+S or similar).

### Menu bar menus

- All app actions must be accessible via the menu bar. The menu bar is the primary command interface on macOS.
- Required menus: App menu, File, Edit, View, Window, Help.
- App menu: About, Settings (Cmd+,), Hide, Quit.
- Edit menu: Undo, Redo, Cut, Copy, Paste, Select All.
- View menu: sidebar toggle, zoom, appearance options.
- Help menu: searchable, links to documentation.
- Custom menus for app-specific functionality between View and Window.
- Group actions logically with separators (dividers).
- Disabled menu items are grayed out, not hidden. Hiding available options confuses muscle memory.
- Keyboard shortcut hints appear right-aligned in menu items. The shortcut characters use the system modifier symbol glyphs (command, option, shift, control).
- Standard menu items that do not apply: disable them, do not remove them from the menu.
- Status bar items (menu bar extras): 22x22pt icon. Use template images that adapt to the menu bar appearance.

### Dock integration

- App icon in the dock: badge count for unread items (use `UNUserNotificationCenter` or `NSApp.dockTile.badgeLabel`).
- Right-click dock menu: include recent documents, status, and quick actions.
- Progress indication on dock icon for long operations.
- Dock bounce: only for events that need immediate attention (received message, completed download). Do not bounce for routine events.
- Minimize to dock: windows minimize with the genie or scale effect based on user preference.

### Notifications (macOS)

- Use `UNUserNotificationCenter` for all notifications. Legacy `NSUserNotification` is deprecated.
- Notifications appear in the upper-right corner, grouped by app.
- Types: banner (auto-dismiss after ~5 seconds), alert (stays until dismissed). Default to banner; only use alert for genuinely urgent information.
- Include a relevant action button. Up to 4 actions in expanded notification.
- Do not spam. Respect notification settings. Rate limit to avoid overwhelming the user.
- Grouped by conversation/topic.
- Sound only for time-sensitive notifications.

### Settings/preferences window

- Open with Cmd+, (always). Menu: App Name > Settings (macOS 13+) or Preferences (macOS 12 and earlier).
- Use `Settings` scene in SwiftUI (replaces `Preferences`).
- Tab-based layout for multiple categories. Use SF Symbols for tab icons (General, Appearance, Accounts, Advanced, etc.).
- Form layout within tabs.
- Window is non-resizable, fixed appropriate size per tab. Standard width: 500-650pt. Centered on screen.
- Settings apply immediately (no "Apply", "OK", or "Save" button). Changes are auto-saved.
- Provide "Restore Defaults" where appropriate, with a confirmation dialog.
- Organization: General tab first, then feature-specific tabs, Advanced last.

---

## 12. iOS-specific patterns

### Safe areas and device geometry

**iPhone safe areas (approximate, varies by model):**

| Device class | Status bar | Home indicator | Corner radius |
|---|---|---|---|
| iPhone SE (3rd gen) | 20pt | 0pt (home button) | 0pt |
| iPhone 14 | 47pt | 34pt | 47.33pt |
| iPhone 14 Pro (Dynamic Island) | 54pt | 34pt | 55pt |
| iPhone 15 Pro | 54pt | 34pt | 55pt |
| iPhone 16 Pro | 59pt | 34pt | 55pt |
| iPhone 16 Pro Max | 59pt | 34pt | 55pt |

**iPad safe areas:**
- All edges: 0pt in landscape with no status bar visible, 24pt status bar in portrait.
- Home indicator: 20pt on iPad models with no home button.
- Landscape: additional leading/trailing insets.

Always use `.ignoresSafeArea()` only for background content, never for interactive elements.

### Dynamic Island

- Content behind the Dynamic Island is clipped. Do not place interactive elements near it.
- Live Activities can integrate with the Dynamic Island, but standard apps should simply respect the safe area.
- Do not try to style content around the island shape. The safe area insets handle it.

### Tab bars (iOS)

- Height: 49pt (standard), 83pt (with home indicator padding on Face ID devices).
- 2-5 tabs maximum. More uses a "More" tab with a list.
- Tab icons: 25x25pt in regular, 18x18pt in compact. Filled when selected, outlined when not.
- Tab labels: single word, sentence case. Font: 10pt caption style.
- Tab bar is always visible during in-tab navigation. It hides only when presenting a full-screen modal or entering full-screen media.
- Active tab icon uses the accent color (tinted). Inactive tabs use `.secondary` label color (gray).
- Badge for notifications/counts.
- Tab bar background: system material blur. In iOS 26, it may receive glass treatment.

### Navigation bars (iOS)

- Standard height: 44pt content area + status bar height.
- Large title height: 96pt (collapsed 44pt) + status bar.
- Title: large title (`.navigationBarTitleDisplayMode(.large)`) for top-level screens, inline for drill-down.
- Back button: system chevron + previous screen title (truncated to "Back" if too long). Never hide the back button. Never replace the chevron with custom art in the navigation bar.
- Navigation bar items: trailing side for actions (Edit, Done, compose icon), 1-2 action buttons maximum. Leading side for back button only (or a close button for modally presented screens).
- Large titles: use for top-level screens in tab-based apps (each tab's root). Subsequent pushed views use standard inline titles.
- Navigation bar background: blur material by default. Transparent when scrolled to top with large title. Becomes opaque on scroll.
- Search bar: integrated below navigation bar with `.searchable`.

### Swipe gestures

- Swipe from left edge: system back navigation. Never override.
- Swipe right on table row: primary/positive action (mark as read, pin). Swipe left: destructive action (delete, archive). Use `.swipeActions()`.
- Swipe actions: maximum 3 per side. Each action has an icon and/or short label. Destructive actions are red.
- Full swipe (swipe all the way): triggers the first action automatically. Support this for common actions like delete or archive.
- Avoid custom horizontal swipe gestures that conflict with edge swipe navigation.

### Pull-to-refresh

- Standard pattern for refreshable content (feeds, inboxes, lists).
- Use `.refreshable()` modifier in SwiftUI or `UIRefreshControl` in UIKit.
- The refresh control appears above the content, pulling down. It shows a spinner while loading.
- Pull distance before activation: ~60pt (system handled).
- Content updates in place. Do not show a full-screen loading state on refresh.

### Scroll behavior

- Large titles collapse on scroll. Navigation bar becomes compact. This is automatic with `NavigationStack` + `.navigationTitle()`.
- Tab bar can hide on scroll for content-focused views (maps, reading). Use `.toolbarVisibility(.hidden, for: .tabBar)` cautiously - users need the tab bar for navigation.
- Scroll-to-top: tapping the status bar scrolls the active scroll view to the top. Do not interfere with this behavior.
- Rubber-banding: the system provides elastic bounce at scroll limits. Never disable or override it.
- Content insets: system automatically adjusts scroll content insets for safe areas, navigation bars, tab bars, and keyboard. Do not manually set insets unless handling a custom layout.

---

## 13. Liquid Glass (macOS 26 / iOS 26)

### What Liquid Glass is

Liquid Glass is a design paradigm introduced at WWDC 2025 (sessions 219, 323, 310, 356). It uses light lensing (bending and focusing light) rather than Gaussian blur. The effect creates a translucent, refractive glass appearance that reveals the content behind it while maintaining readability of overlaid controls.

### What you get for free (recompile only)

- Toolbar glass treatment
- Sidebar glass treatment (NavigationSplitView)
- Menu bar glass
- Dock glass
- Window traffic light controls
- Standard system controls (buttons, toggles, pickers in system chrome)
- Tab bar glass (iOS 26)
- Navigation bar glass (iOS 26)

### .glassEffect() modifier

```swift
.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
.glassEffect(.regular.tint(.blue), in: .capsule)
.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
```

**Variants:**
- `.regular`: Standard glass with moderate translucency. Use for floating controls, toolbars, sidebar items.
- `.clear`: More transparent, less frosted. Use for media-rich contexts where background visibility matters.
- `.identity`: No visual effect. Use for conditional application without layout changes.

**Tint:** `.tint(Color)` adds a color cast to the glass. Takes a `Color` value only, not `LinearGradient`.

**Interactive:** `.interactive()` adds a hover/press state to the glass element for button-like behavior.

### GlassEffectContainer

Groups multiple glass elements so they share a sampling region and can morph together when close enough.

```swift
GlassEffectContainer(spacing: 30) {
    Button("Edit") { }.glassEffect(.regular, in: .capsule)
    Button("Share") { }.glassEffect(.regular, in: .capsule)
}
```

- `spacing`: The distance threshold at which adjacent glass elements merge into a single continuous glass shape. Default is system-determined.
- Use for toolbar button groups, floating action clusters, and segmented control alternatives.
- Child glass elements appear to share the same glass pane when close together.

### .backgroundExtensionEffect()

Extends a view's content (mirrored and blurred) behind floating glass elements like sidebars.

```swift
NavigationSplitView {
    SidebarList()
} detail: {
    ScrollView {
        contentImage
            .backgroundExtensionEffect()
    }
    .ignoresSafeArea(edges: .top)
}
```

Apply to content that should visually extend behind the glass sidebar. Without this, the sidebar glass refracts a blank area.

### Button styles for Liquid Glass

- `.buttonStyle(.glass)`: Translucent glass button. Use for secondary actions in floating control layers.
- `.buttonStyle(.glassProminent)`: Opaque glass button. Use for primary actions in glass contexts.
- These replace `.bordered` and `.borderedProminent` in glass-aware contexts. In non-glass contexts, fall back to standard styles.

### Hard design rules for Liquid Glass

1. **Glass belongs on the navigation/control layer, not on content.** Toolbars, sidebars, floating action bars, and status overlays get glass. List rows, cards, content panels do not.
2. **Never stack glass on glass.** A glass button inside a glass sidebar is wrong (double blur is visually broken). The sidebar is already glass; controls within it should be opaque or `.borderless`.
3. **Never mix `.regular` and `.clear` variants in the same interface.** Pick one style for your app and use it consistently.
4. **Do not apply `.glassEffect()` to list rows or content items.** Glass is for chrome, not content.
5. **Do not paint opaque backgrounds on auto-glass surfaces.** If NavigationSplitView sidebar gets automatic glass, do not override it with `.background(Color.white)`. Use translucent tints if you need color: `.tint(Color.blue.opacity(0.1))`.
6. **SwiftUI materials (`.ultraThinMaterial` etc.) blur behind the window, not behind sibling views.** Do not confuse materials with glass. Don't use SwiftUI materials for glass effects.
7. **Sidebar content extends behind glass.** Use `.backgroundExtensionEffect()` on detail content so the glass sidebar has something to refract. Without it, the glass shows a blank edge.
8. **Floating controls over content use glass. Static chrome uses system-provided treatment.** Do not manually apply `.glassEffect()` to toolbars - the system already handles it.
9. **Don't use glass on text-heavy surfaces** (readability suffers).
10. **Don't mix glass with opaque overlays in the same layer.**
11. **Respect system Reduce Transparency setting.** When enabled, glass falls back to an opaque material. The system handles this automatically for built-in treatments; custom `.glassEffect()` usage also respects it.
12. **Test without glass.** Use `defaults write -g com.apple.SwiftUI.DisableSolarium -bool YES` to verify your app is usable without the effect.
13. **Content behind glass must remain readable.** Verify that text and icons over glass meet contrast requirements (3:1 for non-text, 4.5:1 for text).

### Migration checklist for existing apps

- Remove opaque sidebar backgrounds. Let the system glass show through.
- Add `.backgroundExtensionEffect()` to detail content columns.
- Replace custom toolbar blur with nothing (the system applies glass).
- Audit button styles: replace `.bordered` / `.borderedProminent` with `.glass` / `.glassProminent` in floating contexts.
- Test with both Reduce Transparency on and off.
- Verify contrast requirements over glass surfaces.

---

## 14. App lifecycle

### Launch experience

- Cold launch to interactive content: target under 400ms. Absolute maximum: 3 seconds before the system watchdog terminates the app on iOS.
- Launch screen: use a static launch storyboard or SwiftUI scene that matches the app's initial screen structure (same background color, layout skeleton). No logos, no loading screens, no splash art.
- The launch screen should be a simplified, empty version of the first screen. This creates the illusion of instant loading.
- Defer non-critical initialization to after first frame. Pre-warm: load cached data, defer network requests.
- On macOS, there is no launch screen. The window appears when ready. Show the window shell immediately and load content asynchronously.
- Do not show onboarding or login on every launch. Show it once, then go straight to content.
- Restore the previous state: the last open document, the last selected tab, the scroll position.

### Onboarding

- Onboarding is optional and should be skippable. Provide a "Skip" button on every onboarding screen.
- Maximum 3-5 onboarding screens. Each communicates one idea.
- Onboarding explains value ("what you can do"), not mechanics ("tap here to..."). Users figure out standard patterns themselves.
- Request permissions (notifications, location, camera) in context when they're needed, not during onboarding. Explain why you need the permission in the system dialog's purpose string.
- Show onboarding once per install. Never again unless the user explicitly requests it (Help > Getting Started or similar).
- On macOS, onboarding is typically a single welcome window or sheet on first launch. Not a full-screen flow.

### State restoration

- iOS: implement `NSUserActivity`-based state restoration or SwiftUI's `@SceneStorage` to restore navigation state, scroll position, and unsaved input.
- macOS: implement state restoration through `NSWindowRestoration` or SwiftUI's `@SceneStorage`. Window positions, sizes, and contents should restore exactly.
- Use `NSUserActivity` for handoff-compatible state.
- Restore the exact state the user left - which tab, which item selected, scroll position.
- Unsaved work must survive a background termination on iOS. Use `UIDocument`, Core Data auto-save, or periodic background saves.
- Never ask "Do you want to restore your session?" Just restore it silently. The user expects continuity.

### Backgrounding (iOS)

- When the app enters background: save state, stop unnecessary work, release resources.
- Background tasks: use `BGTaskScheduler` for deferred work. Declare background modes only for continuous needs (audio, location, VOIP).
- Do not continue UI updates in the background. They waste battery and the user can't see them.
- Don't play audio or use location unless the user expects it.
- Time limit: approximately 5 seconds of execution time after entering background before the system suspends the app. Request extended time with `UIApplication.beginBackgroundTask()` for up to 30 seconds.
- Background app refresh: respect the user's setting. If disabled, do not schedule background tasks.

### Termination

- On iOS, the user does not manually quit apps in normal use. The system manages app lifecycle. Design for this.
- On macOS, Cmd+Q quits the app. Auto-save all user work before termination.
- No "Save changes?" dialogs for simple data - just save. Document-based apps: standard save/don't save/cancel dialog only for untitled documents.
- Do not show "Are you sure you want to quit?" dialogs unless there is genuinely unsaved work that would be lost.
- On macOS, the app can stay running when all windows are closed (dock icon remains). This is appropriate for apps that do background work (mail, messaging). For document-based apps, quitting when the last window closes is acceptable (use `applicationShouldTerminateAfterLastWindowClosed`).
- Clean up temporary files.
- Crash recovery: on next launch after a crash, do not re-enter the same state that caused the crash. Clear the offending state and show a clean starting point. Log the crash context for diagnostics.

---

## Appendix A: minimum sizes and spacing quick reference

| Element | iOS minimum | macOS minimum |
|---|---|---|
| Touch/click target | 44x44pt | 24x24pt |
| Button height | 44pt (text button) | 21pt (small) / 24pt (regular) |
| Text field height | 36pt | 21pt |
| List row height | 44pt | 24pt (small) / 28pt (regular) |
| Tab bar height | 49pt (83pt with home indicator) | n/a |
| Navigation bar height | 44pt content + status bar | n/a |
| Toolbar height | n/a | 52pt (38pt compact) |
| Sidebar width | n/a | 200pt minimum |
| Standard margin | 16pt | 20pt |
| Standard padding | 16pt | 12-16pt |
| Inter-element spacing | 8pt | 8pt |
| Section spacing | 24-32pt | 16-24pt |
| Minimum body text | 17pt (body style) | 13pt (body style) |
| Minimum caption text | 12pt | 10pt |
| Icon in toolbar | 22pt | 16pt |

## Appendix B: system font weight mapping

| SwiftUI weight | UIFont weight | CSS weight | SF Pro value |
|---|---|---|---|
| `.ultraLight` | `.ultraLight` | 100 | -0.80 |
| `.thin` | `.thin` | 200 | -0.60 |
| `.light` | `.light` | 300 | -0.40 |
| `.regular` | `.regular` | 400 | 0.00 |
| `.medium` | `.medium` | 500 | 0.23 |
| `.semibold` | `.semibold` | 600 | 0.30 |
| `.bold` | `.bold` | 700 | 0.40 |
| `.heavy` | `.heavy` | 800 | 0.56 |
| `.black` | `.black` | 900 | 0.62 |

## Appendix C: animation timing reference

| Animation type | Duration | Curve | Example |
|---|---|---|---|
| Button press/release | 0.05-0.1s | ease-out | State change highlight |
| Toggle state change | 0.2s | spring | Boolean state change |
| View transition (push/pop) | 0.35s | ease-in-out | Navigation stack |
| Sheet present | 0.3s | spring (damping 0.86) | Modal presentation |
| Sheet dismiss | 0.25s | ease-in | Modal dismissal |
| Fade in | 0.15-0.2s | ease-out | Element appearance |
| Fade out | 0.15s | ease-in | Element removal |
| State change cross-fade | 0.15-0.2s | ease-in-out | Content update |
| Scale transition | 0.2-0.25s | spring(response: 0.3) | Element enter/exit |
| Toolbar show/hide | 0.25s | ease-in-out | Scroll-triggered |
| Sidebar collapse/expand | 0.25-0.3s | spring | Column visibility |
| Skeleton shimmer | 1.5s | linear, repeat | Loading placeholder |
| Progress update | 0.2s | ease-out | Bar fill |
| Collapse/expand | 0.25-0.3s | ease-in-out | Disclosure |
| Tooltip appear | 0.2s | ease-out | Hover info |
| Toast appear | 0.3s | spring | Notification banner |
| Toast auto-dismiss | 4-8s | - | Auto-hide delay |
| Reduced Motion fallback | 0.2s | linear crossfade | All transitions |

## Appendix D: semantic color usage matrix

| Context | Light background | Dark background | High contrast light | High contrast dark |
|---|---|---|---|---|
| Primary text | #000000 | #FFFFFF | #000000 | #FFFFFF |
| Secondary text | #3C3C43 (60%) | #EBEBF5 (60%) | #3C3C43 (68%) | #EBEBF5 (68%) |
| Tertiary text | #3C3C43 (30%) | #EBEBF5 (30%) | #3C3C43 (38%) | #EBEBF5 (38%) |
| Separator | #3C3C43 (29%) | #545458 (65%) | #3C3C43 (37%) | #545458 (75%) |
| Fill (primary) | #787880 (20%) | #787880 (36%) | #787880 (28%) | #787880 (44%) |
| Fill (secondary) | #787880 (16%) | #787880 (32%) | #787880 (24%) | #787880 (40%) |
| Fill (tertiary) | #767680 (12%) | #767680 (24%) | #767680 (20%) | #767680 (32%) |
| System background | #FFFFFF | #000000 | #FFFFFF | #000000 |
| Secondary background | #F2F2F7 | #1C1C1E | #F2F2F7 | #1C1C1E |
| Tertiary background | #FFFFFF | #2C2C2E | #FFFFFF | #2C2C2E |
| Grouped background | #F2F2F7 | #000000 | #F2F2F7 | #000000 |
| Secondary grouped | #FFFFFF | #1C1C1E | #FFFFFF | #1C1C1E |
| Tertiary grouped | #F2F2F7 | #2C2C2E | #F2F2F7 | #2C2C2E |
| Link / accent | #007AFF | #0A84FF | #007AFF | #0A84FF |
| Destructive | #FF3B30 | #FF453A | #FF3B30 | #FF453A |
| Success | #34C759 | #30D158 | #34C759 | #30D158 |
| Warning | #FF9500 | #FF9F0A | #FF9500 | #FF9F0A |
