# Fix stale session liveness presentation in Harness Monitor

## Problem

Harness Monitor currently lets stale or partially refreshed session state look live.

- A selected session can receive a fresher `SessionSummary` while still rendering the older `agents`, `tasks`, `signals`, and `observer` collections from the previous detail snapshot.
- Sidebar and dashboard cards render raw `SessionStatus.title` and `metrics.activeAgentCount`, so cached or leaderless sessions still read like healthy live sessions.
- Agent cards derive `Ready` and `Working` from queue state alone, so disconnected or cached agents can still look ready to act.

The daemon contract already clears dead leaders and drops dead agents from fresh summaries and detail payloads. The remaining problem is monitor-side state retention and presentation.

## Goals

1. Stop showing stale selected-session detail collections once a fresher summary proves the session changed.
2. Present leaderless sessions as leaderless instead of plain live `Active`.
3. Present cached or estimated session data as non-live without inventing a second liveness model per view.
4. Ensure agent cards never show `Ready` or `Working` when the visible state is stale, disconnected, or removed.
5. Cover the regressions with focused `HarnessMonitorKitTests`.

## Non-goals

- No daemon-side contract changes.
- No new UI test suite or full macOS UI validation lane.
- No rework of unrelated monitor navigation, glass, or Agent TUI behavior.

## Current-state findings

### Selected-session refresh path

`refreshSelectedSessionIfSummaryChanged` currently updates the session index summary and then calls `applySelectedSessionSummaryUpdate`, which rewrites only `SessionDetail.session` while preserving the older `agents`, `tasks`, `signals`, `observer`, and `agentActivity` arrays. A delayed fallback reload eventually fixes the detail, but the UI presents the stale collections in the meantime.

### Same-session reload retention

`ContentSessionDetailSlice` intentionally retains the current cockpit during same-session reloads. That behavior is correct for ordinary reload churn, but it also masks the stale-summary bug. Clearing `selectedSession` alone is not enough because the retained presentation stays visible while the summary still points at the same session ID.

### Freshness signal mismatch

The current cached-data tracking is too coarse for this feature. The app needs to distinguish:

1. cached session catalog state used by sidebar/dashboard summaries, and
2. cached selected-session detail state used by the cockpit and agent cards.

Without that split, summary cards can inherit a stale marker just because the selected session is temporarily rendering cached detail.

### Presentation gap

The cockpit already has a stale-session treatment through `SessionDataAvailabilityBanner` and the corner status chrome. Sidebar rows, recent-session cards, and agent cards do not consume a matching presentation layer.

## Proposed design

### 1. Track catalog freshness separately from selected-session detail freshness

Refine the store freshness state so the monitor can tell whether:

- the session catalog itself is cached or estimated, and
- the currently selected session detail is cached or estimated.

The selected-session freshness continues to drive cockpit chrome and detail behavior. The catalog freshness drives sidebar and dashboard summary-card presentation.

This keeps summary surfaces accurate when the app is online but the selected session is temporarily showing cached detail, and it keeps cached catalog snapshots visibly non-live during reconnect or offline flows.

### 2. Invalidate stale selected detail immediately when a fresher summary lands

When a `sessionsUpdated` push delivers a newer summary for the currently selected session:

1. apply the summary update to the session index immediately,
2. clear the selected detail/timeline back to the existing summary-backed loading surface,
3. explicitly disable same-session retained-detail presentation for this refresh path, and
4. keep the existing live detail reload/session-stream recovery path responsible for filling the exact detail back in.

This is intentionally different from offline persisted viewing. Persisted offline selection may still show cached detail, because that is the best available snapshot. The new invalidation only applies when a live summary proves the previously rendered detail is stale.

### 3. Add shared liveness presentation values in HarnessMonitorKit

Introduce store-tested presentation helpers for session summaries and agent cards instead of baking the logic into SwiftUI views.

#### Session summary presentation rules

The session-summary presentation helper should derive:

- primary status text,
- whether the status is estimated/cached,
- metric phrasing, and
- accessibility copy.

Rules:

1. **Leaderless wins over plain live `Active`.** If `leaderId == nil` and the session is not ended, the primary status becomes leaderless rather than raw `Active`.
2. **Only live, leader-led sessions use live-agent phrasing.** Copy like `2 active` is reserved for live, leader-led sessions.
3. **Cached or estimated summaries use neutral phrasing.** Cached summaries should use non-live copy such as snapshot/known-agent wording instead of current-looking live-agent wording.
4. **Ended sessions keep their terminal meaning.** Estimated/cached treatment can be additive, but it must not erase the fact that a session is ended.

