# Recording Checklist

Use this after the chronological `.mov` pass. The recording-triage pipeline pre-fills most rows in `recording-triage/checklist.md`; verify those verdicts and re-watch any row marked `needs-verification`.

If a check is unproven, mark it `needs-verification` and re-watch.

Thresholds live in [recording-analysis.md](recording-analysis.md). Per-act surfaces live in [act-marker-matrix.md](act-marker-matrix.md).

## Automation map

Tier 1 rows resolve from existing detectors, Tier 2 from new mechanical analysis, Tier 3 from frame-pair wrappers, Tier 4 are manual judgments the emitter always defaults to `needs-verification`.

| Tier | Source JSON | Rows |
|------|-------------|------|
| 1 | `frame-gaps.json` | `perf.hitch`, `perf.stall`, `artifact.freezes` |
| 1 | `dead-head-tail.json` | `lifecycle.terminate`, `artifact.head`, `artifact.tail`, `suite.deadHead`, `suite.deadTail` |
| 1 | `thrash.json` | `idle.chrome` |
| 1 | `black-frames.json` | `artifact.blanks` |
| 1 | `assert-recording.json` | `artifact.size` |
| 2 | `act-timing.json` | `lifecycle.ttff`, `lifecycle.dashboard`, `suite.handoff` |
| 2 | `act-identifiers.json` | every `swarm.act{N}.*` row plus `swarm.invariant.transitions`, `swarm.invariant.daemonHealth`, `firstframe.selection` |
| 2 | `launch-args.json` | `lifecycle.persistence` |
| 3 | `layout-drift.json` | `perf.layoutThrash` |
| 4 | (manual) | `lifecycle.manifest`, `lifecycle.warmstart`, `firstframe.states/enablement/glass`, `transition.*`, `idle.stable/rerender/cpu`, `perf.toolbarStutter`, `a11y.*`, `interaction.*`, `artifact.segments`, `suite.relaunchGap/delayedAssert/repeatedWait` |

Tier-4 rows always emit `needs-verification` with a one-line rationale; the agent re-watches them but never silently skips them.

## Required items

### A. Process and lifecycle

- `lifecycle.ttff`: first frame ≤ 2 s on M-series, ≥ 4 s is `found`.
- `lifecycle.dashboard`: populated dashboard ≤ 1 s, ≥ 2 s is `found`.
- `lifecycle.manifest`: manifest pickup > 1 s when the manifest already exists is `found`.
- `lifecycle.warmstart`: warm relaunch must beat cold launch.
- `lifecycle.terminate`: orderly termination, no crash dialog, no hung window in the last 5 s.
- `lifecycle.persistence`: `-ApplePersistenceIgnoreState YES` honored, no prior session window restored.

### B. First-frame state

- `firstframe.states`: loading, empty, populated visually distinguishable.
- `firstframe.enablement`: enabled vs disabled controls reflect capability, not sequencing.
- `firstframe.selection`: non-nil sidebar or list selection has a visible highlight.
- `firstframe.glass`: no sidebar opaque flash, toolbar Liquid Glass intact, no glass-on-glass stack, no detail backdrop bleed.

### C. Transitions between acts

- `transition.animated`: no snap on transitions.
- `transition.duration`: every transition completes ≤ 200 ms.
- `transition.terminates`: no transition still in motion 500 ms after the trigger.
- `transition.hittest`: controls in moving regions remain hit-testable or visibly disabled.
- `transition.toast`: new toasts enqueue, no two visually overlap for more than one frame.
- `transition.sheet`: modal sheets center, present ≤ 200 ms, dismiss ≤ 200 ms, no flicker.

### D. Idle behavior

- `idle.stable`: idle frames pixel-stable ≥ 2 s outside live-data fields.
- `idle.chrome`: no animations on always-visible chrome.
- `idle.rerender`: no unexplained re-renders.
- `idle.cpu`: no visible jank during otherwise idle frames.

### E. Animation and performance

- `perf.hitch`: ≤ 2 inter-frame gaps > 50 ms during animation per segment.
- `perf.stall`: no inter-frame gap > 250 ms without a logged cause.
- `perf.layoutThrash`: no > 3 bounds-box changes within 500 ms after navigation.
- `perf.toolbarStutter`: no rapid back-and-forth toolbar size changes on FocusedValue updates.

