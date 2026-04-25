# Recording Analysis

This document is the recording-first triage doctrine for `swarm-full-flow`. Consume the `.mov` first, then use the artifacts here to decide whether a finding is real.

## Investigation order

1. The recording first: startup, shutdown, retries, relaunches, visible UI state, disabled surfaces, wrong states, stalls, pauses, layout/readability issues, interaction failures.
2. Then the supporting artifacts: screenshots, hierarchy dumps, logs, `xcresult` exports, persisted state.
3. Order is fixed: video first, everything else second. A finding sourced only from a log without a recording timestamp is not promoted.

## Ground truth per act

For every act marker the lane already produces three pieces of truth at a known wall clock:

- `act-driver.log` `actReady("actN", ...)` and `actAck("actN")` bracket the act window.
- `ui-snapshots/<actN>.png` shows the rendered app state.
- `ui-snapshots/<actN>.txt` shows the hierarchy and accessibility tree.

If the frame disagrees with those artifacts, file a finding. See [act-marker-matrix.md](act-marker-matrix.md) for the per-act surface.

## Detection recipes

Bake these into [recording-triage scripts](../../../../scripts/e2e/recording-triage/) when they are run more than once. Run them ad-hoc when triaging a specific window.

### Per-act keyframes

```
ffmpeg -ss <ts> -i swarm-full-flow.mov -frames:v 1 -y <act>.png
```

Extract frames at `actReady`, `actAck`, and 250 ms before each transition. Compare each frame against `ui-snapshots/<actN>.png`; large visual distance is a render-mismatch finding.

### Frame freezes and stalls

```
ffprobe -show_frames -of compact=p=0 swarm-full-flow.mov \
  | awk -F= '/pkt_pts_time=/ {print $NF}'
```

Compute inter-frame gaps:

- Gap > 50 ms during expected motion is a hitch.
- Gap > 250 ms without a clear cause is a stall.
- Gap > 2 s mid-run outside known waits is a freeze.
- Idle gap > 5 s outside act boundaries with no `act-driver.log` activity is a stall finding.

Three or more hitches in a single segment is a perf finding even when no individual gap crosses 250 ms.

### Dead head and dead tail

Compare the `.mov` first frame against the daemon app-launch line and the last frame against the test `terminate` line. Either side > 5 s is a recording-artifact finding.

## Per-launch checklist

One recording segment maps to one app launch. Apply this checklist to every segment in the iteration. The post-analysis proof pass in [recording-checklist.md](recording-checklist.md) drives the verdict for each item; this section explains the threshold behind each verdict.

### A. Process and lifecycle

- Time-to-first-frame target: ≤ 2 s on M-series.
- Time-to-populated-dashboard target: ≤ 1 s.
- Daemon-manifest pickup latency > 1 s when the manifest already exists is a finding.
- Warm relaunch must beat cold launch in the same iteration.
- Termination must be orderly, not a crash dialog or beachball.
- `-ApplePersistenceIgnoreState YES` must prevent prior-session window restore.

### B. First-frame state

- Loading, empty, and populated must be visually distinct.
- Disabled and enabled controls must reflect capability, not sequencing.
- Non-nil sidebar or list selection must show a highlight.
- Sidebar opaque flashes, toolbar Liquid Glass loss, detail backdrop bleed, and glass-on-glass stacks are findings.

### C. State transitions between acts

- Every state transition must animate and finish within 200 ms.
- A transition still in motion 500 ms after the trigger is a finding.
- Controls inside a moving region must stay hittable or visibly disabled.
- New toasts must enqueue, not stack.
- Modal sheets must center and present or dismiss in under 200 ms.

### D. Idle behavior between acts

- Outside live-data fields, idle frames must be pixel-stable for at least 2 s.
- No animations on always-visible chrome.
- No unexplained re-renders.
- Visible jank during idle suggests a render loop.

### E. Animation, performance, hitches

