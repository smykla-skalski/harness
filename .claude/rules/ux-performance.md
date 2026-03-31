---
globs: "**/*.swift"
description: "Performance and responsiveness rules: response times, animation fps, launch time, scroll, memory, network UI."
---

# Performance rules

## Response time thresholds

| Duration | Perception | Required UI |
|---|---|---|
| 0-100ms | Instantaneous | No feedback needed |
| 100ms-1s | Noticeable | Subtle indicator (button state, toolbar spinner) |
| 1-10s | Attention wanders | Spinner with label, allow cancel at 5s |
| 10s+ | Context lost | Progress bar with count/percentage, cancel mandatory |
| 30s+ | Patience gone | Progress bar + estimated time, allow background |

## Animation

- 60fps minimum (16.67ms frame budget). 120fps on ProMotion (8.33ms).
- A single dropped frame is perceptible during smooth animation.
- Never block the main thread for more than 16ms.
- Profile with Instruments: SwiftUI template, Time Profiler, Core Animation.

## Launch time

- Cold launch to first meaningful content: under 400ms.
- Show cached/local data first, refresh from network in background.
- Defer non-critical initialization to after first frame.
- No synchronous network calls at launch.

## Scroll performance

- 60fps during scroll at all times.
- Use List for 50+ items (cell recycling).
- Image loading: placeholder -> async load -> fade in. Never block cell layout.
- Prefetch next page when within 5 items of the end.
- Avoid GeometryReader, large blur shadows, and complex opacity per cell.

## Main thread budget

- UI rendering, user input, animation only on main thread.
- Background threads for: network, disk I/O, image processing, JSON parsing, crypto.
- Use `.task` modifier for view-tied async work (auto-cancels on disappear).
- Use actors for isolated mutable state.
- Check `Task.isCancelled` in long-running loops.

## Network UI patterns

- Optimistic updates for non-destructive actions (toggle favorite, send message): update UI immediately, revert on server error.
- Stale-while-revalidate: show cached data immediately, fetch fresh in background.
- Skeleton screens: show immediately on navigation, match final layout.
- Auto-retry transient errors with exponential backoff: 1s, 2s, 4s, 8s, max 30s. Max 3 retries.
- Don't auto-retry permanent errors (4xx, auth failures).
- Network timeout: 30 seconds default.
- Cancel button always available for operations over 2 seconds.

## Memory

- Downsample images to display size before rendering.
- Cache tiers: memory (NSCache, auto-purges) -> disk -> network.
- Image memory cache: 50-100MB max.
- Cancel tasks when views disappear (`.task` does this automatically).
- Avoid retain cycles: `[weak self]` in closures that capture self.

## Battery

- No timer-based polling when push/streams are available.
- Coalesce network requests.
- Respect Low Power Mode: reduce animations, defer background work.
- Minimize GPU overdraw (don't stack transparent layers).

## Perceived speed

- Show text before images (smaller, faster).
- Preload likely next screen during idle.
- Reserve space for content before it loads (prevent layout shift).
- Stagger content appearance: 30-50ms per item, max 5 items staggered.
- Animate transitions to mask loading time (300ms transition covers 300ms of loading).

## Auto-save

- Save on every meaningful change (debounce 500ms-2s, not every keystroke).
- Save immediately on app backgrounding (iOS) and window close (macOS).
- Restore state after crash: window position, scroll, selection, navigation stack, pending input.
- Use `@SceneStorage` for per-window state, `NSUserActivity` for handoff.
