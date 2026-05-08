# CLAUDE.md

Read `AGENTS.md` first - it is the canonical cross-runtime guide for this directory and covers Tuist generation, build/test, debugging discipline, performance measurement, UX/SwiftUI rule pointers, daemon modes, preview authoring, and gotchas. This file carries only the Claude Code deltas that AGENTS.md does not.

## Agent Lane Setup

`CLAUDE_SESSION_ID` is never auto-injected into Bash. Set lane names explicitly from it when a Claude session needs isolated Harness Monitor build or runtime state. Never use broad shared names like `claude-main`; prefer `agent-<sanitized-uuid>`.

Parallel Claude sessions must use separate full git worktrees for any Monitor edit/generate/build/test/daemon/XcodeBuildMCP work. Build/runtime lanes are still required for side-effect isolation, but they do not make one shared checkout safe for concurrent work.

```bash
HARNESS_MONITOR_BUILD_LANE=agent-<uuid> rtk mise run monitor:build
HARNESS_MONITOR_BUILD_LANE=agent-<uuid> XCODE_ONLY_TESTING=Target/Class rtk mise run monitor:test
HARNESS_MONITOR_RUNTIME_LANE=agent-<uuid> rtk mise run monitor:runtime
HARNESS_MONITOR_RUNTIME_LANE=agent-<uuid> rtk mise run monitor:mcp
```

`monitor:test` auto-passes `-workspace HarnessMonitor.xcworkspace`, which resolves cross-project SPM dependencies (e.g. `HarnessMonitorRegistry` in `mcp-servers/`). `monitor:xcodebuild` does not add `-workspace` - pass it yourself when using that task. If a Swift error persists after fixing a source file, a stale `.dia` from the prior failed build is the cause; delete it and rebuild: `xcode-derived-lanes/<lane>/Build/Intermediates.noindex/HarnessMonitor.build/Debug/<Target>.build/Objects-normal/arm64/<File>.dia`.

The Run scheme is lane-agnostic by contract (see `AGENTS.md` "Daemon discovery and IDE Run"). Agents must keep passing `HARNESS_MONITOR_RUNTIME_LANE` on the `xcodebuild` command line — the env reaches the test/run process and overrides the cross-lane discovery resolver. Never re-enable `Scripts/post-generate.sh::patch_run_scheme_runtime_env` (gated on `HARNESS_MONITOR_PATCH_RUN_SCHEME=1`); patching the user's scheme on every regen hijacks their IDE Run.

## Task Closeout

Finished monitor tasks follow the repo-root rule: replay onto `main` with clean, flat history, never through merge commits. Resolve conflicts by triaging current `main` behavior against the monitor change intent, keep unrelated edits out, and rerun the smallest relevant monitor validation before handoff.

## Fast test reruns (chained selectors)

`XCODE_ONLY_TESTING` accepts comma-separated selectors. Batch focused reruns into ONE call instead of chaining N invocations - each call costs two xcodebuild cold starts plus a tuist graph parse, none of which amortize when the source tree is unchanged:

```bash
XCODE_ONLY_TESTING='HarnessMonitorKitTests/WorkspaceSelectionStoreTests/createAgentRequestCarriesEntryPoint(),HarnessMonitorKitTests/WorkspaceSelectionStoreTests/createAgentRequestIgnoresStaleSelectedSessionID()' \
  HARNESS_MONITOR_BUILD_LANE=agent-<uuid> rtk mise run monitor:test
```

`test-swift.sh` defaults to skipping `build-for-testing` when the existing `.xctestrun` is fresher than every Swift source, project descriptor, SPM lockfile, and the cross-project `mcp-servers/` tree. Break-glass: set `HARNESS_MONITOR_FORCE_BUILD_FOR_TESTING=1` to always rebuild (use after tooling changes that the freshness scope does not capture, e.g. .xcconfig edits, environment switches, or external package updates outside the scoped roots).

## Lane cleanup

Named build lanes live under `xcode-derived-lanes/<lane>`. Delete stale lane directories only when no process is using that lane. Use `rtk mise run clean:stale` for safe stale process/socket cleanup and `rtk mise run monitor:reset` only when resetting the active runtime lane is intended.

## UI shape rules

Two rules guard against the most common forms of structural drift in this app's view layer:

1. **Decompose-on-touch.** When a PR touches a multi-section view (e.g. `AgentDetailSection.swift`) and adds >20 lines or new `@State`/`@AppStorage` to a single section, extract that section into a file-private view in the same file before merge. The rule applies on the next touch, not pre-emptively. Pre-emptive extraction trades a long file for a long file plus parent-side plumbing; on-touch extraction names a seam that's already real.

2. **No UI surface ships without its real producer.** A view that visualizes a signal (badge, sparkline, transcript row, status pill) does not land until the signal's data path is wired end-to-end and exercised by at least one non-empty test fixture in the same PR. Empty-sample sparklines, dashboard tiles fed by stubs, enum variants with no emitter all qualify. The rule prevents the productivity-from-prettiness loop where downstream UI ships ahead of the signal it claims to expose.

   **Fixture origin clarification.** The "non-empty test fixture" requirement is satisfied by either a hand-built fixture (e.g. `[TimelineEntry]` literals constructed in-test) or a real recording from `_artifacts/runs/<slug>/`. Hand-built fixtures are sufficient for pure data-flow contracts where the mapping is deterministic (input shape -> output shape). Real recordings are required when the contract depends on tacit shape (timing, ordering across sources, format quirks the daemon emits but the type system does not encode). When in doubt, prefer the recording: a hand-built fixture that misses a real-format detail looks green for the wrong reason.

   *Canonical hand-built example:* `Tests/HarnessMonitorKitTests/HarnessMonitorStoreAgentTimelinePartitionTests.swift` - the partition contract is pure (no daemon, no clock, no IO), so `[TimelineEntry]` literals plus a 32-trial randomized property check against a linear-scan reference are sufficient. If the next surface looks like that one (deterministic, type-fully-encoded, no cross-source timing), follow this shape; if it depends on anything the type system does not capture, capture a recording instead.
