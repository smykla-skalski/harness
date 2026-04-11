# Error handling and edge cases - comprehensive reference

## 1. Error message design

### Structure
Every error message has three parts:
1. **What happened**: describe the failure in plain terms
2. **Why**: the cause, if known
3. **What to do**: actionable next step or recovery action

### Good vs bad examples

| Bad | Good |
|-----|------|
| "Error 422" | "This email is already registered. Sign in instead?" |
| "Invalid input" | "Phone number must be 10 digits (e.g., 555-123-4567)" |
| "Request failed" | "Couldn't connect to the server. Check your internet and try again." |
| "Permission denied" | "Camera access is needed to scan QR codes. Open Settings to enable it." |
| "Operation failed" | "Your file couldn't be saved because the disk is full. Free up space or save to a different location." |
| "Unknown error" | "Something went wrong. Try again, or contact support if this keeps happening." |

### Rules
- No error codes, HTTP status codes, or stack traces in user-facing messages
- Log technical details for debugging, show human-readable message to user
- Don't blame the user: "Password must be 8+ characters" not "You entered an invalid password"
- Placement: inline near the source of the error, not in a modal alert for form errors
- Persistence: errors stay visible until the user corrects the issue. Never auto-dismiss error messages
- Include an action: button ("Retry", "Open Settings"), link ("Learn more"), or specific instruction
- Tone: neutral and helpful. Not apologetic ("Sorry!"), not robotic ("Error occurred")

## 2. Empty states

### Types and content

