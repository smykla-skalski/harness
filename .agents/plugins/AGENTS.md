# AGENTS.md

This directory is renderer-managed output from `harness setup agents generate`.
The repo-root `AGENTS.md` still applies.

Do not edit files in this directory directly; regeneration will overwrite
them. When a task points here, update the canonical source or the renderer,
then regenerate and validate the managed outputs.

Sources:
- Canonical cross-runtime skills: `agents/skills/`
- Canonical cross-runtime plugins: `agents/plugins/`
- Claude-only local skills: `local-skills/claude/` (symlinked into `.claude/skills/`)

Implementation: `src/agents/assets/render_*.rs`

Regenerate and check:

```bash
mise run setup:agents:generate
mise run check:agent-assets
```
