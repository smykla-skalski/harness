# AGENTS.md

This directory is renderer-managed output from `harness setup agents generate`.

Sources:
- Canonical cross-runtime skills: `agents/skills/`
- Canonical cross-runtime plugins: `agents/plugins/`
- Claude-only local skills: `local-skills/claude/` (symlinked into `.claude/skills/`)

Implementation: `src/agents/assets/render_*.rs`

Do not edit files in this directory directly; edits will be overwritten on the
next `harness setup agents generate` run. Update the canonical sources or the
renderer, then regenerate.
