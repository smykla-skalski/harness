# Interaction design patterns - comprehensive reference

## 1. Direct manipulation

### Drag and drop
- Visual feedback on drag start: lift element with shadow, slight scale (1.05x), reduce opacity of source (0.5)
- Drop target highlighting: change background color or show dashed border (2pt, accent color)
- Drop zones: minimum 44x44pt on iOS, 32x32pt on macOS
- Cancel drag: Escape key (macOS) or drag to invalid zone (return to source with spring animation)
- Multi-select drag: show count badge on dragged item cluster
- Use .draggable and .dropDestination modifiers in SwiftUI
- Provide UTType conformance for cross-app drag operations

### Resize and reorder
- Drag handles visible on hover (macOS) or edit mode (iOS)
- Resize handles: corners and edges, cursor changes to resize cursor
- Minimum resize: 100x100pt for panels/columns, don't let elements collapse to invisible
- Snap-to-grid: 8pt increments when resizing manually
- Reorder: show insertion indicator (2pt blue line) between items at proposed position
- Animate items making room during reorder (200ms, ease-in-out)

### Inline editing
- Double-click to edit (macOS), tap to edit (iOS) for text in tables/lists
- Visual change: field border appears, text becomes editable, cursor placed at end
- Confirm: Return/Enter or clicking away
- Cancel: Escape key restores previous value
- Don't require a separate edit mode for single-field changes

### Undo/redo
- Support at least 20 levels of undo
- Cmd+Z / Cmd+Shift+Z (macOS), shake to undo (iOS)
- Group related operations: e.g., "typing" groups until pause > 2 seconds
- Undo after destructive actions: "Item deleted. Undo" toast for 5-8 seconds
- Always preserve undo stack across saves
- Name undo actions: "Undo Delete", "Undo Paste", not just "Undo"

### Destructive action confirmation
- Preference order: (1) undo with toast > (2) confirmation dialog > (3) type-to-confirm
- Confirmation dialog text: specific ("Delete 3 photos permanently?"), not generic ("Are you sure?")
- Destructive button: red, labeled with the action verb ("Delete", not "OK")
- Cancel button: always present, always the default button
- For high-impact irreversible actions: type the resource name to confirm

## 2. Progressive disclosure

### Hiding complexity
- Show 3-5 most common options by default
- "Advanced" or "More options" disclosure for power-user settings
- Don't hide options that users need frequently (watch analytics)
- First-time users see simplified view, power users can enable advanced mode

### Reveal on demand
- Disclosure triangle/chevron for expandable sections (macOS convention)
- Expand/collapse animation: 250ms ease-in-out
- Remember expand/collapse state per section across sessions
- Don't nest more than 2 levels of disclosure (3 max in file trees)

### Expandable sections
- Show item count when collapsed: "Filters (3 active)"
- Chevron rotates 90 degrees on expand
- Click anywhere on the header to toggle, not just the chevron
- Minimum header height: 44pt (iOS), 28pt (macOS)

### Detail panels and inspectors
- Show supplementary detail in a side panel, not modal
- Panel width: 240-320pt, collapsible
- Content updates based on selection in the main view
- Toggle with keyboard shortcut (Cmd+I or similar)

## 3. Fitts's Law

### Core rule
- Time to reach a target = f(distance / size). Larger targets closer to the cursor are faster to hit.

### Target sizing
- iOS touch targets: 44x44pt minimum, 48x48pt preferred
- macOS click targets: 24x24pt minimum, with 4pt+ between adjacent targets
- If visual element is smaller, expand the hit area: .contentShape(Rectangle()) with larger frame
- Toolbar buttons: 28x28pt visual, 44x44pt hit area
- Small text links: pad the tappable area to 44pt height minimum

### Edge and corner targeting (macOS)
- Menus at screen edges are infinitely tall targets - use screen edges for primary navigation
- Menu bar: top edge, infinitely targetable from above
- Dock: bottom/side edge, same benefit
- Window corners: resize handles benefit from corner targeting
- Don't place frequently-used actions in the center of large empty spaces

### Distance minimization
- Context menus (right-click) appear at cursor - zero travel distance
- Toolbars near the content they affect
- Inline actions near the item they modify (edit button in a row, not only in toolbar)
- Confirmation dialogs: buttons near the mouse position, not always centered in screen
- Floating action button: persistent, at a predictable screen position

### Toolbar placement
- macOS: toolbar at top of window, most-used tools leftmost
- iOS: bottom toolbar for thumb-reachable actions
- Group related tools together with separators
- Don't put destructive actions next to frequent actions (accidental clicks)

## 4. Hick's Law