### F. Readability and accessibility

- `a11y.truncation`: no truncation that hides the primary affordance.
- `a11y.contrast`: WCAG body ≥ 4.5:1, large text ≥ 3:1.
- `a11y.tapTarget`: primary actions ≥ 24 × 24 pt; ≥ 32 × 32 pt is the macOS smell threshold.
- `a11y.fontScaling`: Cmd+/- scaling propagates through `Font.scaled(by:)`.
- `a11y.density`: no region density spike > 2× surrounding density.

### G. Interaction fidelity

- `interaction.click`: click-to-feedback < 100 ms.
- `interaction.hover`: hover-revealed affordances appear ≤ 50 ms, disappear ≤ 50 ms.
- `interaction.drag`: drag preview ≤ 100 ms, drop on valid target produces immediate state change.
- `interaction.shortcut`: every shortcut firing produces visible feedback ≤ 100 ms.

### H. Swarm-specific UI (cross-reference [act-marker-matrix.md](act-marker-matrix.md))

- `swarm.act1.session`: selected sidebar row + cockpit window title at `act1`.
- `swarm.act2.roles`: required runtime/role pairs visible; duplicate claim visibly rejected.
- `swarm.act3.tasks`: five task cards visible at `act3`.
- `swarm.act4.selection`: `agentsTaskCard.value == task_review_id`.
- `swarm.act5.heuristics`: ten distinct `heuristicIssueCard.<code>` cards present.
- `swarm.act6.improver`: improver dry-run reflected in the agents detail pane.
- `swarm.act7.roster`: agents card reflects current roster after the rejoin.
- `swarm.act8.awaitingReview`: `awaitingReviewBadge(task_review_id)` present in the review panel.
- `swarm.act9.reviewers`: claim badge or quorum indicator with two runtimes.
- `swarm.act10.autospawn`: auto-spawn-reviewer indicator present after removal cascade.
- `swarm.act11.workerRefusal`: `harness.toast.worker-refusal` toast or `agentsTaskCard` rejection state visible.
- `swarm.act12.round1`: `roundCounter(task_arbitration_id)` shows `1`; partial-agreement chip visible.
- `swarm.act13.round3`: round counter shows `3`; arbitration banner visible.
- `swarm.act14.signalCollision`: `harness.toast.signal-collision` toast present, no overlap with the act11 toast.
- `swarm.act15.observe`: one of `observeScanButton`/`observeDoctorButton`/observe summary visible; daemon-health green.
- `swarm.act16.end`: `harness.session-status.corner` reaches closed/ended within 20 s of ack.
- `swarm.invariant.transitions`: review-state badge progresses `Open -> AwaitingReview -> InReview -> Done`.
- `swarm.invariant.daemonHealth`: daemon-health indicator green from `act1` through `act16`.

### I. Recording artifact integrity

- `artifact.head`: `.mov` first frame within 5 s of spawn.
- `artifact.tail`: `.mov` last frame within 5 s of exit.
- `artifact.freezes`: no mid-run freeze > 2 s outside known waits.
- `artifact.blanks`: no black or near-blank frames outside known transitions.
- `artifact.size`: file size between 5 MB and 2 GB.
- `artifact.segments`: one segment per launch; multi-launch iterations produce multi-segment captures with no dead time across launches.

## Suite-speed prompts

Apply on every iteration, even when no `swarm.*` row is `found`.

- `suite.deadHead`: no dead time at the start.
- `suite.deadTail`: no dead time at the end.
- `suite.relaunchGap`: no avoidable idle between consecutive launches.
- `suite.handoff`: no slow handoff that delays the next act.
- `suite.delayedAssert`: no assertion that waits longer than required.
- `suite.repeatedWait`: no repeated wait that could be collapsed.

Keep the proof pass terse. Wrap named files or paths in markdown links. Promote any `found` verdict to a row in the active findings file `_artifacts/active.md` using [iteration-protocol.md](iteration-protocol.md). Closed rows belong in the closed archive `_artifacts/ledger.md`; the move is owned by `scripts/swarm-iterate/close-finding.sh`.
