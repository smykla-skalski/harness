---
name: swiftui-design-rules
description: SwiftUI/macOS UX rules covering accessibility (VoiceOver, Dynamic Type, contrast, target sizes), visual design (typography, 8pt spacing, color, dark mode, motion timing), interaction patterns (feedback, loading states, destructive actions, forms, truncation, notifications), and performance targets (60fps, launch time, scroll, memory). Invoke when writing or reviewing SwiftUI views, forms, lists, or any visible UI surface in apps/harness-monitor-macos.
---

# SwiftUI design rules

Hard requirements for any SwiftUI view surface in `apps/harness-monitor-macos`. Every feature ships meeting these rules or it doesn't ship.

## Accessibility

Every feature ships accessible or it doesn't ship. These are hard requirements, not suggestions.

### VoiceOver

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

### Dynamic Type

- All text uses text styles (`.font(.body)`), never hardcoded sizes (`.font(.system(size: 16))`).
- Use `@ScaledMetric` for non-text dimensions that should scale (icon sizes, spacing, container heights).
- Layouts must reflow at accessibility sizes: HStack becomes VStack. Use `@Environment(\.dynamicTypeSize)` with `.isAccessibilitySize` or `ViewThatFits`.
- Text that truncates at AX3+ is a bug. Fix the layout.
- Never clamp text below the user's chosen size.
- Test at: default (Large), XXL (largest non-accessibility), AX3 (mid-range), AX5 (largest).

### Color and contrast

- WCAG 2.1 AA minimum: 4.5:1 for normal text (< 18pt), 3:1 for large text (18pt+ or 14pt+ bold), 3:1 for UI components (icons, borders, focus rings).
- Aim for AAA: 7:1 normal text, 4.5:1 large text.
- Never convey information by color alone. Always pair with icon, text, or pattern.
- Status indicators: color + icon + text label. Not just a colored dot.
- Error fields: red border + error icon + error message text.
- Every custom color needs light AND dark variants meeting contrast requirements.
- Test with Accessibility Inspector for contrast ratios.

### Reduce Motion

- Check `@Environment(\.accessibilityReduceMotion)`.
- Replace slide/spring/bounce with crossfade or instant when enabled.
- Disable parallax and auto-playing animations.
- Keep essential state feedback (progress bars, selection highlights, opacity changes).
- Reduce Motion does not mean no animation - simple fades are fine.

### Reduce Transparency

- Check `@Environment(\.accessibilityReduceTransparency)`.
- Every translucent surface needs a solid-color fallback.
- Glass effects (Liquid Glass) need opaque alternatives.
- Blur overlays need solid-color backgrounds when transparency is reduced.

### Increase Contrast

- Check `@Environment(\.colorSchemeContrast)` for `.increased`.
- Thicker borders (1pt -> 2pt), higher opacity separators, more opaque backgrounds.
- System colors auto-provide high-contrast variants. Custom colors must too (asset catalog).

### Keyboard navigation (macOS)

- Every interactive element reachable via Tab key.
- Tab order follows visual layout: top-to-bottom, leading-to-trailing.
- Arrow keys navigate within groups (lists, grids, segmented controls).
- Visible focus ring on focused element. Never hide the system focus ring.
- Return/Enter activates the default/primary action.
- Escape dismisses modals, sheets, popovers.
- Space toggles checkboxes and buttons.
- No focus traps - user can always Tab out.

### Target sizes

- iOS: 44x44pt minimum touch target. No exceptions.
- macOS: 24x24pt minimum click target with 4pt+ spacing between targets.
- If visual element is smaller, expand hit area with `.contentShape(Rectangle())` and a larger `.frame()`.
- No tiny close buttons (12x12pt X is a violation).

### Cognitive accessibility

- Simple, clear language. No jargon in user-facing text.
- Consistent navigation across the entire app.
- No time pressure for decisions (no auto-advancing, no countdown timers).
- Undo for all destructive actions.
- Don't clear forms on error.

