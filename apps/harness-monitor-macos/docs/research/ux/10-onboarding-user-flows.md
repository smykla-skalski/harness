# Onboarding and user flows - comprehensive reference

## 1. First launch experience

### Show value immediately
- The first screen should show real functionality, not a login gate or permission wall
- If the app requires account creation, let users browse read-only content first
- Show the app's primary view with sample data or an inviting empty state
- Defer setup: don't ask for name/email/preferences before showing value

### Permission requests
- Never ask for all permissions at launch (camera, location, notifications in sequence = wall of dialogs)
- Ask in context: request camera permission when user taps "Scan QR code", not at first launch
- Explain before asking: "We need camera access to scan QR codes" -> [Continue] -> system prompt
- If denied: show a helpful inline message explaining how to enable in Settings, with a direct link
- Graceful degradation: if permission denied, the feature is unavailable but the app still works

### Smart defaults
- Language/locale/timezone: from system settings
- Units: from system locale (metric/imperial)
- Theme: follow system appearance (light/dark)
- Don't ask users to choose things the system already knows

### Rules
- Maximum 3 onboarding screens if absolutely needed
- Skip button always visible (don't force users through a tutorial)
- No auto-advancing slides (user controls the pace)
- No multi-page tutorial before first use - teach in context instead
- Don't show onboarding on every launch (only first launch)
- Remember if onboarding was completed (don't show again after reinstall if iCloud-synced)

## 2. Onboarding patterns

### Progressive onboarding (preferred)
- Teach features as the user encounters them naturally
- First time user taps a feature: show a brief contextual tip (coach mark)
- Don't front-load: spread tips over the first week of use
- Track which tips have been shown, never repeat them

### Coach marks
- Non-modal: don't block interaction with the rest of the UI
- One at a time: never show multiple coach marks simultaneously
- Dismissable: tap anywhere to dismiss
- Clear target: arrow or highlight pointing to the relevant control
- Short text: one sentence, 10-15 words maximum
- Position: above or below the target, never covering it
- Show only once per feature

### Sample data
- Show the app populated with realistic-looking sample data
- Let users interact with sample data to learn the app
- Clearly mark as sample: "Sample data - create your first item to get started"
- Offer to clear sample data or auto-clear when user creates first real item

### Getting-started checklist
- For apps with multi-step setup (e.g., developer tools, project management)
- 3-5 steps maximum: "Set up your profile", "Create a project", "Invite a teammate"
- Track completion with checkmarks
- Show progress: "2 of 4 steps completed"
- Allow dismissing the checklist permanently: "I'll do this later" or X
- Re-accessible from settings or help menu if dismissed

## 3. Settings and preferences design

### Organization
- Group by function: General, Appearance, Accounts, Notifications, Advanced
- Most common settings first in each group
- Most important groups first in navigation
- 5-7 items per section before splitting

### macOS settings window
- Use Settings scene in SwiftUI
- Tab bar with icons across the top (General, Appearance, etc.)
- Fixed window size appropriate to content
- Standard window frame with close button, no minimize/zoom
- Cmd+, opens settings from anywhere in the app

### iOS settings
- In-app settings: Form in NavigationStack with grouped list sections
- System Settings bundle: only for app-level settings users rarely change (cache, permissions)
- Don't split settings between in-app and system - confusing

### Interaction patterns
- Toggles for binary on/off: immediate effect, no Save button
- Pickers for multiple options: inline or navigation push to picker view
- Text fields for custom values: validate on blur
- Sliders for continuous ranges: show current value
- Dangerous settings (reset, delete data): confirmation required
- "Reset to defaults" option at the bottom of each section

### Search in settings
- For apps with 20+ settings: add a search bar at the top
- Search matches setting names and descriptions
- Navigate directly to the matching setting's section

## 4. User authentication flows

### Sign in / sign up
- Single screen with toggle between sign in and sign up (not separate flows)
- Social login buttons first (Apple, Google) if supported - fewer steps
- Email + password below social options
- "Continue with..." language for social login, not "Sign in with..."
- Remember email address across sign-out/sign-in cycles
- Auto-fill support: .textContentType(.username), .textContentType(.password)

### Password
- Show/hide toggle on password field (eye icon)
- Requirements shown proactively as a list below the field, checking off as met
- Don't enforce arbitrary rules beyond minimum length (8+ characters minimum)
- Support password managers: proper text content types
- "Forgot password?" link near password field
- Biometric option (Face ID / Touch ID) after first sign-in

### Session handling
- Stay signed in by default (don't require re-auth on every launch)
- If session expires: preserve current screen state, overlay a compact sign-in form
- After re-auth: return to the exact state the user was in, don't navigate away
- Background token refresh: invisible to user
- Explicit sign-out: accessible from settings/account section, not from main navigation

### Biometric auth
- Offer to enable after first successful password sign-in
- Use for app unlock, not for initial registration
- Fallback to password always available
- Respect system biometric settings
- LAContext for Face ID / Touch ID

## 5. Navigation and wayfinding

### Users must always know where they are
- Active navigation item highlighted (sidebar, tab bar)
- Page/screen title always visible
- Breadcrumbs for hierarchies deeper than 2 levels
- Back button shows the title of the previous screen

### No dead ends
- Every screen has at least one navigation action (back, close, next action)
- Completed workflows suggest next steps
- Error screens provide recovery (retry, go back, go home)
- Empty states provide the action to populate them

### Deep linking
- Support URLs for every navigable screen
- Universal links on iOS, custom URL scheme as fallback
- Opening a deep link navigates to the correct state
- If not signed in, show sign-in then navigate to the deep-linked content

### History and recent items
- macOS: Recent items in File menu
- Recently viewed items accessible from a panel or search
- "Last opened" metadata visible on items
- Cmd+Shift+T or similar to reopen last closed item

## 6. Multi-step workflows (wizards)

### Progress indication
- Show current step and total: "Step 2 of 4"
- Visual progress bar or step indicator with labels
- Steps should have descriptive names, not just numbers
- Show completion state for past steps (checkmark)

### Navigation within wizard
- Allow going back without losing entered data
- Back button returns to previous step with data preserved
- Forward navigation requires current step validation
- Direct step navigation (clicking a completed step) is optional for simple wizards

### Data preservation
- Auto-save progress on each step completion
- If user abandons mid-wizard: save as draft, offer to resume later
- For long wizards (5+ steps): periodic auto-save every 30 seconds
- "Resume draft" on next visit

### Validation
- Validate at each step, not just at the end
- Show inline errors on the current step
- Don't allow advancing past an invalid step
- Final step: show summary/review of all entered data before submission

### Completion
- Success screen with confirmation
- Clear next actions: "View your project", "Share with team", "Create another"
- If the created resource has a URL, show it and offer to copy

## 7. Undo and history

### Undo stack
- Minimum 20 levels of undo
- Cmd+Z / Cmd+Shift+Z (macOS), shake to undo (iOS)
- Group related operations: continuous typing is one undo unit (until 2-second pause)
- Name undo actions: Edit menu shows "Undo Delete" not just "Undo"
- Preserve undo stack across auto-saves
- Clear undo stack only on explicit close or after a major structural change

### Undo toast for destructive actions
- "Item deleted. [Undo]" - visible for 8-10 seconds
- Position: bottom of screen (iOS) or bottom-center of window (macOS)
- Dismissable: swipe away or X button
- Action reverts immediately when tapped
- After timeout: action becomes permanent

### Version history (document-based apps)
- Auto-save versions at meaningful intervals (every save, or every 5 minutes)
- Browse versions: show timeline of versions with preview
- Restore to any previous version
- macOS: integrate with system Versions (NSDocument versioning)
- Show who made changes in collaborative apps

### Activity log
- Collaborative apps: show history of changes by all users
- "John edited the title 5 minutes ago"
- Filter by: user, type of change, date range
- Link from activity log entry to the affected content

## 8. Feature discovery

### Keyboard shortcuts
- Show in menu item labels: "Bold  Cmd+B"
- Discoverable through Help menu search
- Don't require keyboard shortcuts for any action (always have mouse/touch alternative)
- Cheat sheet: Cmd+/ or Help > Keyboard Shortcuts (optional but helpful)

### Context menus
- Right-click (macOS) / long press (iOS) on relevant elements
- Show actions specific to the target element
- Include less-discoverable but useful actions (Copy link, Share, Info)
- Destructive actions at the bottom, separated by divider

### What's New screen
- Show after app updates, not on every launch
- Maximum 3-5 bullet points highlighting user-impacting changes
- Brief description + illustration/icon per item
- "Continue" button to dismiss
- Accessible later from Help menu or About screen
- Don't show for minor bug fix releases (only for feature releases)

### Help menu (macOS)
- Standard Help menu with search
- Search finds menu items and help content
- Link to documentation website
- Link to support/contact
- "Report a problem" option

## 9. User engagement without dark patterns

### Anti-patterns to avoid
- Confirmshaming: "No thanks, I don't want to save money" - manipulative
- Forced continuity: making it hard to cancel subscriptions
- Hidden costs: revealing fees only at the final step
- Bait and switch: advertising one thing, delivering another
- Friend spam: importing contacts without clear consent
- Roach motel: easy to sign up, hard to delete account
- Artificial scarcity/urgency: "Only 2 left!" when not true
- Infinite scroll traps: no clear ending point, guilt-driven engagement
- Streak manipulation: "Don't break your streak!" for non-meaningful metrics
- Notification spam: excessive notifications to drive re-engagement

### Ethical engagement
- Provide clear value in every notification
- Let users control notification frequency and categories
- Make unsubscribe/opt-out as easy as subscribe/opt-in
- Data export: standard formats (JSON, CSV), accessible from settings
- Account deletion: accessible, straightforward, within 24 hours
- Transparent data usage: what data is collected, why, who can see it

## 10. Cross-device and handoff

### Handoff (macOS and iOS)
- NSUserActivity with proper activity type
- Encode enough state to resume the activity on the other device
- Handoff icon appears in dock (macOS) or app switcher (iOS)
- Test: start activity on one device, verify it continues seamlessly on the other

### iCloud sync
- Core Data with CloudKit or SwiftData with CloudKit
- Sync automatically, don't require manual sync
- Conflict resolution: last-write-wins for simple data, merge for complex
- Show sync status: "Synced" or "Syncing..." in subtle indicator
- Handle: device offline, iCloud account changes, storage full

### Universal clipboard
- Supported automatically by the system for standard pasteboard types
- Custom types: register UTTypes for app-specific clipboard content
- Works for text, images, URLs, and custom data

### State sync
- Selected tab, scroll position, and navigation state sync across devices
- Preference sync via iCloud key-value store (NSUbiquitousKeyValueStore)
- Don't sync device-specific settings (notification preferences, haptic settings)

## 11. Internationalization and localization

### String externalization
- All user-facing strings in Localizable.strings or String Catalogs (.xcstrings)
- Use String(localized:) or NSLocalizedString, never hardcoded strings
- Include developer comments for translator context
- Format strings with placeholders: "Found %d items" (different languages reorder words)
- Don't concatenate strings to build sentences - use complete sentences with placeholders

### Text expansion
- German: 30-40% longer than English
- Finnish: up to 50% longer than English
- Chinese/Japanese/Korean: often shorter but may need taller line height
- Layout must not break with longer text - use flexible sizing
- Test with pseudo-localization (double-length strings) during development
- Never truncate translated text without tooltip/expansion

### RTL support
- Mirror horizontal layouts for Arabic, Hebrew, Urdu
- SwiftUI handles most layout mirroring automatically with standard layout primitives
- Test: change system language to Arabic/Hebrew and verify layout
- Icons with directional meaning (arrows, reading order) must flip
- Don't flip: media playback controls, analog clocks, musical notation

### Number and date formatting
- Use system formatters: DateFormatter, NumberFormatter, FormatStyle
- Respect user's locale settings
- Calendar system: Gregorian is not universal (Islamic, Buddhist, Japanese calendars exist)
- First day of week: varies by locale (Sunday, Monday, Saturday)
- Currency: symbol, placement, decimal separator, thousands separator all locale-dependent

### Pluralization
- English: singular/plural ("1 item" / "2 items")
- Other languages have more forms: zero, one, two, few, many, other
- Use .stringsdict or String Catalog with plural rules
- Never use if/else for pluralization - use the localization system

### Cultural sensitivity
- Colors: red doesn't universally mean error (luck in Chinese culture, purity in Indian culture)
- Icons: avoid hand gestures, religious symbols, culturally specific metaphors
- Names: support mononyms, multi-part surnames, non-Latin scripts
- Dates: American date format (MM/DD) is confusing outside the US - use locale formatting
- Addresses: format varies wildly by country - use address frameworks or flexible fields

---

## Quick reference: onboarding rules

| Rule | Limit |
|------|-------|
| Maximum onboarding screens | 3 |
| Permission requests at launch | 0 (ask in context) |
| Coach marks at once | 1 |
| Getting-started checklist items | 3-5 |
| Settings items per section | 5-7 |
| Wizard steps before auto-save | 3 |
| Undo stack minimum depth | 20 levels |
| Undo toast visibility | 8-10 seconds |
| What's New bullet points | 3-5 |
| Text expansion buffer (German) | 30-40% |
| Social login placement | Above email login |
