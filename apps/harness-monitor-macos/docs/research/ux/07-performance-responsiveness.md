# Performance and responsiveness - comprehensive reference

## 1. Response time thresholds

### Jakob Nielsen's research (still valid)

| Duration | Perception | Required feedback |
|----------|-----------|-------------------|
| 0-100ms | Instantaneous | None needed |
| 100ms-1s | Noticeable delay, flow maintained | Subtle indicator (button state change, spinner in toolbar) |
| 1-10s | Attention wanders | Spinner with label, cancel option |
| 10s+ | Context lost | Progress bar with percentage/count, cancel mandatory |
| 30s+ | Patience exhausted | Progress bar + estimated time, allow background operation |

### Per-interaction targets
- Button press visual response: within 1 frame (16ms at 60fps, 8ms at 120fps)
- Toggle state change: animation starts within 1 frame
- List item selection highlight: within 1 frame
- Keyboard character echo: within 1 frame
- Navigation push/pop: begin transition within 100ms
- Search results: first results within 500ms, debounce input at 300ms
- Network request feedback: show spinner after 1 second of no response
- Form submission: disable button + show spinner within 100ms

## 2. Animation performance

### Frame rate targets
- 60fps minimum (16.67ms per frame budget) on standard displays
- 120fps (8.33ms per frame) on ProMotion displays (iPhone 13 Pro+, iPad Pro, MacBook Pro)
- A single dropped frame is perceptible during smooth animation
- During scroll: 60fps minimum, any hitch is immediately visible

### Main thread budget
- Never block the main thread for more than 16ms
- View body evaluation must be fast - no network calls, no disk I/O, no heavy computation
- Image decoding: always off main thread (use AsyncImage or background decode)
- JSON parsing: background thread for payloads > 1KB
- Core Data / SwiftData fetches: use background contexts for large queries

### SwiftUI animation specifics
- Use `.animation(.default, value: someValue)` with explicit value parameter (not bare `.animation(.default)`)
- `.drawingGroup()` for complex vector rendering (rasterizes to Metal)
- Avoid `GeometryReader` in scrollable content (causes layout passes)
- `LazyVStack` / `LazyHStack` for lists over 20 items
- `List` for cell recycling with 100+ items
- Profile with Instruments: SwiftUI template, Time Profiler, Core Animation

## 3. Launch time optimization

### Targets
- Cold launch to first meaningful content: under 400ms
- Warm launch (app was recently terminated): under 200ms
- Resume from background: under 100ms (essentially instant)

### Strategies
- Defer non-critical initialization: analytics, prefetching, background sync
- Show cached/local data first, then refresh from network
- Launch screen matches first screen layout (prevents jarring transition)
- Minimize work in App/Scene init and first view body
- Lazy-load features not needed at launch (use lazy properties, on-demand imports)
- Avoid synchronous network calls at launch
- Pre-warm: if the app knows what the user will see, prepare it during launch screen

### What to measure
- Time from process start to first frame rendered (pre-main + post-main)
- Time to interactive: when user can actually tap/click and get a response
- Use Instruments > App Launch template
- MetricKit for field measurements

## 4. Scroll performance

### Requirements
- 60fps during scroll at all times
- No layout shifts during scroll (content jumping)
- No visible cell recycling artifacts (content flickering on reuse)

### Strategies
- Use List (has built-in cell recycling) for 50+ items
- LazyVStack for custom layouts with many items
- Fixed-height rows when possible (avoid dynamic height calculation during scroll)
- Image loading: placeholder -> async load -> fade in (don't block cell layout)
- Prefetch: load next page of data when within 5 items of the end
- Avoid complex view hierarchies in scroll cells (flatten where possible)
- `.task` on cells for deferred loading (cancelled on cell reuse)

### Common scroll performance killers
- `GeometryReader` inside scroll items
- Shadows with large blur radius on every cell
- Complex opacity/blur effects per cell
- Synchronous image loading in cell body
- Unbounded text layout (Text without line limit in variable-height cells)

## 5. Memory management

### Image memory
- Always downsample images to display size before rendering
- Don't hold full-resolution images in memory for thumbnail display
- Cache tiers: memory cache (NSCache, auto-purges) -> disk cache -> network
- Respond to memory warnings: purge caches, release non-visible resources
- Maximum memory for image cache: 50-100MB (depends on device)

### View lifecycle
- Avoid retain cycles: use `[weak self]` in closures that capture self
- Cancel tasks when views disappear: `.task` does this automatically
- Don't store large data in @State (it lives for the view's lifetime)
- @StateObject lifecycle: created on first appear, destroyed on removal from tree
- Observable objects: don't hold references to views

### Background limits (iOS)
- Background execution: 30 seconds after entering background (unless BGTask)
- Background refresh: use BGAppRefreshTask (system-scheduled, ~30s execution)
- Background processing: use BGProcessingTask (longer, overnight-type work)
- Respond to memory pressure: implement didReceiveMemoryWarning / observe memory notifications

## 6. Network-dependent UI

### Optimistic updates
- Update UI immediately on user action (assume success)
- If server returns error, revert the change and show error
- Works for: toggling favorites, sending messages, reordering items
- Don't use for: destructive actions, financial transactions, permission changes