### Accessibility environment values reference

| Value | Type | Check for |
|---|---|---|
| `\.accessibilityReduceMotion` | Bool | Replace animations |
| `\.accessibilityReduceTransparency` | Bool | Opaque fallbacks |
| `\.colorSchemeContrast` | ColorSchemeContrast | `.increased` = boost contrast |
| `\.legibilityWeight` | LegibilityWeight | `.bold` = heavier weights |
| `\.dynamicTypeSize` | DynamicTypeSize | Layout adaptation |
| `\.accessibilityDifferentiateWithoutColor` | Bool | Don't rely on color alone |

## Visual design

### Typography

- Use text styles (`.body`, `.headline`, `.caption`), not hardcoded point sizes.
- Maximum 2-3 font weights per screen to establish hierarchy.
- Line length: 50-75 characters for body text (70 optimal). Constrain with `.frame(maxWidth:)`.
- Left-align body text. Never justify on screens.
- Numbers in tables/lists: `.monospacedDigit()` for column alignment.
- ALL CAPS only for short labels (2-3 words) with tracking adjustment.
- Monospace (SF Mono) for: code, terminal output, IDs, hashes, file paths, IP addresses.
- Minimum readable text: 11pt (iOS body=17pt, macOS body=13pt). Never smaller.

#### Text style sizes (iOS / macOS)

| Style | iOS | macOS | Use |
|---|---|---|---|
| `.largeTitle` | 34pt | 26pt | Screen headers (one per screen) |
| `.title` | 28pt | 22pt | Section headers |
| `.title2` | 22pt | 17pt | Subsection headers |
| `.title3` | 20pt | 15pt | Card titles |
| `.headline` | 17pt SB | 13pt B | Emphasized body |
| `.body` | 17pt | 13pt | Primary content |
| `.subheadline` | 15pt | 11pt | Supplementary labels |
| `.footnote` | 13pt | 10pt | Timestamps, metadata |
| `.caption` | 12pt | 10pt | Auxiliary info |

### Color

- Use semantic system colors (`.primary`, `.secondary`, `.accent`, `.background`) that auto-adapt to light/dark mode.
- 60-30-10 rule: 60% background, 30% secondary surface, 10% accent color.
- Status colors: red = error/destructive, orange = warning, yellow = caution, green = success, blue = info/link, gray = inactive/disabled.
- One accent color per app for interactive elements (buttons, links, toggles, selection).
- Never use color as the sole indicator of meaning - pair with icon, text, or pattern.

### Dark mode

