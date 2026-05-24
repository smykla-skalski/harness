# Data display and information patterns - comprehensive reference

## 1. Data tables and grids

### Column alignment
- Text: left-aligned
- Numbers: right-aligned (decimal points align)
- Dates: left-aligned (consistent format)
- Status badges: center-aligned
- Actions (buttons/icons): center-aligned
- Boolean (checkmarks): center-aligned

### Header styling
- Bold or semibold weight, same size as body or 1pt larger
- Sort indicator: up/down arrow next to sorted column header
- Current sort: filled arrow. Sortable but not sorted: subtle/hidden arrow
- Click header to sort, click again to reverse. Third click to clear sort
- Sticky header: stays visible when table scrolls vertically

### Row specifications
- Compact: 28-32pt row height, 8pt horizontal cell padding
- Regular: 36-44pt row height, 12pt horizontal cell padding
- Spacious: 48-56pt row height, 16pt horizontal cell padding
- Minimum column width: 60pt (narrow data like status), 120pt (text content)
- Row hover: subtle background highlight (5-8% opacity accent color) on macOS
- Selected row: accent color background at 15-20% opacity

### Zebra striping vs dividers
- Zebra striping: optional, 3-5% background tint difference between alternating rows
- Dividers: hairline (0.5pt) between rows, separator color
- Whitespace: 4-8pt vertical padding within cells for visual separation
- Use one method, not multiple simultaneously

### Column features
- Resizable: drag column border to resize (min width enforced)
- Reorderable: drag column header to reorder (optional, power user)
- Frozen columns: first column (ID/name) stays visible during horizontal scroll
- Sortable: all data columns sortable by click

### Selection
- Single selection: click row to select, highlight with accent background
- Multi-selection: Cmd+click (macOS) for non-contiguous, Shift+click for range
- Checkbox column: leading checkbox for explicit multi-select (preferred for batch actions)
- Select all: checkbox in header row

### Empty table
- "No data" message centered in the table area
- If filtered: "No results match your filters. [Clear filters]"
- If first use: explain what data will appear here

### Pagination vs infinite scroll
- Pagination: for structured data (search results, admin). Show page count, current page, items per page
- Default page size: 25 items
- Infinite scroll: for feed/timeline content. Loading indicator at bottom
- Load more button: user-controlled loading for long lists. "Load 25 more (showing 50 of 342)"
- Always show total count: "1-25 of 342 items"

## 2. Lists and collections

### List item anatomy
- Leading: icon or avatar (20-40pt, depending on context)
- Primary text: item name/title, body weight
- Secondary text: subtitle or description, secondary color, smaller size
- Trailing: accessory (chevron, value, badge, or action button)
- Row height: 44pt minimum on iOS, 28-32pt on macOS for single-line

### List styles
- Grouped (inset): rounded-corner sections with section headers/footers. Use for settings, forms
- Plain: flat list without section decoration. Use for content lists, search results
- Sidebar: macOS sidebar with auto-selection styling

### Section headers and footers
- Header: descriptive section title, uppercase caption style or headline style
- Footer: explanatory text for the section above, secondary color, caption size
- Sticky headers: section headers stay visible during scroll within that section

### Swipe actions
- Trailing (swipe left): destructive actions (delete, archive). Red for delete
- Leading (swipe right): positive actions (mark read, pin, favorite). Custom color
- Full swipe: executes the first action directly (e.g., full swipe left to delete)
- Maximum actions per side: 3 (more becomes unusable)
- Icon + short label for each action

### Multi-select and batch operations
- Enter selection mode: Edit button or long-press
- Checkbox on each row in selection mode
- "Select All" at the top
- Batch action toolbar appears at bottom with available actions
- Exit selection mode: Done button or Cancel

### Reordering
- Edit mode: drag handle appears on trailing edge
- Visual feedback: lifted item has shadow, gap shows insertion point
- Haptic feedback on grab and on snap (iOS)
- Only allow reordering where manual order is meaningful (playlists, priorities)

### Search and filtering
- Search bar at top of list (or Cmd+F)
- Filter results as user types (debounce 300ms)
- Show result count: "3 results"
- Highlight matching text in results
- Clear search: X button in search field
- Recent searches: show last 5-10 searches

## 3. Cards and tiles

### Card anatomy
- Media area: image/preview at top or leading edge
- Title: headline weight, 1-2 lines maximum
- Description: body text, 2-3 lines maximum with truncation
- Metadata: timestamp, author, category. Caption style, secondary color
- Actions: 1-2 buttons or a menu at the bottom or trailing edge

