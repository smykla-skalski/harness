# AGENTS.md

This directory is the previewable SwiftUI layer for Harness Monitor. The
app-level `apps/harness-monitor/AGENTS.md` still applies; this file is the
local structure contract for `Sources/HarnessMonitorUIPreviewable/`.

Inline previews have been extracted. Runtime implementation files should stay
free of `#Preview`; preview code belongs in the nearest `Previews/` folder.

## Placement

- `Views/` is feature-first UI source. Do not add files directly under `Views/`;
  choose a domain folder.
- Existing domains: `Actions`, `Agents`, `App`, `Attention`, `Decisions`,
  `Settings`, `Review`, `Sessions`, `Shared`, `Sidebar`, `Signals`,
  `Timeline`, `Toolbar`, `Voice`, and `Workspace`.
- `Views/<Domain>/Previews/` holds dedicated preview files.
- `Support/` holds cross-cutting non-view support for this target.
- `Theme/` holds shared styling primitives.
- `Features/` holds feature-flagged source roots only.
- `Assets.xcassets` holds target resources.

## Preview rules

1. Prefer dedicated preview files over inline previews.
2. Dedicated preview files live in the nearest `Previews/` folder.
3. Preview filenames use a leading `Preview` prefix, for example
   `PreviewWorkspaceWindowView.swift`.
4. Do not introduce trailing preview suffixes such as `+Preview`, `+Previews`,
   `Previews`, or one-off names such as `CrowdedPreview`.
5. Keep preview-only helpers private and next to the preview file unless reused
   by multiple preview files in the same domain. Only then promote them to a
   clearly named support file such as `SettingsPreviewSupport.swift`.

## Domain notes

- `Workspace/Window/` holds `WorkspaceWindowView` and its extensions/support
  strips.
- `Workspace/Sidebar/` holds workspace sidebar-specific surfaces.
- `Settings/Supervisor/` holds supervisor-specific settings panes and split
  helpers.
- `Shared/` is only for reusable UI primitives used by multiple domains. If a
  file serves one feature, keep it in that feature.

## Reviews list row invariants

`Views/Dashboard/DashboardReviewListRow.swift` and its `+Height` / `+Labels` / `+AuthorChip` / `+ReviewerSummary` companions encode a tight visual contract for the narrow dashboard column. Keep these invariants intact when touching the row:

- **Title is allowed up to two lines.** Use `lineLimit(2)` on the title `Text` and let `DashboardReviewListRowHeight.titleLikelyWraps(_:)` decide whether the row pre-allocates the second line via `hasWrappedTitle: true`. Never bump `lineLimit` past 2 — labels and pills below should win the vertical space first.
- **Secondary line is optional.** It only renders the `repository · #N` identity when the list is *ungrouped* (`showsRepository == true`). In repo-grouped mode the secondary line collapses and `#N` rides inline on the status line via `inlineIdentityAndAge`. The `hasSecondaryLine` flag on `DashboardReviewListRowHeight.Layout` must stay aligned with the conditional render or the row's idealHeight will lie.
- **No pin glyph in the title row.** Pinned PRs are signalled by a 3 pt `HarnessMonitorTheme.accent` left stripe overlay plus a soft `accent.opacity(0.05)` row background; the pinned section header carries the only `pin.fill` glyph in the column. Adding a row-level pin icon brings back the duplicate-encoding noise the redesign removed.
- **Leading status icon names the worst attention reason.** When `requiresAttention` is true, `ReviewItem.statusSystemImage` routes through `primaryAttentionSystemImage` in `DashboardReviewsEnumPresentation.swift`. The cascade order (`requiredFailedChecks` > `checkStatus.failure` > `changesRequested` > `policyBlocked` > `mergeable.conflicting`) is pinned by `DashboardReviewListRowStatusIconTests`; bump the test alongside any reorder.
- **Labels share one chip type.** Both the row's label strip and the detail-pane label strip render `DashboardReviewLabelChip` from `DashboardReviewsReviewLabelLists.swift`. The chip takes an optional `descriptor` (for the colour swatch dot) and a `showsSwatch` flag the row strip uses to opt out when only label names are available. Resist introducing a third chip type — extend the shared one instead.
- **Needs Me count uses a circular badge, repo count uses a pill.** The two badges are visually distinct *on purpose* so a scan never confuses "PRs awaiting me" with "PRs in this repo". Keep the `DashboardReviewsControlStrip.needsMeCountBadge` as a `Capsule`-backed notification badge and the per-repo `DashboardReviewsRepositoryHeaderPill` as a `harnessControlPillGlass` rectangular pill.

## Navigation discipline

Keep implementation and preview files in the same domain so navigator grouping
and Open Quickly stay predictable. If a runtime file gains a preview, add a
mirrored companion in `Previews/` instead of dropping preview code into the
runtime file or an unrelated folder.

## Performance gotcha

Views in `Settings/` and `Shared/` often use shared action controls that opt
into MCP accessibility tracking. If a dense pane here feels slow to open or
react, inspect that tracking path before restructuring the visible SwiftUI
layout. A tracked-element probe that resolves `accessibilityFrame()` or
republishes unthrottled on `NSWindow.didUpdateNotification` can make the whole
window feel stalled; prefer clip-aware AppKit geometry conversion plus
throttled refreshes.
