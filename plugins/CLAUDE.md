# plugins/

This directory is auto-generated. Do not modify files here directly.

## Source location

Canonical plugin definitions live in `agents/plugins/`. Each plugin has:
- `plugin.yaml` - plugin metadata (name, description, version)
- `skills/*/skill.yaml` - skill metadata
- `skills/*/body.md` - skill body content
- `skills/*/references/` - reference documents
- `agents/` - agent definitions (optional)
- `hooks.yaml` - hook definitions (optional, Claude-specific)

## Regenerating

Run from repository root:

```bash
harness setup bootstrap
```

Or for specific agents:

```bash
harness setup bootstrap --agents codex
```

This renders `agents/plugins/` to multiple targets:
- `plugins/` - portable format (Codex, Copilot)
- `.claude/plugins/` - Claude Code specific
- `.gemini/commands/` - Gemini CLI
- `.vibe/plugins/` - Vibe
- `.opencode/plugins/` - OpenCode

## Implementation

Rendering logic is in `src/agents/assets/render_plugins.rs`. The `render_codex_plugin_outputs` function writes to this directory.