- Inter-frame gap > 50 ms during animation is a hitch. Three or more in a single segment is a perf finding.
- Inter-frame gap > 250 ms without a clear cause is a stall.
- First-frame layout thrash: bounds-box changes > 3 within 500 ms after a navigation is a finding.
- Toolbar quantization stutter on FocusedValue updates: rapid back-and-forth size changes in the toolbar are a finding.

### F. Readability and accessibility

- Truncation that hides the primary affordance is a finding. Truncation of secondary metadata is acceptable when a tooltip or detail surface is reachable.
- Text contrast: foreground vs background WCAG ratio < 4.5:1 for body text and < 3:1 for large text is a finding. Sample from the `ui-snapshots` PNG.
- Tap targets < 24 × 24 pt for primary actions are a finding. < 32 × 32 pt for primary actions on macOS is a smell.
- Cmd+/- font scaling regressions: the `Font.scaled(by:)` system must propagate. Views that ignore it are findings.
- Density spikes: count visible interactive elements per region per frame. A spike that exceeds surrounding density by 2× is clutter.

### G. Interaction fidelity

- Click-to-feedback latency must be < 100 ms. A click that produces no visible response within 100 ms is a finding.
- Hover gating: hover-revealed affordances must appear within 50 ms of pointer entry and disappear within 50 ms of exit.
- Drag-drop: every drag must show a drag preview within 100 ms. Every drop on a valid target must produce immediate state change, not a round-trip.
- Keyboard shortcuts: every shortcut firing must produce visible feedback within 100 ms.

### H. Swarm-specific UI (cross-reference act-marker-matrix.md)

- Agents card runtime icon must be correct for every joined role per [act-marker-matrix.md](act-marker-matrix.md) `act2`: leader/claude, worker/codex, worker/claude, reviewer/claude, reviewer/codex, reviewer/claude duplicate (must be visibly rejected, not silently accepted), observer/claude, improver/codex, plus optional gemini/copilot/vibe.
- Review-state badge transitions must be visible and timestamped: `Open -> AwaitingReview -> InReview -> Done`. A badge skipping an intermediate state is a finding.
- Arbitration banner must appear on entry into round-3 arbitration (`act13` window) and dismiss on the final approve.
- Heuristic issue cards: one card per injected code at `act5`. The ten codes are listed in [act-marker-matrix.md](act-marker-matrix.md). Missing cards or wrong code labels are findings.
- `workerRefusal` toast must fire at `act11`. Missing toast or stale label is a finding.
- `signalCollision` toast must fire at `act14`. Missing toast or duplicate stack with `act11` is a finding.
- Auto-spawn-reviewer indicator must appear after the reviewer-removal cascade in `act10`.
- Round-counter pill must increment 1 -> 2 -> 3 across the three request-changes rounds in `act12` and `act13`.
- Partial-agreement chip must appear when the worker disputes `p2`/`p3`.
- Daemon-health indicator must remain green throughout a passing run. Any flap is a finding.

### I. Recording artifact verification

- `.mov` starts within 5 s of process spawn and ends within 5 s of process exit. Anything outside the 5 s band is a dead-head or dead-tail finding.
- No frame freezes > 2 s mid-run except known waits (daemon manifest pickup, model selection).
- No black frames except known transitions.
- File size in the expected band: > 5 MB and < 2 GB for a typical run. Truncated captures are findings.
- One segment per launch. Multi-launch iterations yield multi-segment captures with no dead time across launches.

## Suite-speed lens

Treat any wait that could have started the next safe action as a finding on the loop. Dead head, dead tail, relaunch gaps, delayed assertions, slow handoffs, and redundant waits all count.

## Checklist pass

After the chronological recording review, run the proof checklist in [recording-checklist.md](recording-checklist.md) and keep the short verdict lines with the iteration notes. Do not move to secondary artifacts until the checklist pass is complete.