### Core rule
- Decision time increases logarithmically with the number of choices. Fewer choices = faster decisions.

### Reducing choice overload
- Maximum 7 +/- 2 options in a single group without subgrouping
- Menus: maximum 12-15 items per section, use separators at 5-7 item intervals
- Settings screens: 5-7 items per section before splitting into subsections
- Tab bars: maximum 5 tabs (iOS), 6-8 tabs (macOS settings)

### Grouping options
- Group by function, not alphabetically
- Use visual separators between groups
- Section headers describe the group purpose
- Most-used options first within each group

### Smart defaults
- Pre-select the most common or recommended option
- Mark recommended option: "Recommended" label, or visual emphasis
- Remember the user's last choice for repeated operations
- "Most recent" or "Frequently used" section in long lists
- Sort options by predicted relevance, not just alphabetically

### Progressive choices
- Don't ask for all preferences upfront
- Collect information as needed during natural workflow
- "Default + customize later" pattern for settings

## 5. Miller's Law

### Core rule
- Working memory holds approximately 7 +/- 2 items. Group information into chunks of 3-5 items for comprehension.

### Chunking information
- Phone numbers: 555-123-4567 (chunks of 3-4)
- Credit cards: 4 groups of 4 digits
- Lists longer than 7 items: break into categorized groups
- Navigation menus: 3-5 top-level categories with sub-items
- Form sections: 3-5 fields per section

### Pagination vs infinite scroll vs load more
- Pagination: for structured data (search results, admin tables) - show page count
- Infinite scroll: for feed/timeline content - show loading indicator at bottom
- Load more button: compromise - user controls when more content loads
- Page size: 20-50 items per page (25 default for tables)
- Always show total count: "1-25 of 342 items"

### Grouping in lists
- Section headers for natural category boundaries
- Alphabetical index for long alphabetized lists (contacts)
- Sticky headers during scroll
- Visual separator between groups: 8-12pt spacing or hairline divider

## 6. Feedback loops

### Immediate visual feedback (under 100ms)
- Button press: background color change, slight scale (0.97x), haptic (iOS)
- Toggle: switch position change begins immediately
- Selection: highlight color applied within one frame
- Drag: element lifts and follows finger/cursor on same frame
- Text input: character appears on same frame as keystroke

### State transitions (100-300ms)
- View push/pop: 350ms slide animation
- Sheet present/dismiss: 300ms/250ms
- Disclosure expand/collapse: 250ms
- Tab switch: cross-fade 200ms or no animation
- Toggle animation: 200ms spring

### Success indication
- Checkmark animation: 300ms, green color
- Toast/banner: slide in from top, persist 4-5 seconds
- Haptic: .success feedback (iOS)
- Sound: system completion sound (optional)
- Don't require acknowledgment for success - informational only

### Error indication
- Inline: red border on field + error message below
- Banner: red/orange banner at top of relevant section
- Haptic: .error feedback (iOS)
- VoiceOver: announce error immediately
- Error persists until corrected - don't auto-dismiss errors

