# UX psychology and usability - comprehensive reference

## 1. Nielsen's 10 usability heuristics

### H1: Visibility of system status

- Every user action gets visual feedback within 100ms
- Loading operations show progress after 1 second of waiting
- Background operations show a non-intrusive indicator (toolbar spinner, badge)
- Current location always visible: breadcrumbs, highlighted nav item, page title
- Selection state clearly shown: highlight, checkmark, filled icon
- Sync status visible: "Saved", "Syncing...", "Last synced 2 min ago"
- Network state: show offline banner when connection is lost
- Operation outcome: success confirmation, error explanation, or partial success detail
- Remaining capacity: "3 of 10 used", storage bar, rate limit indicator
- Mode indicators: editing vs viewing, locked vs unlocked, online vs offline

### H2: Match between system and real world

- Use plain language, not technical jargon. "Save" not "Persist", "Remove" not "Unlink"
- Follow real-world metaphors: folder = container, trash = recoverable delete
- Use familiar icons: gear = settings, magnifying glass = search, pencil = edit
- Information in natural, logical order: name before email, city before zip
- Date/time in user's locale format
- Numbers in locale-appropriate format (1,234.56 vs 1.234,56)
- Colors match cultural expectations: red = stop/danger/error, green = go/success

### H3: User control and freedom

- Undo for every destructive action (minimum 20 levels)
- Cancel button on every modal dialog and multi-step flow
- Back navigation always available and obvious
- Escape key dismisses overlays/modals/popovers (macOS)
- Close button visible on all windows and panels
- Don't auto-advance or auto-submit without explicit user action
- Allow editing after submission where possible
- "Discard changes" available when backing out of unsaved work
- Emergency exit: Cmd+Z, Cmd+. (cancel), Escape always work

### H4: Consistency and standards