**First-use empty** (user hasn't created anything yet)
- Explain what will appear here
- Provide the primary action to get started
- Optional: illustration or icon that sets the mood
- Example: "No projects yet. Create your first project to get started." [Create project]

**No-results empty** (search or filter returned nothing)
- Acknowledge the search: "No results for 'moniter'"
- Suggest fixes: "Check spelling, try different keywords, or broaden your filters"
- Offer to clear filters: [Clear all filters] button
- Offer spell correction: "Did you mean 'monitor'?"

**Error empty** (data failed to load)
- What went wrong: "Couldn't load your projects"
- Recovery action: [Retry] button
- Don't show a sad face or broken robot - be matter-of-fact

**Permission-denied empty**
- What permission is needed: "Location access is needed to show nearby results"
- Why it's needed (one sentence)
- Action: [Open Settings] button
- Don't guilt-trip about permissions

**Deleted/cleared empty**
- Confirm the action: "All items cleared"
- Provide undo: [Undo] button, visible for 8-10 seconds
- Show the first-use empty state after undo timeout

### Design pattern
All empty states follow: icon/illustration + headline + description + primary action button. Center vertically and horizontally in the available space. Use ContentUnavailableView in SwiftUI (iOS 17+/macOS 14+).

## 3. Loading states

### Skeleton screens
- Gray rectangles matching the final content layout (same heights, widths, positions)
- Subtle shimmer/pulse animation: gradient sweep left-to-right, 1500ms cycle
- Show immediately when navigating to a new screen (don't show blank first)
- Prevent layout shift: skeleton dimensions must match loaded content dimensions
- Replace with actual content via crossfade (200ms)
- Use for: lists, cards, profiles, dashboards - any screen with a known layout

### Spinners
- Use for indeterminate short waits (under 5 seconds expected)
- Center in the content area, not in the corner
- Add text label after 1 second: "Loading..."
- Don't show spinner for operations under 100ms (feels instant)

### Progress bars
- Use for operations with known progress (upload, download, sync, batch processing)
- Determinate: show percentage or item count ("3 of 12")
- Don't let the progress bar go backwards
- Don't let it stall - if progress stalls, switch to indeterminate or show "Processing..."
- Smooth progress updates (animate between values, don't jump)

### Rules
- Never show a blank screen. Always indicate something is happening
- Show spinner after 1 second of waiting (not immediately - avoids flicker for fast loads)
- Show progress bar for operations expected to take more than 2 seconds
- Cancel button for operations over 5 seconds
- Loading skeleton matches final layout to prevent layout shift

## 4. Offline and connectivity

### Detection
- Monitor network reachability (NWPathMonitor)
- Don't just check for connectivity - verify the server is reachable
- Handle transitions: online -> offline, offline -> online

### Offline banner
- Non-modal, non-intrusive banner at top or bottom of screen
- "You're offline. Some features may be unavailable."
- Don't use a modal alert for connectivity loss (too disruptive)
- Auto-dismiss when connectivity returns
- Show briefly: "You're back online" when reconnected

### Queued operations
- Queue user actions that require network: messages, edits, favorites
- Show pending state on queued items (e.g., clock icon, "Pending" label)
- Sync automatically when connectivity returns
- Resolve conflicts: last-write-wins for simple data, merge for complex data
- If a queued action fails on sync, show the error and let user retry or discard

### Cached data
- Show cached/stale data with "Last updated: 5 minutes ago" timestamp
- Visual indicator for stale data (subtle, not alarming)
- Offer manual refresh: pull-to-refresh or refresh button
- Don't show data without indicating it might be stale
- Graceful degradation: read-only mode when offline

## 5. Destructive actions

### Hierarchy of safeguards (prefer higher in list)

1. **Undo with toast** (best UX): action executes immediately, toast shows "Item deleted. [Undo]" for 8-10 seconds. If undo tapped, revert. If timeout, permanent
2. **Confirmation dialog** (good): "Delete 3 photos? This can't be undone." Primary: "Delete" (red). Secondary: "Cancel"
3. **Type-to-confirm** (for high-impact): "Type the project name to confirm deletion"
4. **Time-delayed execution**: "Deleting in 5 seconds... [Cancel]" - action executes after countdown

### Confirmation dialog rules
- Title: specific action with count. "Delete 3 items?" not "Are you sure?"
- Body: what will happen, especially if irreversible. "These items will be permanently removed."
- Destructive button: red color, labeled with the verb ("Delete", not "OK")
- Cancel: always the default button (what Return/Enter activates)
- Don't use "Yes/No" buttons. Name the action.

### Destructive button styling
- Red foreground or red background for destructive actions
- In SwiftUI: `Button("Delete", role: .destructive) { ... }`
- In context menus and swipe actions: destructive role gets red treatment
- Never place destructive buttons adjacent to frequently used buttons (prevent accidental taps)

### Soft delete (preferred)
- Move to "Trash" or "Recently Deleted" instead of permanent delete
- Automatically purge trash after 30 days
- Show "Recently Deleted" as a visible, accessible section
- Allow restore from trash
- Permanent delete only from within the trash (with confirmation)

## 6. Edge cases and boundary conditions

### Text length
- Very long text: truncate with ellipsis + tooltip (macOS) or expandable "Show more" (iOS)
- Single line: `.lineLimit(1)` with `.truncationMode(.tail)`
- Multi-line clamp: `.lineLimit(2...3)` to show 2-3 lines
- Filenames: truncate middle ("my_very_lo...ument.pdf")
- Never clip text without indication (no silent truncation)

### Large numbers
- Thousands separator: locale-aware (1,234 or 1.234)
- Abbreviation for display: 1.2K, 3.4M, 1.5B (tooltip shows exact value)
- Percentages: one decimal place maximum (42.7%), zero decimals for whole numbers (100%)
- File sizes: human-readable (1.2 GB, 342 KB), use 1024 base

### Quantity edge cases
- Zero items: show empty state, not "0 items" in a list
- One item: singular form ("1 item"), not "1 items"
- Large quantities: abbreviate if space-constrained
- Layout adapts: single item may need different layout than a list of items

### Rapid successive actions
- Debounce: 300ms for search input, 500ms for auto-save
- Disable button during processing: prevent double-submission
- Throttle API calls: maximum 1 per second for user-triggered refreshes
- Batch rapid changes: group multiple edits into a single save operation

### Concurrent modifications
- Optimistic locking: save with version number, reject if stale
- Conflict resolution UI: show both versions, let user choose or merge
- Auto-merge for non-conflicting changes (different fields)
- Last-write-wins for simple, non-critical data

### Permission changes mid-session
- Re-check permissions before executing privileged actions
- If permission revoked: show explanation, don't crash
- Adapt UI: hide or disable controls that require revoked permissions
- Don't cache permission state for long periods

## 7. Form validation

### Timing
- **On blur** (field loses focus): primary validation trigger. Good for format checks
- **On submit**: safety net. Validate all fields, scroll to first error, focus it
- **On keystroke**: only for simple constraints (character count, number-only fields)
- **On paste**: validate pasted content, don't reject silently

### Visual states
1. Neutral: default state, no validation indication
2. Error: red border + error message below the field
3. Success: subtle green checkmark or border (optional, don't over-celebrate)

### Rules
- Don't mark fields as invalid before the user has interacted with them
- Don't show error on an empty required field until user tries to submit or moves past it
- Required field indication: mark optional fields ("Optional"), assume required by default
- Inline error messages below the field, aligned with field start. Not in alerts
- Error message text: what's expected ("Enter an email address"), not what's wrong ("Invalid email")
- Preserve all user input on error - never clear the form
- If validation is async (checking username availability), show spinner in the field

### Multi-field validation
- Validate dependent fields together (password + confirmation)
- Show error on the field that needs to change
- Focus the first error field after submit validation
- "N errors remaining" summary at the top for long forms

## 8. Crash recovery and state preservation

### Auto-save
- Save user work on every meaningful change (not on every keystroke - debounce at 500ms-2s)
- Save on app backgrounding (iOS) immediately
- Save on window close / app quit
- Auto-save indicator: "Saved" in toolbar or status bar (briefly, then fades)
- No explicit Save button needed for most data (settings, notes, lists)
- For document-based apps: auto-save + explicit Save As

### State restoration
- Restore window position and size (macOS)
- Restore scroll position
- Restore selection state (which item, which tab)
- Restore navigation stack depth (which screen user was on)
- Restore pending input (draft text, unsaved form data)
- Use @SceneStorage for per-window state in SwiftUI
- Use NSUserActivity for cross-device handoff state

### Crash recovery
- On next launch after crash: restore last known good state
- Don't show "The app crashed" alert - just restore and continue
- If crash was caused by corrupt state: fall back to defaults, don't crash-loop
- Log crash details for debugging (MetricKit, crash reporter)
- Periodic state snapshots: save full state every 30 seconds as backup

## 9. Timeout and retry

### Timeout values
- Network request: 30 seconds default
- Connection establishment: 10 seconds
- DNS resolution: 5 seconds
- Local operation (disk, database): 10 seconds
- User-facing operations: show timeout message after 30 seconds with retry option

### Retry behavior
- Auto-retry for transient errors (network timeout, 5xx server errors)
- Don't auto-retry for permanent errors (4xx client errors, auth failures)
- Exponential backoff: 1s, 2s, 4s, 8s, max 30s
- Maximum auto-retries: 3 attempts
- Show retry state: "Retrying... (attempt 2 of 3)"
- After max retries: show error with manual [Retry] button
- Jitter: add random 0-500ms to prevent thundering herd

### Cancel
- Cancel button always available during operations over 2 seconds
- Cancel actually cancels (sends cancellation signal, doesn't just dismiss UI)
- After cancel: return to previous state, not to an error state
- Confirm cancel only for long-running operations where progress would be lost

## 10. Accessibility of error states

### VoiceOver announcements
- Announce errors immediately when they appear
- Use AccessibilityNotification.Announcement for dynamic error messages
- Include the error content in the announcement, not just "error occurred"
- Example: announce "Error: email address is invalid" not just "error"

### Focus management
- Move VoiceOver focus to the error when it appears
- For form errors: focus the first field with an error
- Use AccessibilityNotification.LayoutChanged to reset focus
- Error summary at form top should also be focusable

### Error indicators
- Never rely solely on color (red border alone is insufficient)
- Combine: red border + error icon (exclamationmark.triangle) + error text
- Error icon has accessibilityLabel: "Error"
- Error state must be perceivable with Increase Contrast enabled

### Loading state accessibility
- Announce "Loading" when loading begins (if VoiceOver is active)
- Announce "Loaded. N items found." when loading completes
- Skeleton screens: mark as accessibility hidden (decorative)
- Progress bars: accessibilityValue with percentage ("50 percent complete")

---

## Quick reference: safeguard selection

| Impact | Reversible? | Safeguard |
|--------|-------------|-----------|
| Low | Yes | Undo toast (8-10s) |
| Low | No | Confirmation dialog |
| Medium | Yes | Undo toast (8-10s) |
| Medium | No | Confirmation with specific language |
| High | No | Type-to-confirm or time-delayed |
| Critical | No | Type-to-confirm + explicit warning |

## Quick reference: validation timing

| Validation type | When | Example |
|----------------|------|---------|
| Character restriction | On keystroke | Numbers-only field |
| Format check | On blur | Email format |
| Length check | On keystroke (counter) + blur (error) | Character limit |
| Availability check | On blur + debounce | Username availability |
| Cross-field | On blur of dependent field | Password match |
| All fields | On submit | Form completeness |
