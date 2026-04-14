# Session Timeline Revision Design

Date: 2026-04-14
Status: Approved for implementation
Scope: `src/daemon/*`, `apps/harness-monitor-macos/*`

## Problem

The session cockpit currently treats the timeline as a single full array.
Opening a cockpit can briefly show cached rows, then blank or spinner state, then a reloaded array that is often identical.
The monitor also derives the visible total from the currently synced rows instead of from authoritative daemon state.
This wastes work, degrades perceived performance, and makes correctness depend on client-side heuristics.

## Goals

- Make timeline correctness server-owned and future-proof.
- Avoid full-history timeline rereads on cockpit open.
- Keep cached rows visible until precise live data is ready.
- Show authoritative total-count immediately.
- Replace full-block loading with row-level skeleton placeholders.
- Support cheap incremental refresh and page navigation.

## Non-Goals

- Rework the task, signal, or agent detail surfaces outside the timeline.
- Change the semantic content of timeline rows.
- Add approximate or eventually-correct client-side reconciliation heuristics.

## Decision

Introduce a canonical daemon timeline ledger with per-session revision tracking.
The daemon becomes the single source of truth for timeline ordering, dedupe, count, and change detection.
The monitor stores and renders a viewport window, not a full timeline snapshot.

## Architecture

### 1. Canonical Daemon Ledger

Add two daemon DB surfaces:

- `session_timeline_entries`
- `session_timeline_state`

`session_timeline_entries` stores canonical rows for one session timeline.
Each row has:

- `session_id`
- `entry_id`
- `source_kind`
- `source_key`
- `recorded_at`
- `kind`
- `agent_id`
- `task_id`
- `summary`
- `payload_json`
- `sort_recorded_at`
- `sort_tiebreaker`

`source_key` must be stable for every producer so replacement-style syncs can diff old and new rows without ambiguity.

Candidate source-key rules:

- session log transition: `log:<sequence>`
- task checkpoint: `checkpoint:<checkpoint_id>`
- conversation event: `conversation:<agent_id>:<sequence>`
- signal acknowledgment snapshot entry: deterministic from `signal_id`
- observer snapshot entry: deterministic singleton key per session

`session_timeline_state` stores:

- `session_id`
- `revision`
- `entry_count`
- `newest_recorded_at`
- `oldest_recorded_at`
- `integrity_hash`
- `updated_at`

`revision` advances only when the visible canonical timeline changes.
Writers update entries and state in one transaction.

### 2. Producer Rules

Timeline producers must write into the canonical ledger instead of relying on read-time merging.

Append-style producers:

- session log writes
- task checkpoint writes

These append one canonical row and bump `revision` and `entry_count` in the same transaction.

Replacement-style producers:

- conversation event sync
- observer-derived timeline entries
- synthesized signal-ack rows if their source remains derived

These compute the next canonical row set for their source, diff against existing `source_key`s, apply inserts and deletes, and bump `revision` only if the canonical result changed.

### 3. Read Contract

Replace the current whole-array timeline response with a windowed contract.

New response shape:

- `revision`
- `total_count`
- `window_start`
- `window_end`
- `has_older`
- `has_newer`
- `oldest_cursor`
- `newest_cursor`
- `entries`

New query modes:

- latest window by `limit`
- window before `cursor`
- window after `cursor`
- latest window with `known_revision`

If `known_revision` matches current state and the requested latest-window shape still matches, the daemon may return:

- unchanged metadata
- authoritative `total_count`
- no entries payload

That allows the monitor to keep cached rows without any client-side overlap guesswork.

### 4. Push Contract

Session push updates must carry lightweight timeline metadata:

- `timeline_revision`
- `timeline_count`

The daemon does not need to push full timeline rows for every session mutation.
The monitor compares the pushed revision to the active viewport revision.
If unchanged, no timeline fetch is needed.
If changed, the monitor requests only the affected window from the daemon.

### 5. Monitor State Model

Replace the selected-session timeline array as the primary model with a viewport state.

New selected-session timeline state:

