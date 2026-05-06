# AGENTS.md

This directory is the previewable SwiftUI layer for Harness Monitor. The app-level `apps/harness-monitor-macos/AGENTS.md` still applies; this file is the local structure contract for `Sources/HarnessMonitorUIPreviewable/`.

The layout follows the common large-SwiftUI pattern of feature-local folders plus dedicated preview folders. Inline previews have been fully extracted, so preview code belongs only in `Previews/`.

## Directory map

- `Views/` - feature-first UI source tree. New files do not land directly under `Views/`; they must pick a domain folder.
  - `Actions/`
  - `Agents/`
  - `App/`
  - `Attention/`
  - `Decisions/`
  - `Settings/`
  - `Review/`
  - `Sessions/`
  - `Shared/`
  - `Sidebar/`
  - `Signals/`
  - `Timeline/`
  - `Toolbar/`
  - `Voice/`
  - `Workspace/`
- `Views/<Domain>/Previews/` - dedicated preview files. This is the preferred home for new preview code.
- `Support/` - cross-cutting non-view support for this target.
- `Theme/` - shared styling primitives.
- `Features/` - feature-flagged source roots only.
- `Assets.xcassets` - target resources.

## Preview rules

1. Prefer dedicated preview files over inline previews in implementation files.
2. Dedicated preview files live in the nearest `Previews/` folder and use a leading `Preview` prefix, for example `PreviewWorkspaceWindowView.swift`.
3. Do not introduce trailing preview suffixes such as `+Preview`, `+Previews`, `Previews`, or one-off names like `CrowdedPreview` for new files.
4. Runtime implementation files should not contain `#Preview`; add or update a mirrored companion in `Previews/` instead.
5. Keep preview-only helpers private and next to the preview file unless they are reused by multiple preview files in the same domain; only then promote them to a clearly named support file such as `SettingsPreviewSupport.swift`.

## Domain notes

- `Workspace/Window/` holds `WorkspaceWindowView` and its extensions/support strips.
- `Workspace/Sidebar/` holds workspace sidebar-specific surfaces.
- `Settings/Supervisor/` holds supervisor-specific settings panes and their split helpers.
- `Shared/` is only for reusable UI primitives used by multiple domains. If a file serves one feature, keep it in that feature.

## Navigation discipline

1. Avoid creating new top-level files under `Views/`.
2. Keep implementation and preview files in the same domain so navigator grouping and Open Quickly stay predictable.
3. If a runtime file gains a preview, add a mirrored companion in `Previews/` instead of dropping preview code into the runtime file or an unrelated folder.