- One word for one concept throughout (don't alternate "delete/remove/trash" for the same action)
- Icon meaning consistent: same icon = same action everywhere
- Layout patterns consistent: if lists drill down in section A, they drill down in section B
- Platform keyboard shortcuts: Cmd+C, Cmd+V, Cmd+Z, Cmd+Q, Cmd+W, Cmd+, (macOS)
- System controls for system concepts: use system file picker, share sheet, date picker
- Follow platform navigation patterns: sidebar on macOS, tab bar on iOS
- Button placement: primary action right/bottom, cancel left
- Link appearance: underlined and colored consistently
- Status colors: consistent throughout (red = error everywhere)

### H5: Error prevention

- Constrain input: date pickers not text fields for dates, dropdowns for known option sets
- Disable actions that aren't currently valid (with tooltip explaining why)
- Confirmation for destructive actions, especially irreversible ones
- Undo over confirmation when possible (softer interruption)
- Show character/file size limits proactively
- Validate input format inline as user types or on blur
- Auto-save continuously to prevent data loss
- Guard against double-submission: disable submit button after click until response

### H6: Recognition rather than recall

- Show options instead of requiring users to remember them (dropdown > text input for known values)
- Menu items list all available actions (menus are documentation)
- Recent items and frequently used items shown prominently
- Search with suggestions and autocomplete
- Inline help and tooltips for non-obvious controls
- Breadcrumbs for location in deep hierarchies
- Keep relevant information visible: don't hide behind extra clicks
- Labels on icons (or tooltips at minimum)
- Auto-complete based on previous entries

### H7: Flexibility and efficiency of use

- Keyboard shortcuts for all frequent actions (displayed in menus)
- Customizable toolbar (macOS convention)
- Recent/favorites for quick access
- Batch operations: select multiple, apply action once
- Cmd+K / Cmd+P command palette for power users
- Right-click context menus with relevant actions
- Drag and drop as alternative to menu-driven operations
- Search as alternative to browsing
- Default view for novices, customizable for experts

### H8: Aesthetic and minimalist design

- Remove every element that doesn't serve the current task
- Progressive disclosure: show common options, hide advanced ones
- No decorative elements that don't convey information
- White space is a feature, not wasted space
- One primary action per screen/section - make it obvious
- De-emphasize secondary actions (smaller, less color, different style)
- Don't show empty columns, zero-count badges, or irrelevant metadata
- Data density appropriate to the context

### H9: Help users recognize, diagnose, and recover from errors

- Error message format: "What happened" + "Why" + "How to fix"
- No error codes, stack traces, or technical details in user-facing messages (log them)
- Specific, not generic: "Email address is already registered" not "Invalid input"
- Suggest recovery: include action button ("Retry", "Go to Settings", "Contact Support")
- Don't blame the user: "The password must be 8+ characters" not "Invalid password"
- Highlight the source: if a form field has an error, highlight THAT field
- Persist error state until corrected (don't auto-dismiss error messages)

### H10: Help and documentation

- Help menu with search (macOS standard)
- Contextual tooltips on non-obvious controls (500ms hover delay)
- Onboarding for first use: inline, not modal, dismissable
- Keyboard shortcuts discoverable in menus and help
- Help content: task-oriented ("How to export data"), not feature-oriented ("The Export dialog")
- Link to documentation from error messages and empty states

## 2. Cognitive load theory

### Types
- **Intrinsic load**: complexity inherent to the task. Can't reduce, but can scaffold
- **Extraneous load**: complexity from bad design. Reduce aggressively
- **Germane load**: effort spent on learning and schema building. Desirable

### Reducing extraneous load
- Consistent layouts: don't make users re-learn each screen
- Group related information together (Gestalt proximity)
- Remove unnecessary steps in task flows
- Show only relevant information for current task
- Don't require remembering information between screens
- Auto-fill what can be inferred
- Visual hierarchy guides attention to what matters

### Chunking
- Group related items: 3-5 items per chunk
- Long lists: section headers every 5-7 items
- Step numbers: "Step 2 of 4", not a wall of instructions
- Table of contents for long pages

### Progressive disclosure
- Level 1: most common options visible (80% of use cases)
- Level 2: advanced options behind disclosure/toggle
- Level 3: expert settings in separate screen
- Show item count when collapsed: "Advanced options (4)"
- Remember user's disclosure preference

## 3. Don Norman's design principles

### Discoverability
- All possible actions visible or easily found through exploration
- Menu bars list all actions (menus as documentation)
- Hover states and cursor changes signal interactivity (macOS)
- Interactive elements look different from passive content

### Feedback
- Every action produces visible, immediate response
- Button depresses on click, switch moves on toggle
- Audio/haptic feedback for physical-feeling interactions
- Status indicators for ongoing operations
- Completion confirmation: success state shown

### Conceptual models
- UI behavior matches user's mental model
- Consistent metaphors: if it looks like a folder, it behaves like a folder
- Operations behave predictably: if drag reorders in one list, it reorders in all

### Affordances
- Elements look like what they do: buttons look pushable, sliders look slidable
- Text fields have clear boundaries and cursor on focus
- Toggles show on/off state visually
- Drag handles look grippable
- Links are underlined or differently colored

### Signifiers
- Cursor changes: pointer for clickable, I-beam for text, grab for draggable
- Hover highlight on interactive elements (macOS)
- Chevron on drill-down list items
- Focus rings on keyboard-focused elements
- Scroll indicators showing scrollable content extends

### Mappings
- Spatial: left arrow goes left, scroll down moves content up
- Logical: bigger slider value = bigger result
- Cultural: green = positive, red = negative
- Controls adjacent to what they affect

### Constraints
- Prevent impossible states in the UI
- Disable invalid options (with explanation)
- Input masks for formatted data
- Type constraints: number field accepts only numbers

## 4. Emotional design

### Visceral (first impression, 50ms)
- Clean, professional appearance builds trust
- No visual clutter on first screen
- Brand colors and typography set the tone
- Polished app icon

### Behavioral (usability during use)
- Fast, responsive interactions
- Predictable, reliable behavior
- Errors handled gracefully
- Tasks completed efficiently

### Reflective (long-term impression)
- Users feel competent using the app
- Consistent quality builds trust over time
- Respects user's time and attention
- No manipulative patterns

### Delight without annoyance
- Micro-animations that reward: checkmark animation on completion
- Satisfying haptics on significant actions
- Don't repeat delightful animations so often they become annoying
- Don't slow down the experience for the sake of animation

## 5. Decision architecture

### Smart defaults
- Pre-select the most common option
- Default to the safest option for irreversible settings
- Last-used values as defaults for repeated operations
- Timezone/locale from system

### Reducing decision fatigue
- Maximum 3-5 options for primary choices
- Maximum 7 +/- 2 items in a single ungrouped list
- Group related options under category headers
- "Quick setup" option alongside "Custom setup"

### Ethics
- No confirmshaming
- No forced engagement
- Clear opt-in/opt-out
- Transparent data usage
- Easy account deletion

## 6. Attention and focus

### Visual hierarchy directing attention
1. Size: largest element scanned first
2. Color/contrast: high-contrast elements pop
3. Position: top and left scanned first (LTR)
4. Isolation: element with whitespace draws attention
5. Motion: animated elements pull focus (use sparingly)

### Notification discipline
- Don't interrupt focused work for low-priority information
- Badge count: update quietly
- Banner: for time-sensitive, actionable information only
- Sound: for urgent/time-critical only
- Respect system Focus modes
- Let users control notification categories

## 7. Memory and learning

### Onboarding design
- Show value before asking for setup
- Maximum 3 onboarding screens (skip always visible)
- Teach in context: tips when user first encounters a feature
- Don't front-load all tutorials
- Never show the same tip twice

### Feature discovery
- Keyboard shortcut hints in menu items
- Context menus surface less-discoverable actions
- Tooltips after 500ms hover
- Empty states as teaching moments
- "What's New" after updates: 3-5 items max, dismissable

### Spatial memory
- Keep elements in consistent positions across sessions
- Don't rearrange toolbar items based on context
- Navigation structure stays stable
- If something must move, animate the transition

## 8. Trust and safety

### Data safety
- Show what data is collected and why
- Request permissions in context, not at launch
- Data export in standard formats
- Account deletion accessible

### Destructive action safeguards
- Trash before permanent delete (two-step)
- Undo toast for 8-10 seconds after destructive action
- Confirmation dialog with specific language for irreversible actions
- Type-to-confirm for highest-impact actions
- Red/destructive button styling

### Reliability
- Auto-save continuously
- Crash recovery: restore state after unexpected quit
- Offline capability: don't lose data when network drops
- Atomic writes, proper error handling

## 9. Performance perception

### Threshold rules
- 0-100ms: instantaneous, no feedback needed
- 100ms-1s: show subtle activity indicator
- 1-10s: show spinner with label ("Loading items...")
- 10s+: progress bar with percentage/count, cancel button mandatory
- 30s+: progress bar + estimated time remaining

### Perceived speed techniques
- Show content progressively (text before images)
- Optimistic updates: show result before server confirms
- Skeleton screens match final layout
- Preload likely next screen during idle
- Animate transitions to mask loading time

### Skeleton screens
- Gray rectangles matching content layout
- Subtle shimmer/pulse animation (1500ms cycle)
- Show immediately on navigation
- Match exact layout of loaded state
- Replace with content via crossfade (200ms)

## 10. Writing for UI (UX writing)

### Button labels
- Use verbs: "Save", "Delete", "Create project"
- Be specific: "Delete 3 items" not "OK"
- Destructive: name the action ("Delete", "Remove")
- Never "OK" for destructive actions
- Never "Yes/No" for anything

### Error messages
- What happened: "Your file couldn't be saved"
- Why: "The disk is full"
- What to do: "Free up space and try again"
- Tone: neutral, helpful, not blaming

### Empty states
- What this area is for: "Your bookmarks will appear here"
- How to populate: "Bookmark articles to save them"
- Call to action button
- Icon or illustration (optional)

### Confirmation dialogs
- Title: specific action "Delete 3 photos?"
- Body: what will happen "These photos will be permanently removed"
- Primary: name the action "Delete Photos"
- Secondary: "Cancel"
- Never: "Are you sure?" / "Yes" / "No"

### Tooltip content
- Under 10 words
- Describe what the control does
- Include keyboard shortcut: "Bold (Cmd+B)"
- No period at the end

### Menu items
- Verb + noun: "Export Data", "Open File"
- Ellipsis (...) when action opens a dialog
- No ellipsis for immediate actions
- Keyboard shortcut right-aligned

## 11. Inclusive design

### Internationalization
- All strings in localization files, never hardcoded
- Allow 30-50% text expansion for other languages
- RTL layout support for Arabic, Hebrew
- Don't embed text in images
- Locale-appropriate date, time, number formatting
- Pluralization rules vary by language
- Don't concatenate strings for sentences (word order varies)

### Cultural sensitivity
- Avoid hand gesture icons (meanings vary)
- Don't assume name format (first + last)
- Support international phone/address formats

### Age-inclusive design
- Support Dynamic Type for larger text
- Clear contrast for aging vision
- Generous touch targets
- No rapid interactions required

## 12. User testing principles

### 5-user testing rule
- 5 users uncover ~85% of usability issues
- 3 rounds of 5 users > 1 round of 15

### What to measure
- Task completion rate: target >95% for core tasks
- Time on task: benchmark against similar apps
- Error rate: target <2 per core task
- SUS score: target >68 (above average), >80 (good)
- Learnability: improvement on second attempt

---

## Code review checklist (UX)

| Check | Rule |
|-------|------|
| Feedback | Every user action gets visual feedback within 100ms |
| Loading | Operations > 1s show loading state |
| Errors | Error messages: what + why + how to fix |
| Empty state | All empty states have explanation + action |
| Undo | Destructive actions have undo or confirmation |
| Consistency | Same action looks/works the same everywhere |
| Labels | Buttons use verbs, not nouns or "OK" |
| Navigation | Back/escape always works, no dead ends |
| Defaults | Smart defaults reduce required input |
| Keyboard | All actions reachable via keyboard (macOS) |
| Target size | Touch >= 44pt (iOS), click >= 24pt (macOS) |
| Contrast | Text meets 4.5:1 (normal) or 3:1 (large) |
| Dynamic Type | All text uses text styles, layout adapts |
| VoiceOver | Interactive elements have accessibility labels |
| Motion | Animations respect Reduce Motion |
| Color | Information not conveyed by color alone |
| Truncation | Long text handles gracefully |
| Focus | Visible focus ring, logical tab order |