#### Agent card presentation rules

The agent-card presentation helper should derive the queue/activity badge from:

- the agent's recorded status,
- whether the visible selected-session detail is live, and
- queued-task/current-task information.

Rules:

1. `Ready` and `Working` are only valid for live selected-session detail with an `.active` agent.
2. `.disconnected` always renders as disconnected, regardless of queue state.
3. `.removed` always renders as removed.
4. Cached selected-session detail renders snapshot/estimated activity copy instead of `Ready` or `Working`.
5. If a fresh detail no longer includes an agent, the card disappears because the selected detail was invalidated before the new detail loads.

### 4. Reuse the existing stale cockpit language

The cockpit already has the correct non-live visual language:

- `SessionDataAvailabilityBanner`
- stale corner status chrome

The new work should reuse that signal rather than creating a second stale-state visual system.

Sidebar rows and dashboard cards should consume the new summary presentation values. Agent cards should consume the new agent activity presentation values.

### 5. Keep the implementation local to monitor store and view wiring

Expected implementation touch points:

- `HarnessMonitorStore+ConnectionTelemetry.swift`
- `HarnessMonitorStore+Hydration.swift`
- `HarnessMonitorStore+Lifecycle.swift`
- `HarnessMonitorStore+StreamingSelectionSupport.swift`
- `HarnessMonitorStore+Slices.swift`
- `HarnessMonitorStore+ContentSlices.swift`
- `HarnessMonitorStore+SliceModels.swift` or a nearby presentation-support file
- `SidebarSessionRow.swift`
- `SessionsBoardRecentSessionsSection.swift`
- `SessionAgentLaneViews.swift`

No daemon-side Rust changes are required.

## Data flow after the change

### Selected session

1. Global session push updates the catalog.
2. If the selected session summary changed materially, the store updates the selected summary and invalidates the currently rendered detail presentation.
3. The content surface falls back to the existing summary-backed loading UI instead of retaining the stale cockpit.
4. Session stream or fallback reload applies fresh detail and timeline.
5. Fresh detail clears the selected-session cached marker and restores normal live agent/task presentation.

### Sidebar and dashboard

1. Summary views read precomputed liveness presentation values.
2. Leaderless sessions show leaderless status.
3. Cached catalog state uses non-live status/metric phrasing.
4. Live catalog state keeps the existing active/paused/ended semantics.

### Agent lane

1. Agent cards read precomputed activity presentation values.
2. Live active agents may show `Ready`, `Working`, or queued-task copy.
3. Non-live or disconnected states never show `Ready`.

## Error handling and behavior boundaries

- If a fresh summary arrives but the immediate detail reload fails, the UI remains in the summary-backed loading state rather than reverting to the older stale cockpit.
- Offline persisted restore remains allowed to show cached detail because no fresher live summary has invalidated it.
- The design does not silently synthesize agent/task/signal state from mismatched sources. Either the app has a fresh detail payload, or it shows loading/estimated presentation.

## Testing strategy

Add focused `HarnessMonitorKitTests` covering:

1. **Selected-session stale-summary invalidation**
   - same-session summary update clears stale selected detail presentation instead of preserving old agent/task/signal arrays
   - the content slice falls back to the summary-backed loading surface until fresh detail arrives

2. **Summary presentation**
   - leaderless sessions render leaderless presentation
   - cached catalog summaries use non-live metric phrasing instead of live-agent phrasing

3. **Agent activity presentation**
   - disconnected agents do not show `Ready`
   - removed agents do not show `Ready`
   - cached selected-session detail does not show `Ready` or `Working`

4. **Regression coverage for existing persisted flows**
   - offline persisted selection still restores cached detail intentionally
   - live hydration still upgrades summary-backed or cached selection once fresh detail arrives

## Done bar

1. Targeted `HarnessMonitorKitTests` for stale-summary invalidation pass.
2. Targeted `HarnessMonitorKitTests` for leaderless/cached summary presentation pass.
3. Targeted `HarnessMonitorKitTests` for agent-card non-live presentation pass.
4. The smallest targeted macOS build/test lane covering the touched monitor files passes.

## Implementation notes

- Preserve unrelated existing changes in the dirty main-branch worktree.
- Keep the fix in Harness Monitor store/presentation layers first, with SwiftUI views as thin consumers of the derived state.
- Prefer value-type presentation helpers so the behavior is easy to test without UI automation.