### Loading states
- Skeleton screens for known content layouts (lists, cards, profiles)
- Shimmer animation: 1500ms cycle, left-to-right gradient sweep
- Spinner only for indeterminate short waits (under 5 seconds expected)
- Progress bar for known-length operations (upload, download, sync)
- Text label with progress: "Loading 3 of 12 items..."
- Never show a blank screen

### Offline-first patterns
- Cache all successfully loaded data
- Show cached data immediately, refresh in background
- "Last updated" timestamp on cached data
- Queue writes when offline, sync when reconnected
- Non-intrusive offline indicator (banner, not alert)
- Read-only mode when offline is better than "no access"

### Retry and timeout
- Network timeout: 30 seconds default
- Auto-retry with exponential backoff: 1s, 2s, 4s, 8s, max 30s
- Maximum auto-retries: 3
- After max retries: show error with manual "Retry" button
- Cancel button always available during network operations
- Show "Retrying..." with attempt count during auto-retry

### Stale-while-revalidate
- Show cached data immediately (even if potentially stale)
- Fetch fresh data in background
- When fresh data arrives: update UI (with animation if layout changes)
- Show "Updated just now" indicator after refresh
- Don't show loading spinner if cached data is available

## 7. Input responsiveness

### Touch/click response
- Must start visual feedback within 1 frame (16ms)
- Button highlight on touch-down, not touch-up
- Don't wait for touch-up to show press state
- Scroll: no input lag, direct manipulation feel (1:1 finger tracking)

### Keyboard input
- Character must appear within 1 frame of keystroke
- No buffering of keystrokes (each appears immediately)
- Auto-complete suggestions: update within 100ms of keystroke
- Search as-you-type: debounce at 300ms, show results within 500ms of last keystroke
- Don't validate on every keystroke (too disruptive) - validate on blur or submit

### Gesture recognition
- System gestures have priority (home, notification center)
- App gestures should not conflict with system gestures
- Simultaneous gesture recognition where it makes sense
- Long press threshold: 500ms (system default)
- Swipe velocity threshold: respect system defaults

## 8. Background processing

### Thread strategy
- Main thread: UI only (view rendering, user input, animation)
- Background threads: network, disk I/O, image processing, data parsing, crypto
- Use async/await with `.task` modifier for view-tied background work
- Use actors for isolated mutable state
- DispatchQueue.global() for one-off background work

### Progress reporting
- Observable property on the background task
- Update progress from background, UI observes on main thread
- Throttle progress updates to ~10/second (don't flood the UI)
- Show indeterminate progress first, switch to determinate when total is known

### Cancellation
- All background tasks must support cancellation
- `.task` modifier handles cancellation automatically on view disappear
- Check `Task.isCancelled` in long-running loops
- Cancel previous search when new search starts (`.task(id:)`)
- Cancel network requests when user navigates away

## 9. Battery and thermal

### Rules
- No timer-based polling when push notifications or streams are available
- Coalesce network requests (batch API calls, don't make one per item)
- Reduce GPS accuracy when high precision isn't needed
- Defer non-urgent work: use BGProcessingTask
- Respect Low Power Mode: reduce animations, defer background work
- Minimize GPU overdraw: don't stack transparent layers unnecessarily
- Profile with Instruments > Energy Log

### Specifics
- Location: use significant location changes instead of continuous GPS when possible
- Networking: use URLSession background tasks for large downloads
- Animation: reduce frame rate when Low Power Mode is on (CADisplayLink preferred frame rate)
- Timer coalescing: use tolerance on timers to allow the system to batch wake-ups

## 10. Perceived performance techniques

### Content-first loading
- Text renders before images (text is smaller, faster to transmit)
- Above-the-fold content loads before below-the-fold
- Critical path: show the minimum viable content first, enhance after
- Images: show placeholder (skeleton/blur/dominant color) then load actual

### Preloading
- Preload the most likely next screen's data during idle
- Prefetch next page of list data when user is within 5 items of the end
- Pre-render upcoming views if navigation path is predictable
- Don't preload aggressively on cellular or Low Power Mode

### Masking load time with transitions
- 300ms navigation transition covers 300ms of data loading
- Show skeleton for remaining load time after transition completes
- Fade in content as it arrives (200ms crossfade)
- Stagger content appearance: header first, then items (50ms stagger, max 5)

### Layout stability
- Reserve space for content before it loads (prevent layout shift)
- Fixed image dimensions: set frame size before image loads
- Don't insert elements above the user's scroll position
- Skeleton must match final layout exactly (same heights, widths, positions)
- Content replacing skeleton should not cause scroll position changes

---

## Quick reference: performance budgets

| Metric | Target |
|--------|--------|
| Cold launch to first content | < 400ms |
| Warm launch | < 200ms |
| Background resume | < 100ms |
| Animation frame rate | 60fps (120fps ProMotion) |
| Main thread block | < 16ms |
| Touch response | < 16ms (1 frame) |
| Search debounce | 300ms |
| Search results appear | < 500ms |
| Network timeout | 30s |
| Auto-retry backoff | 1s, 2s, 4s, 8s, max 30s |
| Max auto-retries | 3 |
| Skeleton shimmer cycle | 1500ms |
| Content fade-in | 200ms |
| Progress update throttle | 10/second |
| Image memory cache | 50-100MB |
| Scroll frame budget | 16.67ms |
