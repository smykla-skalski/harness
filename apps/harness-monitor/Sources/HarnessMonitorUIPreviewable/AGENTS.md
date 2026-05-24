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