### Progress communication
- Under 2 seconds: spinner/activity indicator only
- 2-10 seconds: spinner with "Loading..." text
- Over 10 seconds: progress bar with percentage or item count
- Over 30 seconds: progress bar + estimated time remaining
- Always show cancel button for operations over 5 seconds
- Update progress smoothly (don't let it jump or go backwards)

## 7. Error prevention

### Constraints
- Type-appropriate input fields: number pad for numbers, email keyboard for email
- Date pickers instead of free-text date entry
- Dropdowns instead of free-text for known option sets
- Character limits shown: "42/280 characters"
- Disable submit button until form is valid (with explanation of what's missing)

### Input validation timing
- Format hints: show expected format as placeholder or helper text before input
- Live validation: after field blur (not during typing for complex validation)
- Keystroke validation: only for simple character restrictions (numbers only, no special chars)
- Submit validation: validate all fields, scroll to first error, focus it

### Safe defaults
- New documents: untitled, auto-saved
- Preferences: most common/safest option pre-selected
- Filters: "All" selected by default, not an empty/zero state
- Permissions: least privilege by default
- Destructive options: never the default button

### Undo over confirm
- Prefer undo (recoverable) over confirmation (interruptive)
- Example: delete email -> move to trash -> "Undo" toast. Not: "Are you sure?" dialog
- Undo available for 8-10 seconds minimum after destructive action
- Only use confirmation for truly irreversible actions (permanent delete, send money)

## 8. Error recovery

### Clear error messages
- Structure: "What happened" + "Why" + "What to do"
- Bad: "Error 422: Unprocessable Entity"
- Good: "This email address is already registered. Try signing in instead, or use a different email."
- Include specific action: button "Sign in instead" or "Try again"
- Don't blame the user: "The password must be at least 8 characters" not "You entered a bad password"

### Suggested fixes
- Form errors: show exactly what's expected ("Enter a date in MM/DD/YYYY format")
- Search: "No results for 'moniter'. Did you mean 'monitor'?"
- Network: "Can't connect. Check your internet connection and try again. [Retry]"
- Permission: "Camera access is needed to scan QR codes. [Open Settings]"

### Retry mechanisms
- Manual retry button always available after errors
- Auto-retry for network errors: exponential backoff (1s, 2s, 4s, 8s, max 30s)
- Maximum auto-retries: 3-5 attempts before giving up with manual retry option
- Show retry attempt: "Retrying... (attempt 2 of 3)"
- Preserve user input across retries - never clear the form on error

### Graceful degradation
- Feature unavailable: show message with expected resolution ("This feature requires iOS 17+")
- Partial failure: load what you can, show inline errors for failed parts
- Offline: read-only mode with cached data, queue writes
- Timeout: show last known state with "Last updated 5 minutes ago"

## 9. Consistency

### Internal consistency
- Same action should look and work the same everywhere in your app
- Delete is always red, always has the same icon, always confirms the same way
- Navigation pattern: if drill-down in one list, drill-down in all lists
- Date format: same everywhere in the app
- Icon meaning: if a gear means settings in one place, it means settings everywhere

### Platform consistency
- Use system controls, not custom lookalikes
- Follow platform navigation patterns (back button, tab bar, sidebar)
- Standard keyboard shortcuts (macOS: Cmd+C/V/X/Z, Cmd+,)
- System dialogs for permissions, sharing, file picking
- Native date/time pickers, not custom

### Terminology
- One word for one concept throughout: don't alternate "delete/remove/trash"
- Match platform language: "Settings" (iOS) / "Preferences" (macOS pre-Ventura) / "Settings" (macOS Ventura+)
- Button labels match menu item labels for same action
- Use user-facing language, not developer jargon

## 10. Affordances and signifiers

### Making interactive elements obvious
- Buttons look like buttons: bordered, filled, or clearly styled differently from text
- Links in text: underlined or colored (accent color), cursor changes on hover (macOS)
- Tappable items: visual indicator (chevron, disclosure arrow)
- Text fields: visible border or background color distinguishing from labels
- Sliders: track + thumb clearly interactive

### Hover states (macOS)
- Background color change (subtle, 5-10% opacity accent)
- Cursor change: pointer for buttons/links, I-beam for text, resize cursor for edges
- Tooltip after 500ms hover for non-obvious controls
- Don't require hover for discoverability - it's a hint, not the only way to find an action

### Disabled states
- Visual: 30-40% opacity of normal state
- Cursor: default arrow, no pointer change (macOS)
- Interaction: no response to click/tap, no haptic
- VoiceOver: announce as "dimmed" or "disabled"
- Tooltip/hint: explain why disabled ("Select an item first")

### Placeholder text
- Lighter color than input text (secondary or tertiary label color)
- Shows expected input format or example: "email@example.com"
- Disappears on focus or first character typed
- Don't use as the only label - always have a visible label above the field

## 11. Mental models

### Matching user expectations
- Folder metaphor: hierarchical organization that matches file system mental model
- Trash/recycle: deleted items go somewhere recoverable before permanent deletion
- Shopping cart: collect items before checkout
- Timeline: chronological from newest to oldest (or clearly marked otherwise)
- Tabs: parallel content areas, like physical tab dividers

### Spatial memory
- Don't move things around between sessions - consistent element positions
- Settings in the same place every time
- Navigation items in consistent order
- Toolbar buttons don't rearrange based on context (add/remove, don't rearrange)
- If layout changes, animate the transition so users can track what moved

### Temporal expectations
- Send message: appears immediately in conversation
- Save: instant confirmation (no multi-second delay)
- Search: results start appearing within 500ms
- Delete: item disappears immediately (with undo option)
- Upload: progress visible immediately

## 12. Microinteractions

### Button press
- Scale down to 0.96-0.98x on press (50ms ease-out)
- Scale back to 1.0x on release (100ms spring)
- Background color darkens/lightens on press
- Haptic feedback on significant button presses (iOS)
- Don't animate every button - reserve for primary/important actions

### Toggle animations
- Switch thumb travels from one side to the other: 200ms spring animation
- Track color transitions: 200ms ease-in-out
- Background color cross-fade: 150ms
- Haptic: .selection feedback at the moment of state change

### Scroll physics
- Momentum scrolling: continue in direction of swipe with deceleration
- Rubber-band at edges: overscroll with elastic bounce-back
- Scroll-to-top: tap status bar (iOS), don't override this
- Snap scrolling for cards/pages: spring to nearest item position
- Scroll velocity affects momentum distance

### Spring animations
- Natural feel for interactive elements
- Parameters: response (0.3-0.5s), dampingFraction (0.6-0.8 for bounce, 1.0 for no bounce)
- Use spring for: drag release, position change, size change
- Don't use spring for: fade in/out, color change, progress

### Pull-to-refresh
- Trigger threshold: 64pt pull distance
- Show activity indicator at top of list during refresh
- Rubber-band pull with resistance
- Haptic at trigger threshold
- Complete animation when content updates (200ms)

## 13. Gestalt principles in UI

### Proximity
- Related elements closer together, unrelated elements further apart
- Group spacing ratio: within-group spacing should be at most 50% of between-group spacing
- Example: 8pt between items in a group, 24pt between groups
- Form sections: 16pt between fields in a section, 32pt between sections

### Similarity
- Same styling = same function. Buttons that do similar things look alike
- Primary actions: same color, size, style throughout app
- Metadata: same font size, weight, color for all metadata displays
- Status indicators: same color coding (red=error, green=success) everywhere

### Continuity
- Aligned elements perceived as related
- Left-alignment rail creates visual continuity down a list
- Horizontal rules guide the eye across a row
- Consistent leading edge alignment within navigation and content

### Closure
- Bordered containers (cards, groups) are perceived as containing related items
- Incomplete borders work: top and bottom rule without sides still groups content
- Icon design: outlines can be incomplete and still read as the object

### Figure/ground
- Active/selected content on elevated surface (lighter in dark mode, shadowed in light mode)
- Modal overlays: dim background to 40-60% black opacity
- Focus: blur background content when modal is active
- Content layers: background < content < controls < overlays < modals < alerts

## 14. Information architecture

### Content hierarchy
- 3 levels maximum for primary navigation
- Breadcrumbs for hierarchies deeper than 2 levels
- Most important content first (F-pattern for text, Z-pattern for landing pages)
- Progressive loading: summary first, details on demand

### Labeling
- Clear, descriptive labels - test with 5-second rule (can users understand in 5 seconds?)
- Consistent naming conventions throughout
- No jargon in navigation or labels
- Action labels: verb + noun ("Create project", "Export data")
- Section labels: noun or noun phrase ("Projects", "Recent activity")

### Search vs browse
- Search: for users who know what they want
- Browse: for users exploring or discovering
- Support both: searchable + categorized browsing
- Faceted search for complex data sets (filters + search)
- Global search: accessible from every screen (Cmd+K or Cmd+F)

## 15. Task flow optimization

### Reducing steps
- Count clicks/taps for common tasks - aim for 3 or fewer for frequent actions
- Keyboard shortcuts for power users
- Batch operations: select multiple, apply action once
- Inline actions: edit/delete right in the list without navigating away
- Smart defaults reduce required input

### Eliminating dead ends
- Every screen has a clear next action or way back
- Empty states suggest what to do
- Error states provide recovery path
- Completed workflows suggest logical next step
- "No results" always offers alternatives

### Remembering user choices
- Last used option pre-selected in dialogs
- Recently accessed items shown first
- Search history preserved
- Filter/sort preferences remembered per context
- Form values preserved if user navigates away and returns

---

## Quick reference thresholds

| Metric | Value |
|--------|-------|
| iOS minimum touch target | 44x44pt |
| macOS minimum click target | 24x24pt |
| Maximum menu items before grouping | 7 |
| Maximum top-level navigation items | 5 (iOS), 7 (macOS) |
| Button press animation duration | 50-100ms |
| State transition animation | 200-300ms |
| View navigation animation | 300-350ms |
| Tooltip hover delay | 500ms |
| Search debounce | 300ms |
| Undo toast duration | 5-8 seconds |
| Toast auto-dismiss | 4-8 seconds |
| Error auto-retry backoff | 1s, 2s, 4s, 8s, max 30s |
| Maximum auto-retries | 3-5 |
| Maximum undo stack depth | 20+ levels |
| Progress bar threshold | 2+ seconds operation |
| Cancel button threshold | 5+ seconds operation |
| Disabled element opacity | 30-40% |
| Modal overlay background | 40-60% black |
| Spacing within groups | 8pt |
| Spacing between groups | 24pt |
| Form fields per section | 3-5 |
| Maximum navigation depth | 3 levels |
| Maximum click/taps for common tasks | 3 |
