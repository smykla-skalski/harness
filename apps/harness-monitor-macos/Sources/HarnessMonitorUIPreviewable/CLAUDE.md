# CLAUDE.md

Read `AGENTS.md` first. It is the canonical layout and preview-organization contract for this directory.

## Claude-specific working rules

1. Do not add files directly under `Views/`; always choose the nearest domain folder first.
2. Prefer `Views/<Domain>/Previews/Preview<Name>.swift` companion files over inline previews in runtime files.
3. Treat `Views/<Domain>/Canvas/` as a migration queue, not the destination for new work. If you touch a file there, try to extract the preview and move the runtime file out in the same change.
4. Keep moves feature-local. Examples: `Workspace/Window/`, `Workspace/Sidebar/`, and `Preferences/Supervisor/`.
5. Before finishing a layout change here, confirm that every file containing `#Preview` lives under `Canvas/` or `Previews/`.
