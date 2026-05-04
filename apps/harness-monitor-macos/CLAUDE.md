# CLAUDE.md

Read `AGENTS.md` first - it is the canonical cross-runtime guide for this directory and covers Tuist generation, build/test, debugging discipline, performance measurement, UX/SwiftUI rule pointers, daemon modes, preview authoring, and gotchas. This file carries only the Claude Code deltas that AGENTS.md does not.

## Agent profile setup

`CLAUDE_SESSION_ID` is never auto-injected into Bash. Set it explicitly on every `monitor:agent:*` call; the wrapper derives `agent-<sanitized-uuid>` from it (lowercase, non-alphanumeric runs → `-`, trimmed). Never use a hardcoded profile name like `claude-main`, and clear inherited build-path env instead of reusing it - agent sessions must stay on their own `agent-<session>` lane by default. Canonical forms:

```bash
CLAUDE_SESSION_ID=<uuid> rtk mise run monitor:agent:build
XCODE_ONLY_TESTING=Target/Class CLAUDE_SESSION_ID=<uuid> rtk mise run monitor:agent:test
HARNESS_CHECK_AUTOCLEAN=1 CLAUDE_SESSION_ID=<uuid> rtk mise run monitor:agent:test
```

`monitor:agent:test` auto-passes `-workspace HarnessMonitor.xcworkspace`, which resolves cross-project SPM dependencies (e.g. `HarnessMonitorRegistry` in `mcp-servers/`). `monitor:agent:xcodebuild` does not add `-workspace` - pass it yourself when using that task. If a Swift error persists after fixing a source file, a stale `.dia` from the prior failed build is the cause; delete it and rebuild: `xcode-derived/profiles/<profile>/Build/Intermediates.noindex/HarnessMonitor.build/Debug/<Target>.build/Objects-normal/arm64/<File>.dia`.

## UI shape rules

Two rules guard against the most common forms of structural drift in this app's view layer:

1. **Decompose-on-touch.** When a PR touches a multi-section view (e.g. `AgentDetailSection.swift`) and adds >20 lines or new `@State`/`@AppStorage` to a single section, extract that section into a file-private view in the same file before merge. The rule applies on the next touch, not pre-emptively. Pre-emptive extraction trades a long file for a long file plus parent-side plumbing; on-touch extraction names a seam that's already real.

2. **No UI surface ships without its real producer.** A view that visualizes a signal (badge, sparkline, transcript row, status pill) does not land until the signal's data path is wired end-to-end and exercised by at least one non-empty test fixture in the same PR. Empty-sample sparklines, dashboard tiles fed by stubs, enum variants with no emitter all qualify. The rule prevents the productivity-from-prettiness loop where downstream UI ships ahead of the signal it claims to expose.