- Not just color inversion. Elevated surfaces get lighter (depth reversal).
- No pure black (#000000) for macOS backgrounds. Use system dark colors (~#1C1C1E).
- System colors auto-adapt. Always use system or asset-catalog colors with light/dark variants.
- Shadows are ineffective in dark mode. Use surface elevation and subtle borders instead.
- Test every screen in both modes, with Increase Contrast enabled.

### Spacing (8-point grid)

All spacing in multiples of 4pt (ideally 8pt):

| Token | Value | Use |
|---|---|---|
| xs | 4pt | Icon-to-label, tight element spacing |
| sm | 8pt | Within groups, related items |
| md | 12pt | Compact container padding |
| base | 16pt | Standard padding, margins (iOS 16pt, macOS 20pt) |
| lg | 24pt | Between sections |
| xl | 32pt | Major section breaks |
| xxl | 48pt | Screen-level separation |

- Within-group spacing at most 50% of between-group spacing (Gestalt proximity).
- Example: 8pt between items in a group, 24pt between groups.
- Form fields: 3-5 per section, 16pt between fields, 32pt between sections.

### Layout

- Use `.leading`/`.trailing`, never `.left`/`.right` (RTL support).
- Right-align numbers in columns. Left-align text. Center-align only for buttons, badges, empty states.
- Safe areas: always respect. Use `.ignoresSafeArea()` only for background content.
- Content width: constrain body text to ~680pt max on wide screens.

### Icons (SF Symbols)

- Prefer SF Symbols over custom icons when a matching symbol exists.
- Match symbol weight to adjacent text weight.
- Let symbols size with text styles (`.font(.body)`), not explicit frame sizing.
- Filled variants for selected state, outline for unselected (tab bars).
- Icon-to-label spacing: 6-8pt.

### Motion

- Default animation duration: 200-350ms. Never exceed 500ms for UI transitions.
- Easing: ease-out for entry, ease-in for exit, ease-in-out for within-screen movement.
- Spring for interactive elements: `response: 0.3-0.5, dampingFraction: 0.6-0.85`.
- Cross-fade for state changes: 150-200ms.
- Respect Reduce Motion: replace movement with crossfade or instant.
- Don't animate everything - only meaningful state changes.

#### Animation timing reference

| Type | Duration | Curve |
|---|---|---|
| Button press | 50-100ms | ease-out |
| Toggle/state change | 200ms | spring |
| View push/pop | 350ms | ease-in-out |
| Sheet present | 300ms | spring |
| Sheet dismiss | 250ms | ease-in |
| Fade in/out | 150-200ms | ease-in-out |
| Skeleton shimmer | 1500ms | linear, repeat |
| Toast auto-dismiss | 4-8s | - |

### Depth and elevation

- Subtle shadow (cards): 0pt x 1pt blur 3pt, black 8-10% opacity.
- Medium shadow (popovers): 0pt x 4pt blur 12pt, black 12-15% opacity.
- Heavy shadow (modals): 0pt x 8pt blur 24pt, black 15-20% opacity.
- Modal overlay background: dim to 40-60% black opacity.
- Border radius: pick one and use it everywhere (8pt default). Inner radius = outer radius - padding.

### Density

- Compact: 28pt row height (macOS), 36pt (iOS), 8pt padding.
- Regular: 36pt row height (macOS), 44pt (iOS), 12pt padding.
- iOS minimum list row height: 44pt. macOS: 28pt.

## Interaction

### Feedback

- Every user action gets visual feedback within 100ms (1 frame at 60fps).
- Button press: immediate visual state change (color, scale 0.97x) on touch-down, not touch-up.
- Toggle: animation starts within 1 frame.
- Text input: character appears same frame as keystroke.
- Operations > 1 second: show spinner with label.
- Operations > 2 seconds: show progress bar if progress is known.
- Operations > 5 seconds: show cancel button.
- Operations > 10 seconds: show progress bar with percentage/count, cancel mandatory.

### Loading states

- Never show a blank screen. Always indicate something is happening.
- Skeleton screens for known layouts: gray rectangles matching final dimensions, shimmer animation (1500ms cycle).
- Skeleton must match final layout exactly (prevent layout shift).
- Replace skeleton with content via crossfade (200ms).
- Spinner: indeterminate short waits under 5 seconds. Don't show for operations under 100ms.
- Progress bar: determinate operations. Never go backwards. Smooth updates.
- Mark skeleton views as `.accessibilityHidden(true)`.

### Error messages

- Structure: what happened + why + what to do next.
- No error codes, HTTP status codes, or stack traces in user-facing messages. Log them.
- Don't blame the user: "Password must be 8+ characters" not "Invalid password".
- Placement: inline near the source. Not modal alerts for form errors.
- Errors persist until corrected. Never auto-dismiss error messages.
- Include recovery action: button ("Retry", "Open Settings") or specific instruction.
- VoiceOver: announce errors immediately with the content.

### Empty states

- Use `ContentUnavailableView` (iOS 17+/macOS 14+).
- First-use: explain what appears here + primary action to get started.
- No-results: acknowledge search + suggest fixes + "Clear filters" button.
- Error: what went wrong + [Retry] button.
- All follow: icon + headline + description + primary action button.

### Destructive actions

Safeguard hierarchy (prefer higher):
1. Undo with toast (8-10 seconds) - best UX
2. Confirmation dialog with specific language
3. Type-to-confirm for high-impact irreversible actions

Rules:
- Confirmation title: specific with count ("Delete 3 items?") not generic ("Are you sure?").
- Destructive button: red, labeled with the verb ("Delete", not "OK"). Use `Button("Delete", role: .destructive)`.
- Cancel is always the default button (Return/Enter activates it).
- Never "Yes/No" buttons. Name the action.
- Never place destructive buttons adjacent to frequently used buttons.
- Prefer soft delete (trash) over permanent delete.

### Form validation

- Validate on blur (field loses focus), not every keystroke.
- Validate all on submit as safety net. Scroll to first error, focus it.
- Don't mark fields as invalid before user interaction.
- Inline error below the field, not in modal alerts. Show what's expected, not what's wrong.
- Required fields: mark optional ones ("Optional"). Assume required by default.
- Preserve all user input on error. Never clear the form.
- Disable button during processing to prevent double-submission.

### Data entry

- Labels visible above fields. Placeholder is not a label (it disappears on input).
- Set `.keyboardType()` appropriately on iOS: `.emailAddress`, `.URL`, `.numberPad`.
- Set `.textContentType()` for autofill: `.emailAddress`, `.password`, `.name`.
- Set `.autocorrectionDisabled()` for usernames, code, IDs.
- Search: debounce at 300ms, show results within 500ms, show result count.
- Recent entries: show last 5-10 used values.

### Data display

#### Numbers and dates
- Locale-aware formatting. Use system formatters (FormatStyle), not hardcoded formats.
- Large numbers: abbreviate (1.2K, 3.4M) with tooltip for exact value.
- Relative time: "Just now" (< 1 min), "5 minutes ago" (< 1h), "3 hours ago" (< 24h), absolute date after 7 days.
- Duration: "1h 23m" for short, "2 days, 3 hours" for longer.
- File sizes: human-readable (1.2 GB, 342 KB). Use ByteCountFormatter.
- Zero items: show empty state, not "0 items" in a list.
- Singular/plural: "1 item" not "1 items". Use localized plural rules.

#### Tables and lists
- Text left-aligned, numbers right-aligned, status centered.
- Column headers: bold/semibold, sticky during scroll.
- Sort indicators: filled arrow on sorted column, click to reverse.
- List row minimum height: 44pt (iOS), 28pt (macOS).

#### Truncation
- Single line: ellipsis at tail. Filenames: middle truncation ("my_very_lo...ument.pdf").
- Multi-line: clamp to 2-3 lines with "Show more" or tooltip for full text.
- Never silently truncate without visual indicator.
- Technical values (IDs, hashes, URLs): tap/click to copy with "Copied" confirmation.

#### Status indicators
- Green: active/success. Orange: warning. Red: error/critical. Blue: info/in-progress. Gray: inactive.
- Always include text label alongside color (don't rely on color alone).
- Badge counts: cap display at "99+".

### Notifications (in-app)

- Toast/banner: auto-dismiss after 4-8 seconds, manually dismissable, non-blocking.
- Stack newest on top, max 3 visible.
- Errors: persistent until resolved. Don't auto-dismiss.
- Success: informational only, don't require acknowledgment.

### Offline and connectivity

- Non-modal offline banner, not a modal alert.
- Show cached data with "Last updated" timestamp.
- Queue writes when offline, sync on reconnect.
- Auto-dismiss offline banner when reconnected.

### Undo

- Minimum 20 levels of undo (Cmd+Z / Cmd+Shift+Z).
- Name actions in Edit menu: "Undo Delete" not just "Undo".
- Group related operations (continuous typing until 2-second pause).
- Preserve undo stack across saves.

## Performance targets

### Response time thresholds

| Duration | Perception | Required UI |
|---|---|---|
| 0-100ms | Instantaneous | No feedback needed |
| 100ms-1s | Noticeable | Subtle indicator (button state, toolbar spinner) |
| 1-10s | Attention wanders | Spinner with label, allow cancel at 5s |
| 10s+ | Context lost | Progress bar with count/percentage, cancel mandatory |
| 30s+ | Patience gone | Progress bar + estimated time, allow background |

### Animation

- 60fps minimum (16.67ms frame budget). 120fps on ProMotion (8.33ms).
- A single dropped frame is perceptible during smooth animation.
- Never block the main thread for more than 16ms.
- Profile with Instruments: SwiftUI template, Time Profiler, Core Animation.

### Launch time

- Cold launch to first meaningful content: under 400ms.
- Show cached/local data first, refresh from network in background.
- Defer non-critical initialization to after first frame.
- No synchronous network calls at launch.

### Scroll performance

- 60fps during scroll at all times.
- Use List for 50+ items (cell recycling).
- Image loading: placeholder -> async load -> fade in. Never block cell layout.
- Prefetch next page when within 5 items of the end.
- Avoid GeometryReader, large blur shadows, and complex opacity per cell.

### Main thread budget

- UI rendering, user input, animation only on main thread.
- Background threads for: network, disk I/O, image processing, JSON parsing, crypto.
- Use `.task` modifier for view-tied async work (auto-cancels on disappear).
- Use actors for isolated mutable state.
- Check `Task.isCancelled` in long-running loops.

### Network UI patterns

- Optimistic updates for non-destructive actions (toggle favorite, send message): update UI immediately, revert on server error.
- Stale-while-revalidate: show cached data immediately, fetch fresh in background.
- Skeleton screens: show immediately on navigation, match final layout.
- Auto-retry transient errors with exponential backoff: 1s, 2s, 4s, 8s, max 30s. Max 3 retries.
- Don't auto-retry permanent errors (4xx, auth failures).
- Network timeout: 30 seconds default.
- Cancel button always available for operations over 2 seconds.

### Memory

- Downsample images to display size before rendering.
- Cache tiers: memory (NSCache, auto-purges) -> disk -> network.
- Image memory cache: 50-100MB max.
- Cancel tasks when views disappear (`.task` does this automatically).
- Avoid retain cycles: `[weak self]` in closures that capture self.

### Battery

- No timer-based polling when push/streams are available.
- Coalesce network requests.
- Respect Low Power Mode: reduce animations, defer background work.
- Minimize GPU overdraw (don't stack transparent layers).

### Perceived speed

- Show text before images (smaller, faster).
- Preload likely next screen during idle.
- Reserve space for content before it loads (prevent layout shift).
- Stagger content appearance: 30-50ms per item, max 5 items staggered.
- Animate transitions to mask loading time (300ms transition covers 300ms of loading).

### Auto-save

- Save on every meaningful change (debounce 500ms-2s, not every keystroke).
- Save immediately on app backgrounding (iOS) and window close (macOS).
- Restore state after crash: window position, scroll, selection, navigation stack, pending input.
- Use `@SceneStorage` for per-window state, `NSUserActivity` for handoff.

## Research backing

Rationale and edge-case research for these rules lives under `apps/harness-monitor-macos/docs/research/ux/`:

- `04-accessibility-requirements.md` - VoiceOver, Dynamic Type, contrast, target size sources
- `03-visual-design-fundamentals.md` - typography, color, 8pt grid origins
- `02-interaction-design-patterns.md` - feedback, errors, forms, destructive actions
- `07-performance-responsiveness.md` - response time thresholds, 60fps budget
- `06-ux-psychology-usability.md` - cognitive load, Gestalt grouping
- `08-error-handling-edge-cases.md` - error message wording and placement
- `09-data-display-patterns.md` - tables, numbers, truncation
- `10-onboarding-user-flows.md` - first-use empty states