- `revision`
- `totalCount`
- `pageSize`
- `currentPage`
- `windowStart`
- `windowEnd`
- `hasOlder`
- `hasNewer`
- `entries`
- `isUsingCachedWindow`
- `isViewportRefreshInFlight`
- `placeholderRowCount`

The existing `[TimelineEntry]` convenience surface may remain temporarily for compatibility, but it must become derived from the viewport state.

### 6. Cache Model

Persist only the latest useful viewport window, not the full history.

Persisted timeline snapshot fields:

- `session_id`
- `revision`
- `total_count`
- `window_start`
- `window_end`
- `page_size`
- cached `entries`
- `last_cached_at`

This gives the monitor an immediate authoritative-feeling snapshot on relaunch without the storage and sync cost of caching every historical row.

### 7. Cockpit Behavior

When opening a cockpit:

#### With cached snapshot

- Render cached detail and cached latest-window rows immediately.
- Mark them as cached.
- Request `latest(limit: pageSize, knownRevision: cachedRevision)`.
- If unchanged, keep rows and flip the data availability to live.
- If changed, patch the visible viewport with the new canonical latest window.

#### Without cached snapshot

- Render detail as soon as available.
- Request only the latest page window.
- Show row skeletons for the missing rows in the viewport instead of a full timeline spinner.

#### Paging older history

- Request only the needed older window.
- Do not materialize all prior pages.
- Keep current visible rows stable while the requested page fills.

### 8. UX Rules

The timeline section must not replace the whole card with a loader after cached rows are already visible.

Loading behavior:

- existing rows remain mounted
- row identity is `entry_id`
- missing rows render skeleton placeholders
- the placeholder style is shimmer text bars moving left-to-right
- page summary and pagination chrome remain visible

Count behavior:

- `Showing X-Y of Z` uses authoritative `totalCount`
- `Z` never depends on the number of locally materialized rows

### 9. Migration

Implementation order:

1. Add canonical DB schema and read APIs.
2. Backfill canonical rows from current DB/file sources on session sync or daemon startup.
3. Add windowed HTTP and WebSocket timeline responses.
4. Update monitor client protocol and recording client.
5. Add monitor viewport state and cache schema.
6. Update cockpit UI to row-level placeholders and authoritative counts.
7. Remove old full-array timeline assumptions from hot paths.

Migration must preserve existing data.
If canonical timeline state is absent for a session, the daemon rebuilds it once from existing sources and then serves windowed reads from the canonical ledger.

## Tests

### Rust

- canonical append updates `revision` and `entry_count`
- replacement sync bumps `revision` only on visible change
- latest window returns newest `N` rows and exact `total_count`
- latest window with matching `known_revision` returns unchanged result without rows
- before/after cursor windows return stable pagination boundaries
- late-arriving or reordered source sync still produces correct canonical ordering

### Swift

- cached cockpit timeline remains visible during live refresh
- selected-session open with no cache fetches latest window only
- matching revision keeps cached rows and avoids row replacement
- changed revision swaps only the viewport rows, not the whole card
- page summary reads authoritative total count
- loading viewport renders skeleton rows instead of a full spinner

## Risks

- Canonicalizing the timeline ledger touches several daemon write paths and requires careful transaction design.
- Conversation-event sync is replacement-style today, so `source_key` correctness is critical.
- Cache schema changes need migration support in SwiftData.

## Open Decisions Resolved

- Chosen approach: canonical server-owned revision ledger.
- Chosen count source: daemon timeline state, not client-side array size.
- Chosen cache scope: latest viewport window plus metadata, not full history.
- Chosen loading UX: row-level skeletons, never full-card replacement once rows exist.

## Implementation Notes

- Keep DB reads on the preferred DB path and make the new window queries the default hot path.
- Use stable ordering based on `recorded_at` plus deterministic tiebreakers so pagination is repeatable.
- Keep Swift UI state updates granular to avoid another invalidation storm.
- Treat any expensive rebuild as a rare fallback, not as the normal read path.