### Card sizing
- Fixed width within grid columns
- Variable height based on content (constrained by line limits)
- Minimum card width: 160pt (compact), 200pt (regular)
- Card spacing/gap: 12-16pt between cards

### Card interactions
- Tap/click: navigates to detail (primary action)
- Long press / right-click: context menu with secondary actions
- Hover (macOS): subtle elevation increase (additional shadow)
- No interactive controls within a card that conflict with the card's tap action

### Card consistency
- All cards in a collection must have the same structure
- Same padding, same font sizes, same image aspect ratio
- If one card has an image, all should (or have a placeholder)
- Variable content: fixed layout, variable content length (truncate/clamp)

## 4. Status and badges

### Status color system
- Green (#34C759 / #30D158): active, online, success, healthy, completed
- Yellow (#FFCC00 / #FFD60A): warning, pending review, attention needed
- Orange (#FF9500 / #FF9F0A): caution, degraded, needs action soon
- Red (#FF3B30 / #FF453A): error, offline, critical, failed
- Blue (#007AFF / #0A84FF): informational, in progress, selected
- Gray (#8E8E93 / #636366): inactive, disabled, unknown, archived
- Purple (#AF52DE / #BF5AF2): scheduled, queued, draft

### Status indicators
- Dot indicator: 8-10pt filled circle, colored by status. Use for simple on/off states
- Badge count: rounded rectangle with number. Red for alerts, blue/gray for counts
- Max badge display: "99+" for counts over 99
- Status text: always include a text label alongside color. "Online" not just green dot
- Pulsing animation: for live/active status (respect Reduce Motion)

### Placement
- Dot: corner of avatar/icon (offset 2pt into the element)
- Badge count: top-right corner of parent element
- Status text: inline with other metadata
- Status bar/chip: colored background pill with text label

## 5. Charts and data visualization

### Chart type selection
- Bar chart: comparing quantities across categories
- Line chart: trends over time
- Pie/donut chart: parts of a whole (maximum 5-7 segments; collapse small ones into "Other")
- Area chart: volume over time
- Scatter plot: correlation between two variables

### Accessibility
- Every chart must have a VoiceOver description summarizing the data
- Provide a data table alternative accessible to screen readers
- Don't rely on color alone to distinguish data series (use patterns, shapes, or line styles)
- Colorblind-safe palettes: avoid red/green as the only distinguishing pair

### Visual rules
- Always label axes (with units)
- Y-axis starts at zero for bar charts (non-zero baseline is misleading)
- Legend: outside the chart area, not overlapping data
- Tooltip on hover: show exact value for the data point
- Grid lines: subtle (5-10% opacity), horizontal only for most charts
- Animate on data update: 300ms ease-in-out transition

### Responsive sizing
- Minimum chart width: 200pt
- Minimum chart height: 150pt
- Chart should fill available width with appropriate aspect ratio (16:9 to 4:3)
- Labels and legends scale with chart size (hide secondary labels at small sizes)

## 6. Dates and times

### Relative vs absolute time
- Under 1 minute: "Just now"
- 1-59 minutes: "5 minutes ago"
- 1-23 hours: "3 hours ago"
- Yesterday: "Yesterday at 2:30 PM"
- 2-6 days: "Tuesday at 2:30 PM"
- 7+ days: absolute date ("Mar 15, 2024")
- Tooltip on relative time showing full absolute timestamp

### Formatting rules
- Respect user's locale for date format (MM/DD/YYYY vs DD/MM/YYYY vs YYYY-MM-DD)
- Use system DateFormatter / FormatStyle, not hardcoded formats
- Time: 12-hour with AM/PM or 24-hour based on user's system preference
- Time zones: show user's local time by default. If showing another zone, label it: "2:30 PM EST"
- Date range: "Mar 15-22, 2024" (don't repeat month/year if same)
- Duration: "1h 23m" for short durations, "2 days, 3 hours" for longer ones

## 7. Numbers and quantities

### Formatting
- Use locale-aware formatters (NumberFormatter / FormatStyle)
- Thousands separator: locale-dependent (1,234 or 1.234)
- Decimals: as few as meaningful. Prices: 2 decimals. Percentages: 0-1 decimal
- Large numbers abbreviation: 1.2K (1,200), 3.4M (3,400,000), 1.5B
- Abbreviation tooltip: show exact value on hover/long-press
- File sizes: binary units (KB, MB, GB). Use ByteCountFormatter
- Negative numbers: minus sign, not parentheses (accounting convention only in financial apps)

### Currency
- Symbol before or after based on locale ($100.00 vs 100,00 EUR)
- Always 2 decimal places for most currencies
- Use Locale.current for formatting
- Explicit currency code when multiple currencies are possible

### Percentages
- One decimal max: 42.7%
- Whole numbers when possible: 100%, 50%, 0%
- Progress: integer percentage only (73%)
- Don't show more than 100% (cap at 100% or explain why it exceeds)

## 8. Text content

### Truncation
- Single line: ellipsis at tail ("This is a very long ti...")
- Filename: middle truncation ("my_very_lo...ument.pdf")
- Multi-line clamp: show 2-3 lines, "Show more" link to expand
- Truncated content: tooltip with full text (macOS) or tap to expand (iOS)
- Never silently truncate without visual indicator

### Copy to clipboard
- Technical values (IDs, hashes, URLs, API keys): click/tap to copy
- Show brief "Copied" confirmation (1-2 seconds, fade out)
- Visual indicator that value is copyable: subtle background on hover, copy icon
- Copy should get the full value, not the truncated display

### Rich text display
- Render markdown in user-generated content where appropriate
- Links: underlined, accent colored, open in default browser
- Code blocks: monospace font, subtle background, horizontal scroll if too wide
- Line numbers in code blocks (optional, for reference)
- Don't render arbitrary HTML from user input (security risk)

### Links
- Underlined + colored (accent color)
- Visited state: slightly different shade (optional, useful for navigation-heavy UIs)
- Hover (macOS): cursor changes to pointer
- External links: open in default browser. Internal links: navigate within app
- Open-in-new-window indicator for external links (optional)

## 9. Search and filtering

### Search bar
- Prominent placement: top of the content area
- Magnifying glass icon on leading edge
- Placeholder text: "Search items..." (specify what's being searched)
- Clear button (X) appears when field has text
- Cancel button on iOS to dismiss keyboard and clear

### Search behavior
- Instant search (filter as you type) for local data, debounced at 300ms
- Server search: debounce at 300ms, show "Searching..." after 500ms
- Show result count: "5 results" or "5 of 342 items match"
- Highlight matching text in results (bold or background highlight)
- No results: "No results for 'query'. Try different keywords."

### Suggestions
- Recent searches: show last 5-10 when search field is focused
- Auto-complete: show suggestions after 2+ characters
- Popular/trending searches (if applicable)
- Category suggestions: "Search in: All, Projects, Files, People"

### Filtering
- Filter controls: segmented control for 2-5 options, dropdown for more
- Active filter indicators: colored pills/chips below search bar showing active filters
- Each filter chip has an X to remove it
- "Clear all filters" button when any filters are active
- Filter state preserved during navigation (until explicitly cleared)
- Show filtered count: "Showing 12 of 342 items"

## 10. Notifications and alerts (in-app)

### Toast/banner notifications
- Position: top of screen (iOS) or top-right of window (macOS)
- Auto-dismiss: 4-8 seconds (longer for more text)
- Manually dismissable (X button or swipe)
- Non-blocking: don't cover interactive content
- Stack: newest on top, max 3 visible, older ones collapse
- Action button optional: "Undo", "View", "Retry"

### In-line alerts
- Position: at the top of the relevant section (not global)
- Persistent: stays until user dismisses or issue is resolved
- Color-coded: blue (info), yellow/orange (warning), red (error), green (success)
- Structure: icon + title + description + optional action
- Dismissable: X button for informational, not for errors (error stays until fixed)

### Badge counts
- Unread/pending counts on navigation items
- Tab bar badges: small red circle with white number
- Maximum display: "99+" (don't show huge numbers)
- Real-time update: badge count changes without page refresh
- Clear on view: badge count decrements when user views the item

### Notification grouping
- Group by source or conversation
- Show summary: "3 new messages from Team Chat"
- Expand to see individual items
- Priority ordering: errors/urgent first, informational last

---

## Quick reference: data formatting

| Data type | Format | Example |
|-----------|--------|---------|
| Relative time (< 1 min) | "Just now" | Just now |
| Relative time (< 1 hour) | "N minutes ago" | 5 minutes ago |
| Relative time (< 24 hours) | "N hours ago" | 3 hours ago |
| Relative time (yesterday) | "Yesterday at TIME" | Yesterday at 2:30 PM |
| Absolute date | Locale format | Mar 15, 2024 |
| Date + time | Date at time | Mar 15, 2024 at 2:30 PM |
| Duration (short) | Nh Nm | 1h 23m |
| Duration (long) | N days, N hours | 2 days, 3 hours |
| Number (small) | Full digits | 1,234 |
| Number (large) | Abbreviated | 3.4M |
| File size | Binary units | 1.2 GB |
| Percentage | N% or N.N% | 42.7% |
| Currency | Locale format | $1,234.56 |
| Phone | Grouped | 555-123-4567 |
