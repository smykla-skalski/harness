---
globs: "**/*.swift"
description: "Interaction design rules: feedback, errors, loading states, destructive actions, data entry, data display."
---

# Interaction design rules

## Feedback

- Every user action gets visual feedback within 100ms (1 frame at 60fps).
- Button press: immediate visual state change (color, scale 0.97x) on touch-down, not touch-up.
- Toggle: animation starts within 1 frame.
- Text input: character appears same frame as keystroke.
- Operations > 1 second: show spinner with label.
- Operations > 2 seconds: show progress bar if progress is known.
- Operations > 5 seconds: show cancel button.
- Operations > 10 seconds: show progress bar with percentage/count, cancel mandatory.

## Loading states

- Never show a blank screen. Always indicate something is happening.
- Skeleton screens for known layouts: gray rectangles matching final dimensions, shimmer animation (1500ms cycle).
- Skeleton must match final layout exactly (prevent layout shift).
- Replace skeleton with content via crossfade (200ms).
- Spinner: indeterminate short waits under 5 seconds. Don't show for operations under 100ms.
- Progress bar: determinate operations. Never go backwards. Smooth updates.
- Mark skeleton views as `.accessibilityHidden(true)`.

## Error messages

- Structure: what happened + why + what to do next.
- No error codes, HTTP status codes, or stack traces in user-facing messages. Log them.
- Don't blame the user: "Password must be 8+ characters" not "Invalid password".
- Placement: inline near the source. Not modal alerts for form errors.
- Errors persist until corrected. Never auto-dismiss error messages.
- Include recovery action: button ("Retry", "Open Settings") or specific instruction.
- VoiceOver: announce errors immediately with the content.

## Empty states

- Use `ContentUnavailableView` (iOS 17+/macOS 14+).
- First-use: explain what appears here + primary action to get started.
- No-results: acknowledge search + suggest fixes + "Clear filters" button.
- Error: what went wrong + [Retry] button.
- All follow: icon + headline + description + primary action button.

## Destructive actions

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

## Form validation

- Validate on blur (field loses focus), not every keystroke.
- Validate all on submit as safety net. Scroll to first error, focus it.
- Don't mark fields as invalid before user interaction.
- Inline error below the field, not in modal alerts. Show what's expected, not what's wrong.
- Required fields: mark optional ones ("Optional"). Assume required by default.
- Preserve all user input on error. Never clear the form.
- Disable button during processing to prevent double-submission.

## Data entry

- Labels visible above fields. Placeholder is not a label (it disappears on input).
- Set `.keyboardType()` appropriately on iOS: `.emailAddress`, `.URL`, `.numberPad`.
- Set `.textContentType()` for autofill: `.emailAddress`, `.password`, `.name`.
- Set `.autocorrectionDisabled()` for usernames, code, IDs.
- Search: debounce at 300ms, show results within 500ms, show result count.
- Recent entries: show last 5-10 used values.

## Data display

### Numbers and dates
- Locale-aware formatting. Use system formatters (FormatStyle), not hardcoded formats.
- Large numbers: abbreviate (1.2K, 3.4M) with tooltip for exact value.
- Relative time: "Just now" (< 1 min), "5 minutes ago" (< 1h), "3 hours ago" (< 24h), absolute date after 7 days.
- Duration: "1h 23m" for short, "2 days, 3 hours" for longer.
- File sizes: human-readable (1.2 GB, 342 KB). Use ByteCountFormatter.
- Zero items: show empty state, not "0 items" in a list.
- Singular/plural: "1 item" not "1 items". Use localized plural rules.

### Tables and lists
- Text left-aligned, numbers right-aligned, status centered.
- Column headers: bold/semibold, sticky during scroll.
- Sort indicators: filled arrow on sorted column, click to reverse.
- List row minimum height: 44pt (iOS), 28pt (macOS).

### Truncation
- Single line: ellipsis at tail. Filenames: middle truncation ("my_very_lo...ument.pdf").
- Multi-line: clamp to 2-3 lines with "Show more" or tooltip for full text.
- Never silently truncate without visual indicator.
- Technical values (IDs, hashes, URLs): tap/click to copy with "Copied" confirmation.

### Status indicators
- Green: active/success. Orange: warning. Red: error/critical. Blue: info/in-progress. Gray: inactive.
- Always include text label alongside color (don't rely on color alone).
- Badge counts: cap display at "99+".

## Notifications (in-app)

- Toast/banner: auto-dismiss after 4-8 seconds, manually dismissable, non-blocking.
- Stack newest on top, max 3 visible.
- Errors: persistent until resolved. Don't auto-dismiss.
- Success: informational only, don't require acknowledgment.

## Offline and connectivity

- Non-modal offline banner, not a modal alert.
- Show cached data with "Last updated" timestamp.
- Queue writes when offline, sync on reconnect.
- Auto-dismiss offline banner when reconnected.

## Undo

- Minimum 20 levels of undo (Cmd+Z / Cmd+Shift+Z).
- Name actions in Edit menu: "Undo Delete" not just "Undo".
- Group related operations (continuous typing until 2-second pause).
- Preserve undo stack across saves.
